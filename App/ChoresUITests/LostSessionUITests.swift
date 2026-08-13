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
    /// gone no code can exist, and the only escape was deleting the app.
    func testStartingOverReachesOnboarding() {
        let app = launchLost()

        app.buttons["lostSession.startOver"].tap()

        // Destructive enough to confirm, so that a child cannot wander into it.
        let confirm = app.buttons["Start a new family"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "starting over should ask first")
        confirm.tap()

        XCTAssertTrue(app.buttons["onboarding.parent"].waitForExistence(timeout: 5),
                      "confirming should reach onboarding, not leave the device stuck")
    }

    func testCancellingStartOverLeavesTheDeviceAlone() {
        let app = launchLost()

        app.buttons["lostSession.startOver"].tap()
        XCTAssertTrue(app.buttons["Start a new family"].waitForExistence(timeout: 5))

        // SwiftUI presents this dialog popover-style here, which drops the explicit
        // cancel button in favour of tapping outside. Dismiss the way the platform
        // actually offers rather than the way the code asks for.
        app.otherElements["PopoverDismissRegion"].tap()

        XCTAssertTrue(app.staticTexts["This device isn't set up"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.parent"].exists,
                       "cancelling must not drop the device into onboarding")
    }
}
