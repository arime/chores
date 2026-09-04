import XCTest

/// Covers the parent's Family screen: what is scheduled shows up under the right
/// child on the right day, the count follows it, and a parent can tick a chore
/// off on the child's behalf.
final class FamilyUITests: ParentUITestCase {

    func testTodayShowsWhatIsScheduledForTodaysWeekday() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        addChore(app, named: "Bins")

        // Only "Dishes" is assigned to today, so only it should appear.
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday)

        app.buttons["tab.family"].tap()

        XCTAssertTrue(app.staticTexts["Kid"].waitForExistence(timeout: 5),
                      "each child gets a section")
        XCTAssertTrue(app.staticTexts["Dishes"].waitForExistence(timeout: 5),
                      "a chore scheduled for today should be listed")
        XCTAssertFalse(app.staticTexts["Bins"].exists,
                       "a chore not assigned to today should not be listed")
        XCTAssertTrue(app.staticTexts["0 of 1 done"].firstMatch.exists,
                      "the count should say none of today's chores are done yet")
    }

    func testTappingAChoreTogglesIt() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday)

        app.buttons["tab.family"].tap()
        XCTAssertTrue(app.staticTexts["0 of 1 done"].firstMatch.waitForExistence(timeout: 5))

        let row = app.buttons["Dishes"]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the whole row should be the tap target, not a swipe action")
        row.tap()

        XCTAssertTrue(app.staticTexts["1 of 1 done"].firstMatch.waitForExistence(timeout: 5),
                      "the count should follow straight away")

        // The same tap takes it back off.
        row.tap()
        XCTAssertTrue(app.staticTexts["0 of 1 done"].firstMatch.waitForExistence(timeout: 5))
    }

    func testChildWithNothingScheduledTodaySaysSo() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")

        // Assign to tomorrow, so today is deliberately empty.
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday % 7 + 1)

        app.buttons["tab.family"].tap()

        XCTAssertTrue(app.staticTexts["Nothing today"].firstMatch.waitForExistence(timeout: 5),
                      "an empty day should say so rather than showing a blank section")
    }

    /// The strip is the whole navigation: picking another day swaps the
    /// sections beneath it.
    func testPickingAnotherDayShowsThatDaysChores() {
        let app = launchIntoParentMode()

        addChild(app, named: "Kid")
        addChore(app, named: "Dishes")
        assign(app, chore: "Dishes", to: "Kid", onISOWeekday: todayISOWeekday)

        app.buttons["tab.family"].tap()

        let today = app.buttons["family.day.\(todayISOWeekday)"]
        XCTAssertTrue(today.waitForExistence(timeout: 5),
                      "every day of the current week gets a cell")
        XCTAssertEqual(today.label, "\(weekdayName(todayISOWeekday)), 0 of 1 done")

        let otherDay = todayISOWeekday % 7 + 1
        let other = app.buttons["family.day.\(otherDay)"]
        XCTAssertEqual(other.label, "\(weekdayName(otherDay)), nothing scheduled")
        other.tap()

        XCTAssertTrue(app.staticTexts["Nothing scheduled"].waitForExistence(timeout: 5),
                      "a day with nothing on it should say so under the child")
        XCTAssertFalse(app.staticTexts["Dishes"].exists,
                       "today's chore should not follow onto another day")
    }

    private func weekdayName(_ isoWeekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en")
        return formatter.standaloneWeekdaySymbols[isoWeekday % 7]
    }
}
