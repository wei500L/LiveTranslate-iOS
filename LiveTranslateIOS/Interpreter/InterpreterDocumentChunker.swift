import Foundation
import CryptoKit

/// The citation-grounded context layer for interpreter documents:
///
///     extracted page text
///     → deterministic chunks (stable IDs — the same page text always
///       produces the same chunk set; no vector DB, no embeddings)
///     → bounded selection (user-chosen pages first, keyword lexical
///       match as fallback, whole-chunk truncation only)
///     → unforgeable source IDs ([S1], [S2]…) in the prompt
///     → citation VALIDATION on the model's answer (source ID must exist
///       in the request, page/line must match, snippet must actually
///       appear in the chunk — fabricated citations are dropped, never
///       rendered as real sources)
///
/// Everything here is pure and Sendable — testable without any model or
/// file system.
enum InterpreterDocumentChunker {
    /// Characters per chunk (whole chunks are the truncation unit — a
    /// sentence is never silently cut mid-way).
    static let chunkCharacterLimit = 900
    /// Maximum chunks riding ONE model request (the file-context budget,
    /// independent of the 8-turn/2400-char conversation budget).
    static let maxChunksPerRequest = 8
    /// Overall character ceiling for the document context in a request.
    static let maxContextCharacters = 6000

    // MARK: - Chunk model

    /// One deterministic chunk of a document page.
    struct Chunk: Identifiable, Equatable, Sendable {
        /// Stable chunk id: deterministic UUID over (documentID, page,
        /// blockIndex) — the MaterialPage.deterministicID convention.
        var id: UUID
        var documentID: UUID
        var documentName: String
        var pageNumber: Int
        /// 1-based block index within the page (line-range provenance).
        var blockIndex: Int
        var text: String
        /// Content hash of the text (cache/audit key).
        var contentHash: String

        /// Human label for the prompt and the citation UI.
        var label: String {
            "\(documentName) · 第\(pageNumber)页"
        }
    }

    /// A chunk as it rides ONE request — with its unforgeable source ID.
    /// The mapping (source ID ↔ chunk) exists only within the request
    /// lifecycle; the model can only cite what was actually sent.
    struct RequestSource: Equatable, Sendable {
        /// The prompt-visible source ID ("S1", "S2"…).
        var sourceID: String
        var chunk: Chunk
    }

    // MARK: - Chunking

    /// Splits one page's text into deterministic chunks. Empty/whitespace
    /// lines are dropped (OCR noise); paragraph groups up to the
    /// character limit become chunks; a single block larger than the
    /// limit splits at sentence boundaries (never mid-sentence).
    static func chunks(
        documentID: UUID, documentName: String,
        pageNumber: Int, text: String
    ) -> [Chunk] {
        let normalizedLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !normalizedLines.isEmpty else { return [] }

        // Group lines into blocks at the character limit, never splitting
        // a line in half.
        var blocks: [String] = []
        var current: [String] = []
        var currentLength = 0
        for line in normalizedLines {
            let length = line.count + 1
            if currentLength + length > chunkCharacterLimit, !current.isEmpty {
                blocks.append(current.joined(separator: "\n"))
                current = []
                currentLength = 0
            }
            // A single oversized line splits at sentence boundaries.
            if length > chunkCharacterLimit {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                    currentLength = 0
                }
                blocks.append(contentsOf: splitSentences(line))
                continue
            }
            current.append(line)
            currentLength += length
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }

