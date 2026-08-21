import Foundation

/// The two web pages the App Store listing points at, so the app can point at
/// them too.
///
/// A privacy policy URL is a required field in App Store Connect, and App Review
/// opens it. Having the same links inside the app is not required, but it is
/// where someone looks for them, and it means the URL is wrong in one place
/// rather than two if the site ever moves. The pages live in `docs/site/` and are
/// published to GitHub Pages by `.github/workflows/pages.yml`.
///
/// They exist only in parent mode. The child's side deliberately has no way out
/// to the web at all.
enum AppLinks {
    private static let base = URL(string: "https://arime.github.io/chores/")!

    static var privacyPolicy: URL { localized("privacy") }
    static var support: URL { localized("support") }

    /// Each page has a Finnish translation one path component further down. The
    /// app is English and Finnish, so this covers every reader it has, and any
    /// other language falls back to the English page rather than a 404.
    private static func localized(_ page: String) -> URL {
        let url = base.appendingPathComponent(page)
        guard Locale.current.language.languageCode?.identifier == "fi" else { return url }
        return url.appendingPathComponent("fi")
    }

}
