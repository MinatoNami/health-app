import XCTest

/// Photographs the screens that a renderer cannot draw.
///
/// `InsightsRenderTests` covers the pieces that are plain SwiftUI, but a `Form`
/// and a `List` are UIKit-backed and `ImageRenderer` produces nothing for
/// either. Settings is the one restyled screen reachable with no server and no
/// account, so it is the one that can be checked this way — a real screenshot
/// of the real screen, on the palette it is supposed to be wearing.
///
/// Unlike `ScreenshotTests` this does not skip: it needs no fixture server, so
/// it should run and fail on an ordinary `xcodebuild test`.
final class AppearanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissOnboardingIfPresent()
    }

    /// The first-run cover is once-per-install and the simulator may or may not
    /// have seen it. Neither case should fail this test.
    private func dismissOnboardingIfPresent() {
        let later = app.buttons["Do this later"].firstMatch
        let notNow = app.buttons["Not now"].firstMatch
        let choose = app.buttons["Choose what to share"].firstMatch
        for _ in 0..<4 {
            if app.tabBars.buttons["Today"].exists { return }
            if later.exists { later.tap(); continue }
            if notNow.exists { notNow.tap(); continue }
            if choose.exists { choose.tap(); continue }
            _ = app.tabBars.buttons["Today"].waitForExistence(timeout: 3)
        }
        // A startup alert about an unreachable server can sit over everything.
        let keepGoing = app.alerts.buttons["Continue Offline"].firstMatch
        if keepGoing.waitForExistence(timeout: 2) { keepGoing.tap() }
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSettingsWearsThePalette() throws {
        XCTAssertTrue(app.tabBars.buttons["Data"].waitForExistence(timeout: 20),
                      "never reached the tab bar")
        app.tabBars.buttons["Data"].tap()

        let row = app.staticTexts["Account, brief & diagnostics"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Settings row is not on Data")
        row.tap()

        XCTAssertTrue(app.textFields["https://your-server"].firstMatch.waitForExistence(timeout: 10),
                      "Settings did not open")
        capture("settings-top")

        // The destructive rows are at the bottom, and they are the ones wearing
        // the new colour.
        for _ in 0..<10 { app.swipeUp() }
        capture("settings-bottom")
    }

    /// The screens pushed off Settings and Data.
    ///
    /// None of them had a design board, and until now none of them had the
    /// palette either — so tapping a row on a restyled Settings landed you on
    /// system grey. All are reachable with no server and no account.
    func testPushedScreensWearThePalette() throws {
        XCTAssertTrue(app.tabBars.buttons["Data"].waitForExistence(timeout: 20))

        app.tabBars.buttons["Data"].tap()
        capture("data-tab")

        push(from: "Data", into: "Metric groups", as: "metrics")

        for (row, name) in [("Morning brief", "daily-brief"),
                            ("How insights work", "insights-about"),
                            ("Batch Files & Log", "exports")] {
            app.tabBars.buttons["Data"].tap()
            let settings = app.staticTexts["Account, brief & diagnostics"].firstMatch
            if settings.waitForExistence(timeout: 8) { settings.tap() }
            push(from: "Settings", into: row, as: name)
        }
    }

    /// Taps a row by label, waits for the push to settle, photographs it.
    /// Scrolls to find the row — several of these are below the fold.
    private func push(from screen: String, into row: String, as name: String) {
        var target = app.buttons[row].firstMatch
        if !target.exists { target = app.staticTexts[row].firstMatch }
        for _ in 0..<8 where !target.isHittable {
            app.swipeUp()
            if !target.exists { target = app.staticTexts[row].firstMatch }
        }
        guard target.isHittable else {
            XCTFail("could not reach \(row) from \(screen)")
            return
        }
        target.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 6)
        Thread.sleep(forTimeInterval: 1.2)
        capture(name)
    }
}
