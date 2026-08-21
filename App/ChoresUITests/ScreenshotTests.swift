import XCTest

/// Captures the App Store screenshots. Driven by `tools/screenshots.sh`, which
/// runs it once per listing language.
///
/// These are not tests, and they assert only enough to know that what they
/// photographed is the screen they meant. They live in the test target because
/// XCUITest is the only thing that can drive the app to a particular screen and
/// take a picture of it — there is no other supported way to get an App Store
/// screenshot out of a simulator.
///
/// **They skip unless `SCREENSHOTS=1` is set in the test runner's environment**,
/// so `xcodebuild test` on the whole scheme stays a test run: five extra photo
/// sessions in it would double its length and prove nothing. The script sets
/// `TEST_RUNNER_SCREENSHOTS=1`, which xcodebuild forwards to the runner with the
/// prefix stripped.
///
/// Navigation here goes through accessibility identifiers and tab indices, never
/// visible labels. The whole point of running twice is that the labels differ.
final class ScreenshotTests: XCTestCase {

    /// Prefix numbers set the order they appear in on the App Store: the upload
    /// script sorts by filename.
    private enum Shot: String {
        case kidToday = "01-kid-today"
        case kidWeek = "02-kid-week"
        case parentToday = "03-parent-today"
        case parentWeek = "04-parent-week"
        case parentSchedule = "05-parent-schedule"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1",
                          "screenshot captures run only under tools/screenshots.sh")
    }

    // MARK: The child's side

    func testKidScreens() throws {
        let app = launch(AppEnvironmentFlag.screenshotKid)

        // Kid mode has two tabs: Today, then Week.
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 30),
                      "the kid fixture should land straight in kid mode")
        capture(app, as: .kidToday)

        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["kidWeek.day.1"].waitForExistence(timeout: 10),
                      "the Week tab should show the current week")
        capture(app, as: .kidWeek)
    }

    // MARK: The parent's side

    func testParentScreens() throws {
        let app = launch(AppEnvironmentFlag.screenshotParent)

        // Parent mode has three: Today, Week, Manage.
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 2).waitForExistence(timeout: 30),
                      "the parent fixture should land in parent mode")
        capture(app, as: .parentToday)

        app.tabBars.buttons.element(boundBy: 1).tap()
        capture(app, as: .parentWeek)

        app.tabBars.buttons.element(boundBy: 2).tap()
        let schedule = app.buttons["manage.schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 10))
        schedule.tap()

        let dayPicker = app.segmentedControls["schedule.dayPicker"]
        XCTAssertTrue(dayPicker.waitForExistence(timeout: 10))
        // Monday, so the shot is the same on every day of the week it is taken.
        dayPicker.buttons.element(boundBy: 0).tap()
        capture(app, as: .parentSchedule)
    }

    // MARK: Plumbing

    /// The language comes from the runner's environment so the script can run the
    /// same captures twice. Anything unset falls back to English, which is the
    /// app's source language.
    private func launch(_ flag: String) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        let locale = environment["SCREENSHOT_LOCALE"] ?? "en_US"

        let app = XCUIApplication()
        app.launch(inLanguage: language, locale: locale, arguments: [flag])
        return app
    }

    /// `XCUIScreen` rather than the app's own frame: the App Store wants an image
    /// at the device's exact resolution, and the screen is what has it.
    ///
    /// PNG explicitly, rather than `XCTAttachment(screenshot:)`, whose format is
    /// XCTest's business and has changed before. `.keepAlways` is what puts the
    /// attachment in the result bundle at all — the default discards attachments
    /// from tests that passed, which is every one of these.
    private func capture(_ app: XCUIApplication, as shot: Shot) {
        // Let animations settle: a shot mid-transition is the one failure mode
        // here that no assertion catches.
        _ = app.wait(for: .runningForeground, timeout: 5)
        Thread.sleep(forTimeInterval: 1)

        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation,
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "\(shot.rawValue).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The launch flags `AppEnvironment` reads. Repeated here as literals because the
/// UI test target does not link the app.
private enum AppEnvironmentFlag {
    static let screenshotParent = "-screenshots-parent"
    static let screenshotKid = "-screenshots-kid"
}