        return blocks.enumerated().compactMap { index, block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let id = deterministicChunkID(
                documentID: documentID, pageNumber: pageNumber, blockIndex: index
            )
            return Chunk(
                id: id,
                documentID: documentID,
                documentName: documentName,
                pageNumber: pageNumber,
                blockIndex: index + 1,
                text: trimmed,
                contentHash: Self.hash(of: trimmed)
            )
        }
    }

    /// Splits an oversized line at sentence enders (。！？.!?;；
    /// — respects Russian and Chinese conventions). Returns one element
    /// when no boundary exists (the chunk stays oversized rather than
    /// being cut mid-sentence).
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?；;.".contains(character), current.count >= 40 {
                sentences.append(String(current))
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(String(current)) }
        return sentences.count > 1
            ? sentences : (text.isEmpty ? [] : [text])
    }

    // MARK: - Selection

    /// Selection input: which pages the user explicitly chose (empty =
    /// all pages), plus the user's question for lexical fallback ranking.
    struct SelectionRequest: Sendable {
        var chunks: [Chunk]
        /// User-selected page numbers (empty = every page).
        var selectedPages: Set<Int>
        /// The question text (tokenized for the lexical fallback).
        var question: String
    }

    /// Selects the bounded chunk set for one request:
    /// 1. user-chosen pages win (page order);
    /// 2. remaining budget fills by lexical match with the question
    ///    (same token conventions as the conversation context);
    /// 3. hard caps: `maxChunksPerRequest` chunks / `maxContextCharacters`
    ///    characters — whole-chunk truncation only.
    static func selectChunks(_ request: SelectionRequest) -> [Chunk] {
        var chosen: [Chunk] = []
        var total = 0
        if !request.selectedPages.isEmpty {
            for chunk in request.chunks where request.selectedPages.contains(chunk.pageNumber) {
                if chosen.count >= maxChunksPerRequest { break }
                if total + chunk.text.count > maxContextCharacters { continue }
                chosen.append(chunk)
                total += chunk.text.count
            }
        }
        if chosen.count < maxChunksPerRequest {
            let queryTokens = Set(tokenize(request.question))
            let ranked = request.chunks
                .filter { !chosen.contains($0) }
                .map { chunk -> (Chunk, Int) in
                    let chunkTokens = Set(tokenize(chunk.text))
                    let overlap = queryTokens.intersection(chunkTokens).count
                    return (chunk, overlap)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            for (chunk, _) in ranked {
                guard chosen.count < maxChunksPerRequest else { break }
                if total + chunk.text.count > maxContextCharacters { continue }
                chosen.append(chunk)
                total += chunk.text.count
            }
        }
        // No selection basis at all (no chosen pages, no query overlap):
        // leading chunks in page order, so a fresh document is still
        // answerable (the caller confirms what will be sent).
        if chosen.isEmpty {
            for chunk in request.chunks {
                guard chosen.count < maxChunksPerRequest else { break }
                if total + chunk.text.count > maxContextCharacters { continue }
                chosen.append(chunk)
                total += chunk.text.count
            }
        }
        return chosen
    }

    /// Assigns unforgeable source IDs ("S1"…) to the selected chunks.
    static func requestSources(for chunks: [Chunk]) -> [RequestSource] {
        chunks.enumerated().map { index, chunk in
            RequestSource(sourceID: "S\(index + 1)", chunk: chunk)
        }
    }

    // MARK: - Citation validation

    /// A model-returned citation, before validation.
    struct ReturnedCitation: Equatable, Sendable {
        var sourceID: String
        var pageNumber: Int?
        var snippet: String
    }

    /// A validated citation — guaranteed to point at a chunk that was
    /// actually sent in this request.
    struct ValidatedCitation: Equatable, Sendable {
        var sourceID: String
        var documentName: String
        var pageNumber: Int
        var blockIndex: Int
        var snippet: String
    }

    /// Validates the model's citations against the request's source
    /// list. Rules:
    /// 1. the source ID must be one of THIS request's IDs;
    /// 2. the page number, when present, must match the chunk's page;
    /// 3. the snippet, when present, must appear in the chunk's text
    ///    (after whitespace normalization) — a quote the document does
    ///    not contain is fabricated;
    /// invalid citations are DROPPED (never rendered as real sources).
    static func validateCitations(
        _ citations: [ReturnedCitation], against sources: [RequestSource]
    ) -> [ValidatedCitation] {
        let bySource = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        var valid: [ValidatedCitation] = []
        for citation in citations {
            guard let source = bySource[citation.sourceID] else { continue }
            if let page = citation.pageNumber, page != source.chunk.pageNumber {
                continue
            }
            let snippet = citation.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty, !containsNormalized(haystack: source.chunk.text, needle: snippet) {
                continue
            }
            valid.append(ValidatedCitation(
                sourceID: citation.sourceID,
                documentName: source.chunk.documentName,
                pageNumber: source.chunk.pageNumber,
                blockIndex: source.chunk.blockIndex,
                snippet: snippet
            ))
        }
        return valid
    }

    /// Whitespace-insensitive containment check (safe normalization —
    /// OCR line joins and model re-flowing must not reject a real quote).
    static func containsNormalized(haystack: String, needle: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.components(separatedBy: .whitespacesAndNewlines)
                .joined()
                .lowercased()
        }
        return normalize(haystack).contains(normalize(needle))
    }

    // MARK: - Deterministic IDs & hashing

    /// Deterministic chunk id (materialID/page convention): SHA-256 over
    /// the seed, first 16 bytes shaped as a name-based (v5) UUID.
    static func deterministicChunkID(
        documentID: UUID, pageNumber: Int, blockIndex: Int
    ) -> UUID {
        let seed = "\(documentID.uuidString)#\(pageNumber)#\(blockIndex)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let b = Array(digest.prefix(16))
        var bytes = b
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(
            uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                   bytes[4], bytes[5], bytes[6], bytes[7],
                   bytes[8], bytes[9], bytes[10], bytes[11],
                   bytes[12], bytes[13], bytes[14], bytes[15])
        )
    }

    static func hash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Tokenization (the retriever's script-aware conventions)

    /// Russian/Latin words (lowercased, ё→е) and CJK bigrams — the same
    /// tokenizer rules as CourseAssistantRetriever, kept local so the
    /// interpreter domain does not reach into the materials domain.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word: [Character] = []
        var cjk: [Character] = []

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(String(word).lowercased().replacingOccurrences(of: "ё", with: "е"))
            word = []
        }
        func flushCJK() {
            if cjk.count == 1 {
                tokens.append(String(cjk))
            } else if cjk.count > 1 {
                for index in 0..<(cjk.count - 1) {
                    tokens.append(String([cjk[index], cjk[index + 1]]))
                }
            }
            cjk = []
        }

        for character in text {
            if isCJK(character) {
                flushWord()
                cjk.append(character)
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return tokens
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }
}

