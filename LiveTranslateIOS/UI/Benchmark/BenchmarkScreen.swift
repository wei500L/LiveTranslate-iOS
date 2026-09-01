import SwiftUI
import AVFoundation

/// Dual-backend comparison benchmark: pick audio, run sequentially through
/// Core ML then sherpa-onnx, view and export the report.
struct BenchmarkScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var items: [BenchmarkAudioItem] = []
    @State private var referenceText = ""
    @State private var showFileImporter = false
    @State private var shareItem: SharedFile?
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                Text("在两种识别模式下先后运行同一个本地模型（不会同时占用内存）。未提供参考文本时，报告仅描述输出差异。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Test audio")) {
                Button {
                    loadBuiltinSample()
                } label: {
                    Label(String(localized: "Add built-in Russian sample"), systemImage: "waveform.badge.plus")
                }
                .disabled(builtinSampleURL == nil)
                if builtinSampleURL == nil {
                    Text(String(localized: "No built-in sample is bundled in this build."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label(String(localized: "Import WAV / M4A…"), systemImage: "folder.badge.plus")
                }

                if let error = loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                ForEach(items.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[index].name).font(.subheadline)
                        Text("\(String(format: "%.1f s", Double(items[index].samples.count) / Double(items[index].sampleRate))) · \(items[index].referenceText == nil ? String(localized: "no reference text") : String(localized: "with reference text"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexSet in
                    items.remove(atOffsets: indexSet)
                }
            }

            Section(String(localized: "Reference text (optional, applies to all items)")) {
                TextEditor(text: $referenceText)
                    .frame(minHeight: 70)
                    .font(.caption)
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    if environment.benchmarkRunner.isRunning {
                        HStack {
                            ProgressView().padding(.trailing, 6)
                            Text(String(localized: "正在运行对比测试…"))
                        }
                    } else {
                        Text(String(localized: "Run comparison"))
                    }
                }
                .disabled(items.isEmpty || environment.benchmarkRunner.isRunning)
            }

            if let report = environment.benchmarkRunner.report {
                Section(String(localized: "Report")) {
                    ScrollView(.horizontal) {
                        Text(report.markdown())
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button(String(localized: "Export Markdown")) { export(named: "comparison", content: report.markdown(), ext: "md") }
                    Button(String(localized: "Export JSON")) {
                        if let data = try? report.jsonData(), let text = String(data: data, encoding: .utf8) {
                            export(named: "comparison", content: text, ext: "json")
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "识别性能测试"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .wav]) { result in
            switch result {
            case .success(let url):
                importAudio(url)
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - Audio loading

    private var builtinSampleURL: URL? {
        Bundle.main.url(forResource: "test_ru", withExtension: "wav")
    }

    private func loadBuiltinSample() {
        guard let url = builtinSampleURL else { return }
        loadAudio(url: url, name: String(localized: "Built-in sample"))
    }

    private func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        loadAudio(url: url, name: url.lastPathComponent)
    }

    private func loadAudio(url: URL, name: String) {
        do {
            let samples = try BenchmarkAudioLoader.loadMono16k(url)
            let reference = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(
                BenchmarkAudioItem(
                    name: name,
                    samples: samples,
                    sampleRate: 16_000,
                    referenceText: reference.isEmpty ? nil : reference
                )
            )
            loadError = nil
        } catch {
            loadError = String(format: String(localized: "Could not load %@: %@"), name, error.localizedDescription)
        }
    }

    // MARK: - Run / export

    private func run() async {
        let computeDescription: String
        switch environment.settings.coreMLCompute {
        case .accuracy: computeDescription = "cpuAndGPU"
        case .neuralEngineExperimental: computeDescription = "cpuAndNeuralEngine"
        }
        _ = try? await environment.benchmarkRunner.run(
            items: items,
            coreMLComputeDescription: computeDescription,
            onnxThreadCount: environment.settings.onnxThreads
        )
    }

    private func export(named: String, content: String, ext: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(named)-\(Int(Date.now.timeIntervalSince1970)).\(ext)")
        if (try? content.data(using: .utf8)?.write(to: url, options: .atomic)) != nil {
            shareItem = SharedFile(url: url)
        }
    }
}

/// Decodes an audio file to mono 16 kHz Float32 samples for benchmarking.
enum BenchmarkAudioLoader {
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(domain: "BenchmarkAudioLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        let sourceCapacity = AVAudioFrameCount(16_000) // read/resample in 1 s chunks
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity) else {
            throw NSError(domain: "BenchmarkAudioLoader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate source buffer"])
        }
        var output: [Float] = []
        var reachedEnd = false

        while !reachedEnd {
            try file.read(into: sourceBuffer)
            let inputFrames = sourceBuffer.frameLength
            if inputFrames == 0 { break }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up) + 32)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw NSError(domain: "BenchmarkAudioLoader", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot allocate output buffer"])
            }

            var conversionError: NSError?
            var fedThisPass = false
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if fedThisPass {
                    // No more input for this output buffer.
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fedThisPass = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }

            if let conversionError {
                throw conversionError
            }
            if status == .error {
                throw NSError(domain: "BenchmarkAudioLoader", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Conversion failed"])
            }

            if let channel = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (inputFrames < sourceCapacity && !fedThisPass) {
                reachedEnd = true
            }
            if file.length == 0 { reachedEnd = true }
            if file.framePosition >= file.length { reachedEnd = true }
        }
        return output
    }
}
