import XCTest

/// End-to-end UI tests.
///
/// The app is launched with `-ui-testing`, which swaps in the in-memory backend:
/// hermetic, no Supabase stack required, and no state carried between runs.
final class OnboardingUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        return app
    }

    func testFreshDeviceLandsOnOnboarding() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10),
                      "a fresh device should offer the parent setup path")
        XCTAssertTrue(app.buttons["onboarding.child"].exists,
                      "a fresh device should offer the claim-code path")
    }

    func testParentCanCreateAFamilyAndReachParentMode() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10))
        app.buttons["onboarding.parent"].tap()

        let signIn = app.buttons["parentSignIn.button"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()

        let startFamily = app.buttons["parentSetup.createFamily"]
        XCTAssertTrue(startFamily.waitForExistence(timeout: 10))
        startFamily.tap()

        let familyName = app.textFields["createFamily.familyName"]
        XCTAssertTrue(familyName.waitForExistence(timeout: 5))
        familyName.tap()
        familyName.typeText("Koti")

        let parentName = app.textFields["createFamily.parentName"]
        parentName.tap()
        parentName.typeText("Parent")

        app.buttons["createFamily.submit"].tap()

        // Reaching the three-tab shell proves the family was created, the session
        // re-read itself, and the root routed on role.
        XCTAssertTrue(app.tabBars.buttons["Manage"].waitForExistence(timeout: 10),
                      "creating a family should land the device in parent mode")
        XCTAssertTrue(app.tabBars.buttons["Today"].exists)
        XCTAssertTrue(app.tabBars.buttons["Week"].exists)
    }

    func testCreateIsRejectedWhenNamesAreBlank() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 10))
        app.buttons["onboarding.parent"].tap()

        let signIn = app.buttons["parentSignIn.button"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()

        let startFamily = app.buttons["parentSetup.createFamily"]
        XCTAssertTrue(startFamily.waitForExistence(timeout: 10))
        startFamily.tap()

        XCTAssertTrue(app.buttons["createFamily.submit"].waitForExistence(timeout: 5))
        app.buttons["createFamily.submit"].tap()

        XCTAssertTrue(app.staticTexts["Please fill in both names."].waitForExistence(timeout: 5),
                      "blank names should be refused before any backend call")
        XCTAssertFalse(app.tabBars.buttons["Manage"].exists,
                       "a rejected form must not navigate anywhere")
    }

    func testUnknownClaimCodeShowsItsOwnMessage() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["onboarding.child"].waitForExistence(timeout: 10))
        app.buttons["onboarding.child"].tap()

        let codeField = app.textFields["claimCode.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        codeField.tap()
        codeField.typeText("ZZZZZZ")

        app.buttons["claimCode.submit"].tap()

        // The wording has to distinguish a typo from a spent code, which is why
        // claim_profile() raises distinct SQLSTATEs.
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "recognise that code")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5),
                      "an unknown code should say so specifically")
    }
}
