import XCTest
@testable import LiveTranslateIOS

final class SSEParserTests: XCTestCase {
    func testWholeStreamAtOnce() {
        var parser = SSEParser()
        // Built with explicit terminators: a multiline literal cannot end in
        // a newline, which would silently drop the blank line after [DONE].
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"Привет\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\" мир\"}}]}\n\n"
            + "data: [DONE]\n\n"
        let payloads = parser.feed(stream)
        XCTAssertEqual(payloads, [
            "{\"choices\":[{\"delta\":{\"content\":\"Привет\"}}]}",
            "{\"choices\":[{\"delta\":{\"content\":\" мир\"}}]}",
            "[DONE]",
        ])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testByteSplitAcrossChunks() {
        var parser = SSEParser()
        // Split mid-line and inside a multi-byte UTF-8 character, as an
        // incremental line stream can deliver.
        let line1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Здравствуйте\"}}]}"
        let line2 = "data: [DONE]"
        var collected: [String] = []
        for char in line1 + "\n\n" + line2 + "\n\n" {
            collected += parser.feed(String(char))
        }
        XCTAssertEqual(collected, [String(line1.dropFirst("data: ".count)), "[DONE]"])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testCRLFLineEndings() {
        var parser = SSEParser()
        let payloads = parser.feed("data: one\r\n\r\ndata: two\r\n\r\n")
        XCTAssertEqual(payloads, ["one", "two"])
    }

    func testCommentLinesIgnored() {
        var parser = SSEParser()
        let payloads = parser.feed(": keep-alive\r\n\r\ndata: real\r\n\r\n")
        XCTAssertEqual(payloads, ["real"])
    }

    func testFinalEventWithoutBlankLine() {
        var parser = SSEParser()
        var payloads = parser.feed("data: first\n\ndata: last")
        XCTAssertEqual(payloads, ["first"])
        payloads = parser.finish()
        XCTAssertEqual(payloads, ["last"])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testMultilineDataFieldsJoined() {
        var parser = SSEParser()
        let payloads = parser.feed("data: a\ndata: b\n\n")
        XCTAssertEqual(payloads, ["a\nb"])
    }

    func testDataWithoutSpaceAfterColon() {
        var parser = SSEParser()
        let payloads = parser.feed("data:{\"x\":1}\n\n")
        XCTAssertEqual(payloads, ["{\"x\":1}"])
    }

    func testUnknownFieldsIgnored() {
        var parser = SSEParser()
        let payloads = parser.feed("event: chunk\nid: 7\ndata: payload\n\n")
        XCTAssertEqual(payloads, ["payload"])
    }
}
