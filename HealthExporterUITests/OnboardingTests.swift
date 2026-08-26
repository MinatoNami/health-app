import XCTest

/// The one screen every user is guaranteed to see, and the one flow that by
/// construction happens once per install — which is what makes it worth a test.
/// The flag that suppresses it after the first run is the likeliest thing here
/// to break, in either direction: a screen that never appears, or one that
/// appears every launch.
///
/// Unlike `ScreenshotTests` this needs no server. Onboarding runs before any of
/// that exists, which is rather the point of it.
final class OnboardingTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetFirstRun"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        dismissServerAlertIfPresent()
    }

    /// A real first run has no server configured and so cannot raise the
    /// unreachable alert. A simulator carrying a dead URL from an earlier test
    /// can — and it arrives *after* launch, on top of the onboarding cover, so
    /// a one-shot check before it exists misses it.
    private func dismissServerAlertIfPresent() {
        let keepGoing = app.alerts.buttons["Continue Offline"].firstMatch
        if keepGoing.waitForExistence(timeout: 2) { keepGoing.tap() }
    }

    /// Waits for the intro, clearing anything that lands on top of it.
    @discardableResult
    private func waitForIntro(timeout: TimeInterval = 25) -> Bool {
        let intro = app.staticTexts["Your health data, on a server you own."]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if intro.exists { return true }
            dismissServerAlertIfPresent()
        }
        return intro.exists
    }

    func testTheFlowReachesTheGroupPicker() throws {
        // 1 — the intro
        XCTAssertTrue(waitForIntro(), "onboarding did not appear on a reset first run")
        capture("Onboarding")

        // The warning that justifies the whole flow existing.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'once, ever'")
        ).firstMatch.exists, "the once-ever warning is missing")

        app.buttons["Choose what to share"].tap()

        // 2 — the groups, with the request button beneath them
        let request = app.buttons["Request Health Access"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10), "group picker did not appear")
        XCTAssertTrue(request.isEnabled, "groups ship enabled by default, so this should be live")
        capture("OnboardingTypes")

        // Stops here deliberately. Tapping Request puts up the system Health
        // sheet, which XCUITest cannot reach — see
        // `testServerStepRendersAndFinishes` for the far side of it.
    }

    func testItDoesNotComeBack() throws {
        XCTAssertTrue(waitForIntro())
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15))

        // Relaunch *without* the reset argument: the flag has to survive.
        app.terminate()
        app.launchArguments = []
        app.launch()
        dismissServerAlertIfPresent()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 20),
                      "the app did not come back up")
        XCTAssertFalse(
            app.staticTexts["Your health data, on a server you own."].exists,
            "onboarding reappeared after being dismissed"
        )
    }

    /// Step three, entered directly.
    ///
    /// The natural route runs through `requestAuthorization`, which puts up a
    /// system Health sheet that is not in this app's element tree — XCUITest
    /// cannot see it, let alone dismiss it. So the step in between is the one
    /// piece of this flow that stays unautomated, and this covers what lies on
    /// the far side of it.
    func testServerStepRendersAndFinishes() throws {
        app.terminate()
        app.launchArguments = ["-resetFirstRun", "-onboardingStep=connect"]
        app.launch()
        dismissServerAlertIfPresent()

        let server = app.staticTexts["Now point it somewhere."]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !server.exists { dismissServerAlertIfPresent() }
        XCTAssertTrue(server.exists, "the server step did not render")
        XCTAssertTrue(app.buttons["Connect a server"].exists)
        capture("OnboardingServer")

        app.buttons["Do this later"].tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15),
                      "finishing onboarding did not reveal the app")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
