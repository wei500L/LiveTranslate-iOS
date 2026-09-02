import XCTest

/// Production walkthrough driver — NOT a functional test suite.
///
/// An automated session cannot synthesize taps on this host (no
/// accessibility permission), so this test is the "finger": it launches
/// the app with NO launch arguments (real production mode, no demo data)
/// and performs the same taps a human reviewer would, attaching a
/// screenshot at every step. Everything observed afterwards is the real
/// production app running the real pipeline — this file adds no app-side
/// hooks and asserts nothing beyond element existence so the walk can
/// proceed.
final class ProductionWalkthroughTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProductionWalkthrough() throws {
        let app = XCUIApplication()
        app.launch() // no launch arguments → production mode

        // ---- Home ------------------------------------------------------
        let startCard = app.buttons["开始新课堂"]
        XCTAssertTrue(startCard.waitForExistence(timeout: 15), "home start card missing")
        snap(app, "01-home")

        // ---- New-session sheet -----------------------------------------
        startCard.tap()
        let startButton = app.buttons["开始课堂"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5), "new-session sheet missing")
        snap(app, "02-newsession-empty")

        let field = app.textFields.firstMatch
        field.tap()
        field.typeText("Algebra Lecture 01")
        // Dismiss the keyboard so the start button is clearly tappable.
        let hideKeyboard = app.buttons["收起键盘"]
        if hideKeyboard.waitForExistence(timeout: 2) { hideKeyboard.tap() }
        snap(app, "03-newsession-filled")

        // ---- Start the real classroom -----------------------------------
        startButton.tap()

        // The coordinator loads the real model (Core ML cpu-only in the
        // simulator) before entering the listening phase — allow a generous
        // window. The phase chip is a plain Text (StatusChip).
        let listening = app.staticTexts["正在监听俄语"]
        XCTAssertTrue(
            listening.waitForExistence(timeout: 120),
            "classroom never reached the listening phase"
        )
        snap(app, "04-live-listening")

        // ---- Listen: real mic → VAD → ASR -------------------------------
        // Russian speech is played through the host speakers during this
        // window (driven from the host side); the pipeline transcribes
        // whatever the microphone actually picks up.
        Thread.sleep(forTimeInterval: 16)
        snap(app, "05-live-listening-16s")
        Thread.sleep(forTimeInterval: 64)
        snap(app, "06-live-listening-80s")

        // ---- Pause / resume ---------------------------------------------
        app.buttons["暂停"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        snap(app, "07-live-paused")
        app.buttons["继续"].firstMatch.tap()
        XCTAssertTrue(listening.waitForExistence(timeout: 10))
        snap(app, "08-live-resumed")

        // ---- End the classroom ------------------------------------------
        // The stop control and the confirmation-dialog button share the
        // label 结束课堂; after the dialog is up the dialog button is the
        // last match in the accessibility hierarchy.
        app.buttons["结束课堂"].firstMatch.tap()
        let cancelItem = app.buttons["继续听课"]
        XCTAssertTrue(cancelItem.waitForExistence(timeout: 5), "end confirmation dialog missing")
        snap(app, "09-end-dialog")
        let endButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "结束课堂")
        ).allElementsBoundByIndex
        endButtons.last?.tap()

        let finished = app.buttons["课堂已结束 · 返回首页"]
        XCTAssertTrue(finished.waitForExistence(timeout: 15), "classroom never finished")
        snap(app, "10-live-finished")
        finished.tap()

        // ---- Home again (recent classroom should now be real) -----------
        XCTAssertTrue(startCard.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2) // let onAppear reload finish
        snap(app, "11-home-after-class")

        // ---- Records tab -------------------------------------------------
        let tabBar = app.otherElements["主导航"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "floating tab bar missing")
        tabBar.buttons["课堂记录"].tap()
        Thread.sleep(forTimeInterval: 2)
        snap(app, "12-records")

        // ---- Session detail ----------------------------------------------
        let row = app.staticTexts["Algebra Lecture 01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "session row missing in records")
        row.tap()
        Thread.sleep(forTimeInterval: 2)
        snap(app, "13-session-detail")
        // The detail screen has its own section tabs; show the notes view
        // (real saved bilingual content, never generated filler).
        let notesTab = app.buttons["课堂笔记"].firstMatch
        if notesTab.exists { notesTab.tap(); Thread.sleep(forTimeInterval: 1); }
        snap(app, "14-session-detail-notes")

        // ---- Bookmarks tab ------------------------------------------------
        tabBar.buttons["书签"].tap()
        Thread.sleep(forTimeInterval: 2)
        snap(app, "15-bookmarks")

        // ---- Search tab ----------------------------------------------------
        tabBar.buttons["搜索"].tap()
        Thread.sleep(forTimeInterval: 1)
        snap(app, "16-search-empty")
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 4) {
            searchField.tap()
            searchField.typeText("Algebra")
            Thread.sleep(forTimeInterval: 2)
            snap(app, "17-search-result")
        }

        // ---- Profile / settings tab -----------------------------------------
        tabBar.buttons["我的"].tap()
        Thread.sleep(forTimeInterval: 2)
        snap(app, "18-settings")
    }
}
