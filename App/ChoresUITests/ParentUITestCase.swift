import XCTest

/// Shared setup for the parent-mode UI tests. Launching with `-ui-testing` swaps
/// the Supabase backend for the in-memory fake, so each test starts from an empty
/// family and builds only what it needs.
class ParentUITestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func launchIntoParentMode() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10))
        app.buttons["onboarding.parent"].tap()

        let familyName = app.textFields["createFamily.familyName"]
        XCTAssertTrue(familyName.waitForExistence(timeout: 5))
        familyName.tap()
        familyName.typeText("Koti")

        let parentName = app.textFields["createFamily.parentName"]
        parentName.tap()
        parentName.typeText("Parent")
        app.buttons["createFamily.submit"].tap()

        XCTAssertTrue(app.tabBars.buttons["Manage"].waitForExistence(timeout: 10))
        return app
    }

    /// Types into an alert's text field and confirms it.
    func fillAlert(_ app: XCUIApplication, text: String, confirm: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "expected an alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        alert.buttons[confirm].tap()
    }

    func addChild(_ app: XCUIApplication, named name: String) {
        app.tabBars.buttons["Manage"].tap()
        app.buttons["People"].tap()
        XCTAssertTrue(app.buttons["people.addChild"].waitForExistence(timeout: 5))
        app.buttons["people.addChild"].tap()
        fillAlert(app, text: name, confirm: "Add")
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "the new child should appear in the list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func addParent(_ app: XCUIApplication, named name: String) {
        app.tabBars.buttons["Manage"].tap()
        app.buttons["People"].tap()
        XCTAssertTrue(app.buttons["people.addParent"].waitForExistence(timeout: 5))
        app.buttons["people.addParent"].tap()
        fillAlert(app, text: name, confirm: "Add")
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "the new parent should appear in the list")
    }

    func addChore(_ app: XCUIApplication, named name: String) {
        app.tabBars.buttons["Manage"].tap()
        app.buttons["Chores"].tap()
        XCTAssertTrue(app.buttons["chores.add"].waitForExistence(timeout: 5))
        app.buttons["chores.add"].tap()
        fillAlert(app, text: name, confirm: "Add")
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5),
                      "the new chore should appear under Active")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Assigns a chore on the given ISO weekday (1 = Monday). Assumes the Manage
    /// tab is reachable; leaves the app on the schedule editor.
    func assign(_ app: XCUIApplication, chore: String, to child: String, onISOWeekday weekday: Int) {
        app.tabBars.buttons["Manage"].tap()
        app.buttons["Schedule"].tap()

        let dayPicker = app.segmentedControls["schedule.dayPicker"]
        XCTAssertTrue(dayPicker.waitForExistence(timeout: 5))
        dayPicker.buttons.element(boundBy: weekday - 1).tap()

        let add = app.buttons["schedule.add.\(child)"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        XCTAssertTrue(app.buttons[chore].waitForExistence(timeout: 5))
        app.buttons[chore].tap()
        XCTAssertTrue(app.staticTexts[chore].waitForExistence(timeout: 5),
                      "the assigned chore should show under the child")
    }

    /// `Calendar` counts Sunday as 1; the app uses ISO weekdays where Monday is 1.
    var todayISOWeekday: Int {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return weekday == 1 ? 7 : weekday - 1
    }
}
