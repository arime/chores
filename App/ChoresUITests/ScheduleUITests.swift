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

    /// A second parent is an equal, not a delegate: role is what every RLS policy
    /// asks about, so claiming this code grants the full set.
    func testParentCanAddAnotherParentAndShowThemACode() {
        let app = launchIntoParentMode()

        addParent(app, named: "Bo")

        // The list distinguishes the caller from the parent being set up.
        XCTAssertTrue(app.staticTexts["This device"].exists,
                      "the caller's own row should say so")
        XCTAssertTrue(app.staticTexts["Not set up"].exists,
                      "a parent who hasn't claimed a device yet should say so")

        app.buttons["people.parent.Bo"].tap()
        let code = app.staticTexts["claimCodeSheet.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5),
                      "a second parent needs a code to claim their device")
        XCTAssertEqual(code.label.count, 6, "claim codes are six characters")
    }

    /// Without this the only way back into a family from a wiped parent device is
    /// hand-writing a row into claim_codes.
    func testParentCanGetARecoveryCodeForTheirOwnDevice() {
        let app = launchIntoParentMode()

        app.tabBars.buttons["Manage"].tap()
        XCTAssertTrue(app.buttons["manage.ownCode"].waitForExistence(timeout: 5))
        app.buttons["manage.ownCode"].tap()

        let code = app.staticTexts["claimCodeSheet.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5),
                      "a parent should be able to mint a code for their own profile")
        XCTAssertEqual(code.label.count, 6, "claim codes are six characters")
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
