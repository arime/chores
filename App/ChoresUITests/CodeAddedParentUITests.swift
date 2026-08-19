import XCTest

/// A parent who joins with a code instead of an Apple ID. They get every parent
/// power, and a Manage screen with one way out rather than three — the branch
/// most likely to be broken by someone tidying up `ManageView` later.
final class CodeAddedParentUITests: ParentUITestCase {

    func testAParentAddedByCodeGetsOneWayOut() {
        let app = launchIntoParentMode()
        addParent(app, named: "Toinen")

        // Take the code the first parent would read out, then hand the device
        // over: signing out is what makes this the second parent's device.
        let row = app.buttons["people.parent.Toinen"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let codeLabel = app.staticTexts["claimCodeSheet.code"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 5))
        let code = codeLabel.label
        app.buttons["Done"].tap()

        app.tabBars.buttons["Manage"].tap()
        let signOut = app.buttons["manage.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        // The code door, not the parent door: no Apple ID is involved anywhere
        // in this path.
        let codeDoor = app.buttons["onboarding.child"]
        XCTAssertTrue(codeDoor.waitForExistence(timeout: 10))
        codeDoor.tap()

        let field = app.textFields["claimCode.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        app.buttons["claimCode.submit"].tap()

        XCTAssertTrue(app.tabBars.buttons["Manage"].waitForExistence(timeout: 10),
                      "a parent code should open parent mode on an anonymous device")
        app.tabBars.buttons["Manage"].tap()

        let leave = app.buttons["manage.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["manage.signOut"].exists,
                       "signing out would strand a parent with no credential to return with")
        XCTAssertFalse(app.buttons["manage.deleteAccount"].exists,
                       "they never created an account to delete")
    }
}
