import XCTest
import Network
@testable import LiveTranslateIOS

/// A minimal loopback HTTP server that streams its body slowly and in small
/// chunks, with HTTP Range support — just enough to exercise the installer's
/// download path, including pause/resume, without any network access.
final class SlowHTTPServer: @unchecked Sendable {
    let body: Data
    var chunkSize = 2_048
    var interChunkDelay: TimeInterval = 0.01

    private let listener: NWListener
    private let queue = DispatchQueue(label: "slow-http-server")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(body: Data) throws {
        self.body = body
        self.listener = try NWListener(using: .tcp) // ephemeral port
    }

    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            self.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success,
              let raw = listener.port?.rawValue, raw != 0 else {
            throw NSError(domain: "SlowHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener did not come up"])
        }
        port = raw
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/model.bin")! }

    // MARK: - Internals

    private func handle(_ connection: NWConnection) {
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let _ = error { connection.cancel(); return }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(request: buffer[..<headerEnd.lowerBound], connection: connection)
            } else if buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeaders(connection, buffer: buffer)
            }
        }
    }

    private func respond(request: Data, connection: NWConnection) {
        guard let text = String(data: request, encoding: .utf8),
              text.hasPrefix("GET ") else {
            connection.cancel()
            return
        }

        // Range: bytes=N-  →  206 Partial Content from N (resume support).
        var start = 0
        if let rangeLine = text.split(separator: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.firstIndex(of: "="),
           let dash = rangeLine[rangeLine.index(after: eq)...].firstIndex(of: "-") {
            start = Int(rangeLine[rangeLine.index(after: eq)..<dash]) ?? 0
        }

        let slice = body.subdata(in: start..<body.count)
        var head = "HTTP/1.1 \(start > 0 ? "206 Partial Content" : "200 OK")\r\n"
        head += "Content-Length: \(slice.count)\r\n"
        if start > 0 {
            head += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            self.sendChunks(of: slice, at: slice.startIndex, over: connection)
        })
    }

    private func sendChunks(of slice: Data, at index: Data.Index, over connection: NWConnection) {
        let end = min(index + chunkSize, slice.endIndex)
        let chunk = slice[index..<end]
        connection.send(content: Data(chunk), completion: .contentProcessed { _ in
            if end >= slice.endIndex {
                connection.cancel()
            } else {
                let delay = self.interChunkDelay
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.sendChunks(of: slice, at: end, over: connection)
                }
            }
        })
    }
}

/// Download interruption and recovery through the real `ModelInstaller`
/// against the loopback server: pause mid-file keeps a partial, resume
/// completes it with a Range request, and the hash gate runs before the
/// file is accepted into the install tree.
@MainActor
final class ModelInstallerInterruptionTests: XCTestCase {
    private var server: SlowHTTPServer?
    private var installer: ModelInstaller?

    override func tearDown() async throws {
        server?.stop()
        server = nil
        installer = nil
        // Remove test artifacts from the real backend root (distinct,
        // test-only file names — the actual models are never touched).
        if let root = try? ModelPaths.backendRoot(.sherpaONNXInt8) {
            let fm = FileManager.default
            if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for child in children
                where child.lastPathComponent.hasPrefix("test-interruption-")
                    || (child.lastPathComponent.hasPrefix(".partial-")
                        && child.lastPathComponent.contains("test-interruption")) {
                    try? fm.removeItem(at: child)
                }
            }
        }
    }

    private func makeBackendInfo(url: URL, bytes: Int, sha256: String)
        -> ModelManifest.BackendInfo
    {
        ModelManifest.BackendInfo(
            id: "test-interruption",
            kind: .sherpaONNXInt8,
            repo: "loopback",
            revision: "test",
            files: [
                .init(path: "test-interruption-model.bin", url: url.absoluteString,
                      bytes: bytes, sha256: sha256)
            ],
            totalDownloadBytes: bytes,
            installedBytes: bytes,
            stagingBytes: bytes,
            minimumFreeDiskBytes: 1,
            license: "test",
            coreMLCompiledCacheVersion: nil
        )
    }

    private func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// Pause mid-download → partial file survives → resume completes the
    /// file with an HTTP Range request → full SHA256 gate passes.
    func testPauseKeepsPartialAndResumeCompletes() async throws {
        let data = randomData(count: 200_000)
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("interruption-source-\(UUID().uuidString).bin")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let sha = try await ModelIntegrityVerifier.sha256(of: tempFile)

        let server = try SlowHTTPServer(body: data)
        try server.start()
        self.server = server
        self.installer = ModelInstaller()

        let info = makeBackendInfo(url: server.url, bytes: data.count, sha256: sha)
        let destination = try ModelPaths.backendRoot(.sherpaONNXInt8)
            .appendingPathComponent("test-interruption-model.bin")
        try? FileManager.default.removeItem(at: destination)

        // ---- Download, pause partway through ----
        let firstAttempt = Task { try await installer!.install(info) }
        let pauseDeadline = Date().addingTimeInterval(20)
        while installer!.progress.fraction < 0.25, Date() < pauseDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        installer!.pause()
        do {
            try await firstAttempt.value
            XCTFail("a paused install must throw CancellationError")
        } catch { /* expected */ }
        XCTAssertTrue(installer!.isPaused)

        // The partial must still be on disk next to the destination.
        let dir = destination.deletingLastPathComponent()
        let partials = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".partial-") }
        XCTAssertFalse(partials.isEmpty, "pause must keep the partial file for resume")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a partial download must never be visible as an installed file")

        // ---- Resume: the same install call continues from the partial ----
        try await installer!.install(info)
        XCTAssertFalse(installer!.isPaused)

        // The completed file passes the full hash gate.
        let verifyFailure = await ModelIntegrityVerifier.verify(
            file: info.files[0], at: destination
        )
        XCTAssertNil(verifyFailure, "resumed file must match the pinned SHA256")
    }

    /// A source that silently changes content between pause and resume is
    /// caught by the SHA256 gate — never accepted into the install tree.
    func testCorruptedResumeIsRejectedByHashGate() async throws {
        let original = randomData(count: 100_000)
        let corrupted = original.map { $0 ^ 0x5A }

        let goodFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("good-\(UUID().uuidString).bin")
        try original.write(to: goodFile)
        defer { try? FileManager.default.removeItem(at: goodFile) }
        let sha = try await ModelIntegrityVerifier.sha256(of: goodFile)

        // Server serves the *corrupted* bytes but the manifest pins the
        // *original* hash.
        let server = try SlowHTTPServer(body: Data(corrupted))
        try server.start()
        self.server = server
        self.installer = ModelInstaller()

        let info = makeBackendInfo(url: server.url, bytes: corrupted.count, sha256: sha)
        let destination = try ModelPaths.backendRoot(.sherpaONNXInt8)
            .appendingPathComponent("test-interruption-model.bin")
        try? FileManager.default.removeItem(at: destination)

        do {
            try await installer!.install(info)
            XCTFail("a hash mismatch must fail the install")
        } catch { /* expected */ }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a corrupted file must never enter the install tree")
    }
}
