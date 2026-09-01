import Foundation

/// Incremental Server-Sent Events parser for OpenAI-compatible streaming
/// responses.
///
/// Feed arbitrary text chunks (a chunk may split a line or a multi-byte UTF-8
/// character); complete events are returned as payload strings in arrival
/// order.
///
/// Handles:
/// - `data: {...}` lines with optional space after the colon
/// - multi-line `data:` fields (joined with `\n` per the SSE spec)
/// - `data: [DONE]` terminators (returned as the literal `[DONE]` payload)
/// - comment lines starting with `:`
/// - both `\n` and `\r\n` line endings
/// - a final event without a trailing blank line (via `finish()`)
///
/// Line splitting operates on Unicode scalars, not `Character`s: in Swift the
/// CRLF pair forms a single grapheme cluster, so `firstIndex(of: "\n")` on the
/// `Character` view never matches a `\r\n`-terminated line.
struct SSEParser {
    /// Partial line accumulated across chunk boundaries.
    private var pendingLine: [Unicode.Scalar] = []
    /// `data:` lines of the event currently being assembled.
    private var eventDataLines: [String] = []

    /// Feed one text chunk. Returns the payloads of every event that became
    /// complete within this chunk.
    mutating func feed(_ chunk: String) -> [String] {
        pendingLine.append(contentsOf: chunk.unicodeScalars)
        var payloads: [String] = []
        while let newline = pendingLine.firstIndex(of: "\n") {
            var line = String(String.UnicodeScalarView(pendingLine[..<newline]))
            if line.hasScalarSuffix("\r") { line.unicodeScalars.removeLast() }
            pendingLine.removeSubrange(pendingLine.startIndex...newline)
            if let payload = processLine(line) {
                payloads.append(payload)
            }
        }
        return payloads
    }

    /// Flush the tail of the stream: an unterminated final line and any
    /// assembled-but-undispatched event.
    mutating func finish() -> [String] {
        var payloads: [String] = []
        if !pendingLine.isEmpty {
            var line = String(String.UnicodeScalarView(pendingLine))
            pendingLine = []
            if line.hasScalarSuffix("\r") { line.unicodeScalars.removeLast() }
            if let payload = processLine(line) {
                payloads.append(payload)
            }
        }
        if let payload = flushEventData() {
            payloads.append(payload)
        }
        return payloads
    }

    private mutating func processLine(_ line: String) -> String? {
        if line.isEmpty {
            // Blank line dispatches the current event.
            return flushEventData()
        }
        if line.hasPrefix(":") {
            // SSE comment / keep-alive.
            return nil
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst("data:".count))
            if value.hasPrefix(" ") { value.removeFirst() }
            eventDataLines.append(value)
        }
        // `event:`, `id:` and `retry:` fields are not used by chat
        // completions streams and are ignored.
        return nil
    }

    private mutating func flushEventData() -> String? {
        guard !eventDataLines.isEmpty else { return nil }
        let payload = eventDataLines.joined(separator: "\n")
        eventDataLines = []
        return payload
    }
}

private extension String {
    /// Scalar-level suffix check — `hasSuffix("\r")` is false for a string
    /// whose last grapheme cluster is the CRLF pair.
    func hasScalarSuffix(_ scalar: Unicode.Scalar) -> Bool {
        unicodeScalars.last == scalar
    }
}