// MARK: - Sensitive-information masking (隐私预览)

/// Local, deterministic redaction suggestions for the pre-send preview:
/// obvious passport numbers, bank card numbers, phone numbers and email
/// addresses in the SELECTED text are marked and (by default) masked
/// before anything reaches the model.
///
/// This is a best-effort local heuristic — the UI says so explicitly
/// (自动检测只作为建议). It never claims completeness.
enum InterpreterSensitiveMasker {
    struct Match: Equatable, Sendable {
        /// The matched raw text.
        var raw: String
        /// passport | card | phone | email
        var kind: Kind
        /// Character range in the source string.
        var range: Range<String.Index>
    }

    enum Kind: String, CaseIterable, Sendable {
        case passport
        case card
        case phone
        case email

        var displayName: String {
            switch self {
            case .passport: return "疑似护照号"
            case .card: return "疑似银行卡号"
            case .phone: return "疑似手机号"
            case .email: return "疑似邮箱"
            }
        }
    }

    /// Detects sensitive-looking substrings (best-effort heuristics).
    static func detect(in text: String) -> [Match] {
        var matches: [Match] = []
        // Email.
        scan(text, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, kind: .email) {
            matches.append($0)
        }
        // Russian passport: 4 digits + 6 digits (commonly "1234 567890"
        // or "№1234-567890").
        scan(text, pattern: #"(?<![0-9])\d{4}[\s-]?\d{6}(?![0-9])"#, kind: .passport) {
            matches.append($0)
        }
        // Bank card: 13-19 digit groups of 4.
        scan(text, pattern: #"(?<![0-9])(?:\d{4}[\s-]?){3,5}\d{1,4}(?![0-9])"#, kind: .card) {
            matches.append($0)
        }
        // Russian phone: +7/8 followed by 10 digits (groups tolerated).
        scan(text, pattern: #"(?<![0-9])(?:\+7|8)[\s(-]?\d{3}[\s)-]?\d{3}[\s-]?\d{2}[\s-]?\d{2}(?![0-9])"#, kind: .phone) {
            matches.append($0)
        }
        return matches
    }

    private static func scan(
        _ text: String, pattern: String, kind: Kind,
        into: (Match) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        regex.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) { result, _, _ in
            guard let result,
                  let range = Range(result.range, in: text) else { return }
            into(Match(raw: String(text[range]), kind: kind, range: range))
        }
    }

    /// Masks the detected sensitive substrings (first N chars kept as a
    /// hint, the rest as ×). Non-overlapping; later matches skip ranges
    /// already masked.
    static func mask(_ text: String, detected: [Match]) -> String {
        guard !detected.isEmpty else { return text }
        let sorted = detected.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for match in sorted {
            guard match.range.lowerBound >= cursor else { continue } // overlap skip
            result += text[cursor..<match.range.lowerBound]
            let raw = match.raw
            let keep = min(3, raw.count / 4)
            let masked = String(raw.prefix(keep))
                + String(repeating: "×", count: max(1, raw.count - keep))
            result += masked
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            result += text[cursor..<text.endIndex]
        }
        return result
    }

    /// Convenience: detect + mask in one call (the default pre-send
    /// transformation).
    static func masked(_ text: String) -> (masked: String, matches: [Match]) {
        let matches = detect(in: text)
        return (mask(text, detected: matches), matches)
    }
}
