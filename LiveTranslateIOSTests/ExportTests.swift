import XCTest
@testable import LiveTranslateIOS

final class ExportTests: XCTestCase {
    private let start = date(2026, 9, 1, 10, 0, 0)

    private static func date(
        _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int
    ) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        // The exporter's formatters use the local timezone; build the
        // fixture dates in the same one so expectations hold on any host.
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: components)!
    }

    private func makeData() -> TranscriptExportData {
        TranscriptExportData(
            title: "Лекция по алгебре",
            startTime: start,
            endTime: start.addingTimeInterval(3725),
            duration: 3725,
            backend: .coreMLFP16,
            modelVersion: "846833ef",
            computeDescription: "CPU + GPU (accuracy)",
            translationModel: "deepseek-chat",
            entries: [
                ExportEntry(
                    sequenceID: 0,
                    startOffset: 12.34,
                    endOffset: 15.00,
                    originalText: "Здравствуйте, начнём лекцию.",
                    translatedText: "大家好，我们开始上课。",
                    createdAt: start.addingTimeInterval(12.34)
                ),
                ExportEntry(
                    sequenceID: 1,
                    startOffset: 60.0,
                    endOffset: 63.5,
                    originalText: "Сегодня мы изучаем группы.",
                    translatedText: nil,
                    createdAt: start.addingTimeInterval(60)
                ),
            ]
        )
    }

    // MARK: - Markdown

    func testMarkdownContent() {
        let text = TranscriptExporter.export(makeData(), format: .markdown)
        XCTAssertTrue(text.hasPrefix("# Лекция по алгебре"))
        XCTAssertTrue(text.contains("- Start: 2026-09-01 10:00:00"))
        XCTAssertTrue(text.contains("- End: 2026-09-01 11:02:05"))
        XCTAssertTrue(text.contains("- Duration: 1:02:05"))
        XCTAssertTrue(text.contains("- Model: GigaAM-v3 e2e_rnnt"))
        XCTAssertTrue(text.contains("- ASR backend: GigaAM-v3 e2e_rnnt · Core ML FP16"))
        XCTAssertTrue(text.contains("- Compute: CPU + GPU (accuracy)"))
        XCTAssertTrue(text.contains("- Translation model: deepseek-chat"))
        XCTAssertTrue(text.contains("**[00:12]** Здравствуйте, начнём лекцию."))
        XCTAssertTrue(text.contains("大家好，我们开始上课。"))
        // Entry without translation still lists the original.
        XCTAssertTrue(text.contains("**[01:00]** Сегодня мы изучаем группы."))
    }

    func testMarkdownContainsNoSecrets() {
        let text = TranscriptExporter.export(makeData(), format: .markdown)
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains("sk-"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    // MARK: - TXT

    func testBilingualTXT() {
        let text = TranscriptExporter.export(makeData(), format: .bilingualTXT)
        XCTAssertTrue(text.contains("[00:12] Здравствуйте, начнём лекцию."))
        XCTAssertTrue(text.contains("→ 大家好，我们开始上课。"))
        XCTAssertTrue(text.contains("[01:00] Сегодня мы изучаем группы."))
    }

    func testRussianTXT() {
        let text = TranscriptExporter.export(makeData(), format: .russianTXT)
        XCTAssertTrue(text.contains("[00:12] Здравствуйте, начнём лекцию."))
        XCTAssertFalse(text.contains("大家好"))
        XCTAssertFalse(text.contains("→"))
    }

    func testChineseTXT() {
        let text = TranscriptExporter.export(makeData(), format: .chineseTXT)
        XCTAssertTrue(text.contains("[00:12] 大家好，我们开始上课。"))
        XCTAssertFalse(text.contains("Здравствуйте"))
    }

    // MARK: - SRT

    func testSRTFormat() {
        let text = TranscriptExporter.export(makeData(), format: .srt)
        let expected = """
        1
        00:00:12,340 --> 00:00:15,000
        Здравствуйте, начнём лекцию.
        大家好，我们开始上课。

        2
        00:01:00,000 --> 00:01:03,500
        Сегодня мы изучаем группы.

        """
        XCTAssertEqual(text, expected)
    }

    func testSRTTimestampBoundaries() {
        XCTAssertEqual(TranscriptExporter.srtTimestamp(0), "00:00:00,000")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(12.34), "00:00:12,340")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(3600.5), "01:00:00,500")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(-5), "00:00:00,000")
        // Rounding, not truncation.
        XCTAssertEqual(TranscriptExporter.srtTimestamp(1.9995), "00:00:02,000")
    }

    func testMMSS() {
        XCTAssertEqual(TranscriptExporter.mmss(0), "00:00")
        XCTAssertEqual(TranscriptExporter.mmss(65), "01:05")
        // Past an hour the minutes keep counting: no silent wrap.
        XCTAssertEqual(TranscriptExporter.mmss(3725), "62:05")
    }

    // MARK: - JSON

    func testJSONRoundTrip() throws {
        let text = TranscriptExporter.export(makeData(), format: .json)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Лекция по алгебре")
        XCTAssertEqual(object["model"] as? String, "GigaAM-v3 e2e_rnnt")
        XCTAssertEqual(object["backend"] as? String, "coreMLFP16")
        XCTAssertEqual(object["compute"] as? String, "CPU + GPU (accuracy)")
        XCTAssertEqual(object["entryCount"] as? Int, 2)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["sequenceID"] as? Int, 0)
        XCTAssertEqual(entries[0]["originalText"] as? String, "Здравствуйте, начнём лекцию.")
        XCTAssertEqual(entries[0]["translatedText"] as? String, "大家好，我们开始上课。")
        XCTAssertNil(entries[1]["translatedText"])
        // `start` is built in the local timezone (the markdown formatters
        // use it); the JSON stamp must carry the same instant in UTC ISO
        // form, whatever the host timezone is.
        let stamp = try XCTUnwrap(object["startTime"] as? String)
        XCTAssertTrue(stamp.hasSuffix("Z"), "expected a UTC stamp, got \(stamp)")
        let parsed = try XCTUnwrap(
            ISO8601DateFormatter().date(from: stamp),
            "startTime is not a parseable ISO-8601 instant: \(stamp)"
        )
        XCTAssertEqual(parsed.timeIntervalSinceReferenceDate, start.timeIntervalSinceReferenceDate,
                       accuracy: 1.0)
    }

    // MARK: - File naming

    func testSuggestedFileNameSanitizesTitle() {
        let name = TranscriptExporter.suggestedFileName(
            title: "Лекция: Алгебра/Группы?",
            format: .markdown,
            date: start
        )
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertTrue(name.contains("20260901-1000"))
    }

    func testEmptyTitleFallsBack() {
        let name = TranscriptExporter.suggestedFileName(
            title: "///",
            format: .srt,
            date: start
        )
        XCTAssertTrue(name.hasPrefix("LiveTranslate-Classroom-"))
        XCTAssertTrue(name.hasSuffix(".srt"))
    }

    func testWriteTemporaryFile() throws {
        let url = try TranscriptExporter.writeTemporaryFile(
            data: makeData(), format: .json
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("Лекция по алгебре"))
    }

    func testFormatMetadata() {
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.bilingualTXT.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")
        XCTAssertEqual(ExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportFormat.allCases.count, 6)
    }
}
