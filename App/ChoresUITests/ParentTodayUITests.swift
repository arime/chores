import XCTest

/// Covers the parent's at-a-glance screen: what is scheduled for today shows up
/// under the right child, and the progress ring counts it.
final class ParentTodayUITests: ParentUITestCase {

    func testTodayShowsWhatIsScheduledForTodaysWeekday() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        addChore(app, named: "Bins")

        // Only "Dishes" is assigned to today, so only it should appear.
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday)

        app.tabBars.buttons["Today"].tap()

        XCTAssertTrue(app.staticTexts["Kid"].waitForExistence(timeout: 5),
                      "each child gets a section on Today")
        XCTAssertTrue(app.staticTexts["Dishes"].waitForExistence(timeout: 5),
                      "a chore scheduled for today should be listed")
        XCTAssertFalse(app.staticTexts["Bins"].exists,
                       "a chore not assigned to today should not be listed")
        XCTAssertTrue(app.staticTexts["0 of 1 done"].exists,
                      "the ring should count today's chores as none done yet")
    }

    func testChildWithNothingScheduledSaysSo() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")

        // Assign to tomorrow, so today is deliberately empty.
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday % 7 + 1)

        app.tabBars.buttons["Today"].tap()

        XCTAssertTrue(app.staticTexts["Nothing today"].waitForExistence(timeout: 5),
                      "an empty day should say so rather than showing a blank section")
    }
}
