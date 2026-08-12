import XCTest

/// The child's side. Launched with `-ui-testing-kid`, which seeds a claimed child
/// with two chores on every weekday.
final class KidUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchAsKid() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-kid"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10),
                      "a claimed child should land straight in kid mode")
        return app
    }

    /// `Calendar` counts Sunday as 1; the app uses ISO weekdays where Monday is 1.
    private var todayISOWeekday: Int {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return weekday == 1 ? 7 : weekday - 1
    }

    func testKidSeesNoParentControls() {
        let app = launchAsKid()
        XCTAssertFalse(app.tabBars.buttons["Manage"].exists,
                       "kid mode must not expose parent functionality")
    }

    func testTappingAChoreMarksItDone() {
        let app = launchAsKid()

        XCTAssertTrue(app.staticTexts["0 of 2 done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Bins"].waitForExistence(timeout: 5))
        app.buttons["Bins"].tap()

        XCTAssertTrue(app.staticTexts["1 of 2 done"].waitForExistence(timeout: 5),
                      "a tap should count immediately, without waiting on the server")

        // Tapping again takes it back off.
        app.buttons["Bins"].tap()
        XCTAssertTrue(app.staticTexts["0 of 2 done"].waitForExistence(timeout: 5))
    }

    func testFutureDaysAreReadOnly() {
        let app = launchAsKid()
        app.tabBars.buttons["Week"].tap()

        let tomorrow = todayISOWeekday % 7 + 1
        let dayButton = app.buttons["kidWeek.day.\(tomorrow)"]
        XCTAssertTrue(dayButton.waitForExistence(timeout: 5))
        dayButton.tap()

        // Sunday is the last day of the ISO week, so "tomorrow" from Sunday falls
        // in next week and gets the other message.
        let expected = todayISOWeekday == 7
            ? "This week only." : "You can tick these off on the day."
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5),
                      "a day that hasn't happened yet should say so")
        XCTAssertFalse(app.buttons["Bins"].isEnabled,
                       "and its chores should not be tappable")
    }
}
