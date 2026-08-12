import XCTest

/// Covers the week grid and the day detail behind it, including a parent marking
/// a chore done on the child's behalf.
final class ParentWeekUITests: ParentUITestCase {

    func testParentCanOpenADayAndMarkAChoreDone() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")

        let weekday = todayISOWeekday
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: weekday)

        app.tabBars.buttons["Week"].tap()

        let cell = app.buttons["week.Kid.\(weekday)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5),
                      "every child gets a cell per day of the current week")
        XCTAssertEqual(cell.label, "0 of 1 done")
        cell.tap()

        XCTAssertTrue(app.staticTexts["Dishes"].waitForExistence(timeout: 5),
                      "the day detail should list what is scheduled")

        // Swipe the row itself, not the label inside it — swipe actions belong to
        // the cell.
        let row = app.cells.containing(.staticText, identifier: "Dishes").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()

        let markDone = app.buttons["Mark done"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 5),
                      "today is completable, so the parent should be offered Mark done")
        markDone.tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.label, "1 of 1 done",
                       "the grid should reflect the completion straight away")
    }

    func testDaysWithNothingScheduledReadAsEmpty() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday)

        app.tabBars.buttons["Week"].tap()

        let otherDay = todayISOWeekday % 7 + 1
        let cell = app.buttons["week.Kid.\(otherDay)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.label, "nothing scheduled")
    }
}
