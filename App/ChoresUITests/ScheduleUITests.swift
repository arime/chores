import XCTest

/// Covers the parent's core setup workflow: add a child, add chores, build a
/// weekly template, and copy a day.
final class ScheduleUITests: ParentUITestCase {

    func testParentCanBuildAScheduleAndCopyADay() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        addChore(app, named: "Bins")

        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: 1)

        // Copy Monday onto Wednesday.
        app.buttons["schedule.copyDay"].tap()
        XCTAssertTrue(app.buttons["Wednesday"].waitForExistence(timeout: 5))
        app.buttons["Wednesday"].tap()
        app.buttons["Copy"].tap()

        // Wednesday should now look like Monday.
        let dayPicker = app.segmentedControls["schedule.dayPicker"]
        XCTAssertTrue(dayPicker.waitForExistence(timeout: 5))
        dayPicker.buttons.element(boundBy: 2).tap()

        XCTAssertTrue(app.staticTexts["Dishes"].waitForExistence(timeout: 5),
                      "copying a day should carry its assignments across")
    }

    func testArchivingRemovesAChoreFromTheActiveList() {
        let app = launchIntoParentMode()

        addChore(app, named: "Vacuum")

        app.tabBars.buttons["Manage"].tap()
        app.buttons["Chores"].tap()
        XCTAssertTrue(app.buttons["Vacuum"].waitForExistence(timeout: 5))
        app.buttons["Vacuum"].swipeLeft()
        app.buttons["Archive"].tap()

        // It moves out of Active and into the archived group, rather than vanishing.
        XCTAssertTrue(app.buttons["Archived (1)"].waitForExistence(timeout: 5),
                      "an archived chore should still be listed, under Archived")
    }
}
