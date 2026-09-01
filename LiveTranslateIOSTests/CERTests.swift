import XCTest
@testable import LiveTranslateIOS

/// CER/WER metric tests — the math the backend comparison report is built on.
final class CERTests: XCTestCase {
    func testIdenticalTextsGiveZeroCER() {
        XCTAssertEqual(TextMetrics.cer(hypothesis: "Привет, мир!", reference: "Привет, мир!"), 0)
    }

    func testCaseAndPunctuationAreNormalized() {
        // Same sentence with different case and punctuation → CER 0.
        XCTAssertEqual(
            TextMetrics.cer(hypothesis: "привет мир", reference: "ПРИВЕТ, МИР!"),
            0, accuracy: 1e-9
        )
    }

    func testKnownEditDistance() {
        // "кот" vs "код": one substitution of 3 reference chars → 1/3.
        XCTAssertEqual(TextMetrics.cer(hypothesis: "код", reference: "кот"), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testWhitespaceCollapsing() {
        XCTAssertEqual(TextMetrics.cer(hypothesis: "а  б\tв", reference: "а б  в"), 0, accuracy: 1e-9)
    }

    func testPunctuationStrippedComparison() {
        // Punctuation differences alone must not count when requested.
        XCTAssertEqual(
            TextMetrics.cer(hypothesis: "Да, конечно.", reference: "Да конечно", stripPunctuation: true),
            0, accuracy: 1e-9
        )
        // But they DO count in the default (normalized keeps nothing) mode —
        // normalization always strips punctuation by default here, so verify
        // the difference survives via the char set only through stripPunctuation: false.
        XCTAssertGreaterThan(
            TextMetrics.cer(hypothesis: "Да, конечно.", reference: "Да конечно", stripPunctuation: false),
            0
        )
    }

    func testEmptyReferenceIsTotalMismatch() {
        XCTAssertEqual(TextMetrics.cer(hypothesis: "текст", reference: ""), 1)
        XCTAssertEqual(TextMetrics.cer(hypothesis: "", reference: ""), 0)
    }

    func testDeletionCounts() {
        // Hypothesis missing one of four reference chars → 1/4.
        XCTAssertEqual(TextMetrics.cer(hypothesis: "абг", reference: "абвг"), 0.25, accuracy: 1e-9)
    }

    func testInsertionCounts() {
        // Hypothesis has one extra char vs reference of three → 1/3.
        XCTAssertEqual(TextMetrics.cer(hypothesis: "абвг", reference: "абв"), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testWERIdentical() {
        XCTAssertEqual(TextMetrics.wer(hypothesis: "один два три", reference: "один два три"), 0)
    }

    func testWERWordSubstitution() {
        // 3 reference words, one wrong → 1/3.
        XCTAssertEqual(TextMetrics.wer(hypothesis: "один два четыре", reference: "один два три"), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testWEREmptyReference() {
        XCTAssertEqual(TextMetrics.wer(hypothesis: "слово", reference: ""), 1)
    }

    func testEditDistanceBasics() {
        XCTAssertEqual(TextMetrics.editDistance(Array("abc"), Array("abc")), 0)
        XCTAssertEqual(TextMetrics.editDistance(Array("abc"), Array("abd")), 1)
        XCTAssertEqual(TextMetrics.editDistance(Array(""), Array("xyz")), 3)
        XCTAssertEqual(TextMetrics.editDistance(Array("kitten"), Array("sitting")), 3)
    }

    func testCharacterDiffSummary() {
        XCTAssertEqual(TextMetrics.characterDiffSummary("абв", "абв"), "identical")
        XCTAssertTrue(TextMetrics.characterDiffSummary("абвгде", "абв").contains("+"))
        XCTAssertTrue(TextMetrics.characterDiffSummary("абв xyz", "абв abc").contains("↔"))
    }

    func testRussianCaseFolding() {
        // Cyrillic uppercase folds the same as Latin.
        XCTAssertEqual(
            TextMetrics.cer(hypothesis: "москва", reference: "МОСКВА"),
            0, accuracy: 1e-9
        )
    }
}
