import XCTest

extension XCUIApplication {
    /// The parent's two tabs, found by position in the system tab bar. SwiftUI
    /// does not carry an accessibility identifier through to a tab bar item,
    /// and the labels change with the language the screenshots are taken in,
    /// so the order — Family, then Manage — is the one thing to hold on to.
    var familyTab: XCUIElement { tabBars.buttons.element(boundBy: 0) }
    var manageTab: XCUIElement { tabBars.buttons.element(boundBy: 1) }
}
