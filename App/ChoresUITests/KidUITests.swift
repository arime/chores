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
        app.launchInEnglish("-ui-testing-kid")
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

    /// Both halves of `ScheduleResolver.eligibility(for:today:)`, whichever the
    /// calendar allows to be reached today.
    ///
    /// The week view renders only the current ISO week, so `kidWeek.day.N` is
    /// always day N of *this* week — it can never address next week. That leaves
    /// Sunday with no later day to select, so on Sunday this asserts the
    /// complementary rule instead: a day already past stays editable, because a
    /// child may still tick off any earlier day in the current week. Asserting
    /// the reachable rule beats skipping and leaving Sunday uncovered.
    func testDayEditabilityFollowsPositionInTheWeek() {
        let app = launchAsKid()
        app.tabBars.buttons["Week"].tap()

        // Sunday is the last day of the ISO week; every other day has a tomorrow
        // inside it.
        let isLastDayOfWeek = todayISOWeekday == 7
        let target = isLastDayOfWeek ? todayISOWeekday - 1 : todayISOWeekday + 1

        let dayButton = app.buttons["kidWeek.day.\(target)"]
        XCTAssertTrue(dayButton.waitForExistence(timeout: 5))
        dayButton.tap()

        XCTAssertTrue(app.buttons["Bins"].waitForExistence(timeout: 5))

        if isLastDayOfWeek {
            XCTAssertTrue(app.buttons["Bins"].isEnabled,
                          "an earlier day in the current week stays tickable")
            XCTAssertFalse(app.staticTexts["You can tick these off on the day."].exists,
                           "a day that has already happened is not in the future")
        } else {
            XCTAssertTrue(
                app.staticTexts["You can tick these off on the day."]
                    .waitForExistence(timeout: 5),
                "a day that hasn't happened yet should say so")
            XCTAssertFalse(app.buttons["Bins"].isEnabled,
                           "and its chores should not be tappable")
        }
    }
}
