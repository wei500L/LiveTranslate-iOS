import XCTest
@testable import LiveTranslateIOS

/// `GigaAMTokenDecoder` behavior: piece join, `▁` → space, byte fallback,
/// space collapsing, vocabulary guards. Uses a synthetic 1025-entry
/// vocabulary — real `tokens.json` is model metadata and must not be
/// committed to the repo (it is exercised by the integration tests).
final class GigaAMTokenDecoderTests: XCTestCase {
    /// Builds a 1025-piece vocabulary where the given indices map to the
    /// given pieces (everything else is an inert filler piece).
    private func makeVocabulary(_ mapping: [Int: String]) throws -> GigaAMTokenDecoder {
        var pieces = [String](repeating: "<filler>", count: GigaAMTokenDecoder.vocabularySize)
        for (index, piece) in mapping {
            pieces[index] = piece
        }
        return try GigaAMTokenDecoder(pieces: pieces)
    }

    func testVocabularySizeGuard() {
        XCTAssertThrowsError(try GigaAMTokenDecoder(pieces: ["<s>", "</s>"])) { error in
            guard case GigaAMTokenDecoder.TokenDecoderError.unexpectedVocabularySize(let count) = error
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(count, 2)
        }
    }

    /// The pinned Core ML export (`smkrv/gigaam-v3-e2e-rnnt-coreml`) ships
    /// exactly the 1024 real pieces with the blank (id 1024) implicit — the
    /// decoder must accept that shape, and the implicit blank must decode
    /// to nothing instead of leaking a missing piece.
    func testPinnedExportVocabularyWithImplicitBlank() throws {
        var pieces = [String](repeating: "<filler>", count: GigaAMTokenDecoder.blankID)
        pieces[0] = "▁привет"
        pieces[1023] = "!"
        let decoder = try GigaAMTokenDecoder(pieces: pieces)
        XCTAssertEqual(decoder.decode(ids: [0, 1023]), "привет!")
        XCTAssertEqual(decoder.decode(ids: [1024]), "")
    }

    func testPlainPieceJoin() throws {
        let decoder = try makeVocabulary([0: "Прив", 1: "ет", 2: ".", 3: "!"])
        XCTAssertEqual(decoder.decode(ids: [0, 1, 2, 3]), "Привет.!")
    }

    func testUnderscoreBecomesSpace() throws {
        let decoder = try makeVocabulary([0: "▁Привет", 1: "▁мир", 2: "!"])
        XCTAssertEqual(decoder.decode(ids: [0, 1, 2]), "Привет мир!")
    }

    func testLeadingUnderscoreIsTrimmed() throws {
        let decoder = try makeVocabulary([0: "▁Здравствуйте", 1: "."])
        XCTAssertEqual(decoder.decode(ids: [0, 1]), "Здравствуйте.")
    }

    func testSpaceRunsCollapse() throws {
        let decoder = try makeVocabulary([0: "▁▁a", 1: "▁", 2: "▁b"])
        XCTAssertEqual(decoder.decode(ids: [0, 1, 1, 2]), "a b")
    }

    func testTrailingSpaceIsTrimmed() throws {
        let decoder = try makeVocabulary([0: "a", 1: "▁"])
        XCTAssertEqual(decoder.decode(ids: [0, 1]), "a")
    }

    /// SentencePiece byte fallback: multi-byte UTF-8 characters arrive as a
    /// run of `<0xNN>` pieces. "П" is D0 9F in UTF-8.
    func testByteFallbackAccumulatesUTF8() throws {
        let decoder = try makeVocabulary([0: "<0xD0>", 1: "<0x9F>", 2: "▁текст"])
        XCTAssertEqual(decoder.decode(ids: [0, 1, 2]), "П текст")
    }

    /// A byte-fallback run interrupted by a normal piece flushes the pending
    /// bytes first (mirrors SentencePiece's incremental decoding).
    func testByteFallbackFlushesBeforePlainPiece() throws {
        let decoder = try makeVocabulary([0: "<0xD0>", 1: "<0x9F>", 2: "a", 3: "<0xD0>", 4: "<0xA0>"])
        // П a Р
        XCTAssertEqual(decoder.decode(ids: [0, 1, 2, 3, 4]), "ПaР")
    }

    /// Invalid UTF-8 byte sequences decode with U+FFFD replacement, never
    /// crash (defensive — the model should not emit these, but a truncated
    /// hypothesis could).
    func testByteFallbackInvalidUTF8DoesNotCrash() throws {
        let decoder = try makeVocabulary([0: "<0xFF>", 1: "<0xFE>"])
        let text = decoder.decode(ids: [0, 1])
        XCTAssertFalse(text.isEmpty)
    }

    func testOutOfRangeAndBlankIDsAreSkipped() throws {
        let decoder = try makeVocabulary([0: "a", 1: "b"])
        // -1, 1025 (vocab size), 2000 out of range; 1024 is the blank.
        XCTAssertEqual(decoder.decode(ids: [-1, 0, 1025, 1, 2000, 1024]), "ab")
    }

    func testEmptyHypothesisDecodesToEmptyString() throws {
        let decoder = try makeVocabulary([0: "a"])
        XCTAssertEqual(decoder.decode(ids: []), "")
    }

    func testByteFallbackValueParsing() {
        XCTAssertEqual(GigaAMTokenDecoder.byteFallbackValue("<0x41>"), 0x41)
        XCTAssertEqual(GigaAMTokenDecoder.byteFallbackValue("<0xff>"), 0xFF)
        XCTAssertEqual(GigaAMTokenDecoder.byteFallbackValue("<0xAF>"), 0xAF)
        // Not byte-fallback pieces:
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("▁hello"))
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("<0x1>"))     // two hex digits required
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("<0xGG>"))
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("0x41"))      // brackets required
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("<0x411>"))   // trailing junk
        XCTAssertNil(GigaAMTokenDecoder.byteFallbackValue("<0x41"))     // unclosed
    }

    func testCollapseSpaces() {
        XCTAssertEqual(GigaAMTokenDecoder.collapseSpaces("  a  b  "), "a b")
        XCTAssertEqual(GigaAMTokenDecoder.collapseSpaces(""), "")
        XCTAssertEqual(GigaAMTokenDecoder.collapseSpaces("   "), "")
        XCTAssertEqual(GigaAMTokenDecoder.collapseSpaces("a b c"), "a b c")
    }
}
