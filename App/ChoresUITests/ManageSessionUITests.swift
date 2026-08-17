import XCTest

final class ManageSessionUITests: ParentUITestCase {

    func testSigningOutReturnsToTheFirstScreen() {
        let app = launchIntoParentMode()
        app.tabBars.buttons["Manage"].tap()

        let signOut = app.buttons["manage.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10),
                      "signing out should land back on the two doors")
    }

    func testLeavingWarnsThatTheFamilyGoesWithYou() {
        let app = launchIntoParentMode()
        app.tabBars.buttons["Manage"].tap()

        let leave = app.buttons["manage.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'cannot be undone'")).firstMatch
            .waitForExistence(timeout: 5),
            "the only parent must be told the family goes too")
    }
}
