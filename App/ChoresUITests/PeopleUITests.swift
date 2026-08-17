import XCTest

/// Covers deleting a child from People: the most destructive action in the
/// app, since it erases someone else's history rather than the actor's own.
final class PeopleUITests: ParentUITestCase {

    func testDeletingAChildNamesWhatWillBeLost() {
        let app = launchIntoParentMode()
        addChild(app, named: "Kid")
        app.tabBars.buttons["Manage"].tap()
        app.buttons["People"].tap()

        let row = app.buttons["people.child.Kid"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["people.deleteChild.Kid"].tap()

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'ticked off'")).firstMatch
            .waitForExistence(timeout: 5),
            "the confirmation must say the history goes too")

        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.buttons["people.child.Kid"].waitForExistence(timeout: 5))
    }
}
