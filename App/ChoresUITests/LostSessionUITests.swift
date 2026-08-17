import XCTest

/// A device that remembers being set up but no longer maps to a profile. Launched
/// with `-ui-testing-lost-session`, which pins that state.
final class LostSessionUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchLost() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-lost-session"]
        app.launch()
        XCTAssertTrue(app.staticTexts["This device isn't set up"].waitForExistence(timeout: 10),
                      "a claimed device with no profile should not show plain onboarding")
        return app
    }

    func testEnteringACodeIsOfferedFirst() {
        let app = launchLost()

        app.buttons["lostSession.reclaim"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5),
                      "the claim-code screen should be one tap away")
    }

    /// The screen used to offer nothing but a code. If the family is genuinely
    /// gone no code can exist, and the only escape was deleting the app. Now the
    /// escape is signing in as a parent — the database refuses anonymous callers
    /// trying to start a new family, so that option is gone entirely.
    func testSigningInIsOfferedSecond() {
        let app = launchLost()

        app.buttons["lostSession.signIn"].tap()

        XCTAssertTrue(app.buttons["parentSignIn.button"].waitForExistence(timeout: 5),
                      "signing in should reach the parent sign-in screen, not leave the device stuck")
    }
}
