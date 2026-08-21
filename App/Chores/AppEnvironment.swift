import Foundation
import ChoresCore

/// Owns the app's long-lived collaborators. One instance, created at launch.
@MainActor
final class AppEnvironment {
    let backend: any ChoresBackend
    let snapshotCache: SnapshotCache
    let outbox: Outbox
    let appleTokens: any AppleTokenProviding

    init(backend: any ChoresBackend, directory: URL, appleTokens: any AppleTokenProviding) {
        self.backend = backend
        self.snapshotCache = SnapshotCache(directory: directory)
        self.outbox = Outbox(directory: directory, backend: backend)
        self.appleTokens = appleTokens
    }

    /// UI tests launch with this flag so they run against in-memory fakes: no
    /// Supabase stack required, no state carried between runs, no network flake.
    static let uiTestFlag = "-ui-testing"

    /// Starts already claimed as a child, with chores scheduled for every day of
    /// the week. Reaching kid mode for real takes two devices — a parent generates
    /// a code, the child types it — which one UI test process cannot do.
    static let uiTestKidFlag = "-ui-testing-kid"

    /// An empty backend on a device that remembers being claimed — the state
    /// `LostSessionView` exists for. Unreachable otherwise in a test, since the
    /// in-memory backend starts empty on every launch.
    static let uiTestLostSessionFlag = "-ui-testing-lost-session"

    /// The two App Store screenshot fixtures: a lived-in family, seen from the
    /// parent's side and from a child's. `tools/screenshots.sh` launches with
    /// these, and nothing else does.
    ///
    /// They are separate from the flags above because the seeds pull in opposite
    /// directions. A test wants the smallest family that can carry an assertion;
    /// a screenshot wants a full week of chores and a history of ticking them
    /// off. Sharing one fixture would make every test read around data it does
    /// not care about.
    static let screenshotParentFlag = "-screenshots-parent"
    static let screenshotKidFlag = "-screenshots-kid"

    static var isUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(uiTestFlag)
            || arguments.contains(uiTestKidFlag)
            || arguments.contains(uiTestLostSessionFlag)
            || arguments.contains(screenshotParentFlag)
            || arguments.contains(screenshotKidFlag)
    }

    /// The names in the screenshots, in whichever language the app has resolved.
    ///
    /// Deliberately not in the string catalogue: these are reachable only behind
    /// a launch flag, so putting them there would mean shipping — and asking
    /// anyone reviewing translations to read — strings no user can ever see. The
    /// App Store shows one set of screenshots per listing language, and the
    /// listing has two.
    private static var screenshotFamily:
        (family: String, parent: String, children: [String], chores: [String]) {
        if Locale.current.language.languageCode?.identifier == "fi" {
            return ("Koti", "Äiti",
                    ["Aino", "Eero", "Väinö"],
                    ["Roskat", "Tiskit", "Imurointi", "Sängyn petaus", "Kissan ruoka", "Pyykit"])
        }
        return ("Home", "Mum",
                ["Ada", "Oscar", "Iris"],
                ["Bins", "Dishes", "Vacuum", "Make bed", "Feed the cat", "Laundry"])
    }

    /// Set once a device resolves to a profile. Lives here so the UI-test reset
    /// below and `RootView`'s `@AppStorage` cannot drift apart.
    static let hasBeenClaimedKey = "device.hasBeenClaimed"

    /// Ticked in the scheme's Run arguments to point a development build at the
    /// hosted project. Read only in Debug builds — see `credentials`.
    static let hostedFlag = "-hosted"

    /// Development builds talk to the Supabase stack on the developer's Mac;
    /// anything distributed talks to the hosted project.
    ///
    /// The discriminator is the build configuration rather than the platform,
    /// because a phone tethered to Xcode is still development. Release is the
    /// only configuration an archive can be built from, so a TestFlight build
    /// cannot be pointed at a laptop by mistake — there is no code path to it.
    private static var credentials: (url: String, anonKey: String) {
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains(hostedFlag) {
            return (Secrets.Local.supabaseURL, Secrets.Local.supabaseAnonKey)
        }
        #endif
        return (Secrets.Hosted.supabaseURL, Secrets.Hosted.supabaseAnonKey)
    }

    static func live() -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        if isUITesting {
            // The simulator keeps defaults between runs, so pin the flag rather
            // than inheriting whatever the last test left behind.
            if arguments.contains(uiTestLostSessionFlag) {
                UserDefaults.standard.set(true, forKey: hasBeenClaimedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hasBeenClaimedKey)
            }
        }
        if arguments.contains(screenshotParentFlag) || arguments.contains(screenshotKidFlag) {
            let content = screenshotFamily
            let backend = InMemoryChoresBackend()
            backend.seedDemoFamily(
                familyName: content.family,
                parentName: content.parent,
                childNames: content.children,
                childColors: ProfilePalette.options,
                choreNames: content.chores,
                today: CalendarDay(Date(), in: .current),
                // The second child, whose day is halfway done — the most
                // informative of the three to photograph.
                claimingChildAt: arguments.contains(screenshotKidFlag) ? 1 : nil)
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                appleTokens: StubAppleTokenProvider())
        }
        if arguments.contains(uiTestKidFlag) {
            let backend = InMemoryChoresBackend()
            backend.seedClaimedChild(childName: "Kid",
                                     choreNames: ["Bins", "Dishes"],
                                     onISOWeekdays: Array(1...7))
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                appleTokens: StubAppleTokenProvider())
        }
        if arguments.contains(uiTestFlag) {
            return .preview()
        }
        if arguments.contains(uiTestLostSessionFlag) {
            // `.preview()`'s backend starts with no session at all, which reads as
            // `.signedOut` rather than the claimed-but-profileless state this flag
            // names — `seedLostSession()` puts it in the state `signInAnonymously()`
            // would reach live, without an async call this synchronous factory
            // cannot await.
            let backend = InMemoryChoresBackend()
            backend.seedLostSession()
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                appleTokens: StubAppleTokenProvider())
        }
        let (urlString, anonKey) = credentials
        guard let url = URL(string: urlString), url.host != nil, !anonKey.isEmpty else {
            fatalError("""
                Secrets.swift is missing or incomplete.
                Copy Secrets.swift.example to Secrets.swift and fill in both
                Local and Hosted.
                """)
        }
        return AppEnvironment(
            backend: SupabaseChoresBackend(url: url, anonKey: anonKey),
            directory: SnapshotCache.defaultDirectory(),
            appleTokens: isUITesting ? StubAppleTokenProvider() : AppleSignInProvider())
    }

    /// Backed by in-memory fakes, for SwiftUI previews. A fresh temporary
    /// directory each call, so previews never share cache or outbox state.
    static func preview() -> AppEnvironment {
        AppEnvironment(
            backend: InMemoryChoresBackend(),
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            appleTokens: StubAppleTokenProvider())
    }
}
