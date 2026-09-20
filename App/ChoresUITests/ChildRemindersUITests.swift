import XCTest

/// A child's two reminder times are the parent's to set, from the child's own
/// edit sheet. On by default; off sticks.
final class ChildRemindersUITests: ParentUITestCase {

    func testSwitchingAChildsEveningReminderOffSticks() {
        let app = launchIntoParentMode()
        addChild(app, named: "Kid")
        app.manageTab.tap()
        app.buttons["manage.people"].tap()

        app.buttons["people.child.Kid"].tap()
        let evening = app.switches["editChild.evening.toggle"]
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        XCTAssertEqual(evening.value as? String, "1", "a new child starts with both reminders on")
        XCTAssertEqual(app.switches["editChild.afternoon.toggle"].value as? String, "1")

        evening.tap()
        XCTAssertEqual(evening.value as? String, "0")
        app.buttons["Save"].tap()

        app.buttons["people.child.Kid"].tap()
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        XCTAssertEqual(evening.value as? String, "0", "off must survive a save and a reopen")
        XCTAssertEqual(app.switches["editChild.afternoon.toggle"].value as? String, "1",
                       "the other slot is untouched")
    }
}
