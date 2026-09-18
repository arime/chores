import XCTest

/// The parent's own evening reminder: on by default, and the hub says what it
/// is set to.
final class EveningReminderUITests: ParentUITestCase {

    func testTurningTheReminderOffIsReflectedOnTheHub() {
        let app = launchIntoParentMode()
        app.manageTab.tap()

        let row = app.buttons["manage.reminder"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // CONTAINS rather than an exact match: iOS puts a narrow no-break space
        // before "PM", and the test locale decides between 21:00 and 9:00 PM.
        XCTAssertTrue(row.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '21:00' OR label CONTAINS '9:00'")).firstMatch.exists,
            "a new parent starts at 21:00")
        row.tap()

        let toggle = app.switches["reminder.evening.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "the switch starts on")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")

        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.buttons["manage.reminder"].staticTexts["Off"].waitForExistence(timeout: 5),
                      "the hub row should now say Off")
    }
}
