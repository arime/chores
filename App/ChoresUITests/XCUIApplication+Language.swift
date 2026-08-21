import XCTest

extension XCUIApplication {
    /// Launches with the language pinned to English rather than inherited from
    /// the simulator. The suite asserts visible labels — "Manage", "Nothing
    /// today", "0 of 1 done" — and English is the source language those are
    /// written in. A Finnish simulator would otherwise fail every one of them
    /// while the app was working correctly.
    func launchInEnglish(_ arguments: String...) {
        launch(inLanguage: "en", locale: "en_US", arguments: arguments)
    }

    /// The general form, for the screenshot captures — they are taken once per
    /// App Store listing language, so they are the one caller that needs to
    /// choose.
    func launch(inLanguage language: String, locale: String, arguments: [String]) {
        launchArguments = arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        launch()
    }
}
