import Foundation

/// Decodes GigaAM token IDs into text using `tokens.json` (the SentencePiece
/// vocabulary exported as a JSON string array). The pinned Core ML export
/// (`smkrv/gigaam-v3-e2e-rnnt-coreml`) contains exactly the 1024 real
/// pieces; the blank (id 1024, the 1025th model output) is implicit and
/// never appears in a hypothesis.
///
/// Behavior mirrors the reference inference (`example_infer.py`) and the
/// SentencePiece `decode` the PyTorch model applies:
/// - pieces are concatenated,
/// - `▁` (U+2581) becomes a space,
/// - byte-fallback pieces (`<0xNN>`) are accumulated into UTF-8 bytes,
/// - runs of spaces collapse to one, leading/trailing whitespace is trimmed.
///
/// Output already carries GigaAM's punctuation, casing and digits — never
/// re-lowercase or strip punctuation here.
final class GigaAMTokenDecoder {
    static let blankID = 1024
    static let vocabularySize = 1025

    let pieces: [String]

    enum TokenDecoderError: Error, CustomStringConvertible {
        case invalidTokensJSON(String)
        case unexpectedVocabularySize(Int)

        var description: String {
            switch self {
            case .invalidTokensJSON(let detail):
                return "tokens.json could not be parsed: \(detail)"
            case .unexpectedVocabularySize(let count):
                return "tokens.json has \(count) entries, expected \(GigaAMTokenDecoder.blankID) " +
                    "(blank \(GigaAMTokenDecoder.blankID) is implicit) or \(GigaAMTokenDecoder.vocabularySize)"
            }
        }
    }

    init(pieces: [String]) throws {
        // 1024: the pinned export (blank implicit). 1025: an export that
        // includes an explicit blank slot. Anything else is the wrong model.
        guard pieces.count == Self.blankID || pieces.count == Self.vocabularySize else {
            throw TokenDecoderError.unexpectedVocabularySize(pieces.count)
        }
        self.pieces = pieces
    }

    /// Load from the `tokens.json` file inside the Core ML metadata directory.
    convenience init(metadataURL: URL) throws {
        do {
            let data = try Data(contentsOf: metadataURL)
            let pieces = try JSONDecoder().decode([String].self, from: data)
            try self.init(pieces: pieces)
        } catch let error as TokenDecoderError {
            throw error
        } catch {
            throw TokenDecoderError.invalidTokensJSON(String(describing: error))
        }
    }

    /// Decode a hypothesis (token IDs) into display text.
    func decode(ids: [Int]) -> String {
        var result = String()
        result.reserveCapacity(ids.count * 3)
        var pendingBytes: [UInt8] = []

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            result += String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll(keepingCapacity: true)
        }

        for id in ids {
            // The blank can never legally appear in a hypothesis (the greedy
            // loop breaks before appending it); skipping keeps a malformed
            // one from leaking the literal `<blank>` piece into the text.
            guard id >= 0, id < pieces.count, id != Self.blankID else { continue }
            let piece = pieces[id]
            if let byte = Self.byteFallbackValue(piece) {
                pendingBytes.append(byte)
            } else {
                flushBytes()
                result += piece
            }
        }
        flushBytes()

        let text = result.replacingOccurrences(of: "▁", with: " ")
        return Self.collapseSpaces(text)
    }

    /// `<0x41>` → 0x41, nil for ordinary pieces.
    static func byteFallbackValue(_ piece: String) -> UInt8? {
        var chars = piece.unicodeScalars.makeIterator()
        guard chars.next() == "<", chars.next() == "0", chars.next() == "x",
              let d1 = chars.next(), let d2 = chars.next(),
              chars.next() == ">", chars.next() == nil
        else { return nil }
        guard let high = Self.hexDigit(d1), let low = Self.hexDigit(d2) else {
            return nil
        }
        let value = high << 4 | low
        return UInt8(value)
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - Unicode.Scalar("0").value)
        case "a"..."f": return Int(scalar.value - Unicode.Scalar("a").value + 10)
        case "A"..."F": return Int(scalar.value - Unicode.Scalar("A").value + 10)
        default: return nil
        }
    }

    /// Trim + collapse runs of spaces (SentencePiece never emits meaningful
    /// double spaces; collapsing keeps display stable when consecutive `▁`
    /// pieces occur after byte fallbacks).
    static func collapseSpaces(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var lastWasSpace = true  // also eats leading spaces
        for ch in text {
            if ch == " " {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
