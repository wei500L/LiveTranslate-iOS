import Foundation

/// Local, explainable retrieval over one course's study material — the
/// source-selection stage of 问这门课. No vector database, no embedding
/// dependency, no network: TF-IDF over a tokenized corpus, where the
/// tokenizer understands the three scripts the product actually meets
/// (Russian/Latin words, CJK bigrams, and their mix in one line).
///
/// Every chunk keeps its source identity (material+page, session+entry,
/// note, attachment, review, learning row) so a retrieved hit can become
/// a clickable citation — a chunk without provenance is never built.
enum CourseAssistantRetriever {
    /// One retrievable unit of course content with its provenance.
    struct SourceChunk: Sendable, Equatable {
        var kind: AssistantCitationKind
        /// Human label (材料名 · 第n页 / 课堂名 · 03:12 …).
        var label: String
        var text: String
        var materialID: UUID?
        var pageNumber: Int?
        var sessionID: UUID?
        var entryID: UUID?
        var noteID: UUID?
        var attachmentID: UUID?
        var reviewID: UUID?
    }

    /// A scored hit — the citation candidate.
    struct ScoredChunk: Sendable, Equatable, Identifiable {
        var number: Int
        var chunk: SourceChunk
        var score: Double

        var id: Int { number }
    }

    // MARK: - Tokenization

    /// Russian/Latin words (lowercased, ё→е, dashes kept inside words)
    /// and CJK character bigrams (unigram fallback for a single CJK
    /// char). Punctuation and whitespace split. Deterministic — the same
    /// text always yields the same tokens on every device.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        tokens.reserveCapacity(text.count / 4 + 2)
        var word: [Character] = []
        var cjk: [Character] = []

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(normalizeWord(String(word)))
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

        for char in text {
            if isCJK(char) {
                flushWord()
                cjk.append(char)
            } else if char.isLetter || char.isNumber || char == "-" || char == "ё" || char == "Ё" {
                if cjk.isEmpty == false && (char == "-" ) {
                    // A dash between CJK segments terminates the run.
                    flushCJK()
                }
                word.append(char)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return tokens
    }

    private static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func normalizeWord(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Scoring

    /// TF-IDF ranking of the chunks against the query. Chunks whose
    /// score is zero (no query token present) are never returned — the
    /// no-evidence path is a real retrieval outcome, not an error.
    /// - Parameters:
    ///   - query: the user's question (tokenized internally).
    ///   - chunks: the scope's source chunks.
    ///   - limit: how many hits to return (the prompt's context budget).
    static func search(
        query: String, chunks: [SourceChunk], limit: Int = 12
    ) -> [ScoredChunk] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty, !chunks.isEmpty else { return [] }

        // Pre-tokenize the corpus once; document frequencies ride along.
        var tokenized: [(chunk: SourceChunk, tokens: [String])] = []
        tokenized.reserveCapacity(chunks.count)
        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            let tokens = tokenize(chunk.text)
            guard !tokens.isEmpty else { continue }
            tokenized.append((chunk, tokens))
            for token in Set(tokens) {
                documentFrequency[token, default: 0] += 1
            }
        }
        guard !tokenized.isEmpty else { return [] }
        let totalDocuments = Double(tokenized.count)

        // Query terms that appear NOWHERE are uninformative for ranking
        // (they still matter for the empty-result decision below).
        let querySet = Array(Set(queryTokens))
        var scored: [(chunk: SourceChunk, score: Double)] = []
        scored.reserveCapacity(tokenized.count)
        for (chunk, tokens) in tokenized {
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            var score = 0.0
            var matched = false
            for token in querySet {
                guard let count = counts[token], count > 0 else { continue }
                matched = true
                let idf = log(1.0 + totalDocuments / (1.0 + Double(documentFrequency[token] ?? 0)))
                let tf = Double(count)
                score += tf * idf
            }
            guard matched else { continue }
            // Length normalization: a long page must not win purely by
            // being long.
            let length = Double(max(tokens.count, 8))
            scored.append((chunk, score / sqrt(length)))
        }
        guard !scored.isEmpty else { return [] }

        // Deduplicate by identical provenance+text so one repeated line
        // cannot fill the whole context.
        var seen = Set<String>()
        var unique: [(chunk: SourceChunk, score: Double)] = []
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            let key = [
                entry.chunk.kind.rawValue,
                entry.chunk.materialID?.uuidString ?? "",
                String(entry.chunk.pageNumber ?? 0),
                entry.chunk.sessionID?.uuidString ?? "",
                entry.chunk.entryID?.uuidString ?? "",
                entry.chunk.noteID?.uuidString ?? "",
                entry.chunk.attachmentID?.uuidString ?? "",
                entry.chunk.reviewID?.uuidString ?? "",
                String(entry.chunk.text.hashValue),
            ].joined(separator: "#")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(entry)
        }

        return unique.prefix(limit).enumerated().map { index, entry in
            ScoredChunk(number: index + 1, chunk: entry.chunk, score: entry.score)
        }
    }
}
