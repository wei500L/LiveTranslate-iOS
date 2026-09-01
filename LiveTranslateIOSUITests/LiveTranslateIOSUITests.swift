import XCTest

/// Smoke UI test: the app launches and shows the three tabs. Translation and
/// model download flows are intentionally not exercised here — they depend on
/// models/network and are covered by integration tests and manual runs.
final class LiveTranslateIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsExist() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).exists)
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 1).exists)
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 2).exists)
    }
}
