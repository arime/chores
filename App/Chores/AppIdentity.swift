import Foundation

/// What the app calls itself, and which version it is — read from the bundle
/// rather than written down twice.
///
/// The name on the home screen and the name on the App Store are allowed to
/// differ, and here they do: the store lists it as "Snappy Chores" because plain
/// "Chores" was taken, while the icon says "Chores", which is what fits under an
/// icon. The bundle holds whatever the phone is showing, so quoting the bundle
/// means the app and the home screen can never disagree — and a rename in the
/// project file reaches every screen without anyone hunting for string literals.
enum AppIdentity {
    /// `CFBundleDisplayName` if the project sets one, and the bundle name
    /// otherwise. That is the same order the home screen resolves it in.
    static var displayName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "Chores"
    }

    /// `CFBundleShortVersionString` is `MARKETING_VERSION`, the version users
    /// see and the one that changes when the release does.
    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// `CFBundleVersion`, which `tools/testflight.sh` sets from the clock at
    /// archive time. Meaningless to read, and the most useful thing in a support
    /// email: `build/uploads.log` maps it back to the exact commit the binary
    /// came from.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// "Chores 1.0 (20260821.1649)". Not localized: a name and two numbers read
    /// the same in both languages.
    static var summary: String {
        let version = [marketingVersion, build.isEmpty ? "" : "(\(build))"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return version.isEmpty ? displayName : "\(displayName) \(version)"
    }
}
