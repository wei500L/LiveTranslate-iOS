import XCTest

/// Smoke UI test: the app launches and shows the five custom floating-tab
/// navigation items. Translation and model download flows are intentionally
/// not exercised here — they depend on models/network and are covered by
/// integration tests and manual runs.
final class LiveTranslateIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsExist() throws {
        let app = XCUIApplication()
        app.launch()

        // The floating tab bar is custom SwiftUI, not a UITabBar, so match
        // by accessibility labels.
        let tabBar = app.otherElements["主导航"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        for title in ["首页", "课堂记录", "书签", "搜索", "我的"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "Missing tab \(title)")
        }
    }
}
