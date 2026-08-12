import Foundation
import ChoresCore

/// Owns the app's long-lived collaborators. One instance, created at launch.
@MainActor
final class AppEnvironment {
    let backend: any ChoresBackend
    let snapshotCache: SnapshotCache
    let outbox: Outbox

    init(backend: any ChoresBackend, directory: URL) {
        self.backend = backend
        self.snapshotCache = SnapshotCache(directory: directory)
        self.outbox = Outbox(directory: directory, backend: backend)
    }

    /// UI tests launch with this flag so they run against in-memory fakes: no
    /// Supabase stack required, no state carried between runs, no network flake.
    static let uiTestFlag = "-ui-testing"

    /// Starts already claimed as a child, with chores scheduled for every day of
    /// the week. Reaching kid mode for real takes two devices — a parent generates
    /// a code, the child types it — which one UI test process cannot do.
    static let uiTestKidFlag = "-ui-testing-kid"

    static var isUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(uiTestFlag) || arguments.contains(uiTestKidFlag)
    }

    /// Set once a device resolves to a profile. Lives here so the UI-test reset
    /// below and `RootView`'s `@AppStorage` cannot drift apart.
    static let hasBeenClaimedKey = "device.hasBeenClaimed"

    static func live() -> AppEnvironment {
        if isUITesting {
            // The simulator keeps defaults between runs, and every UI test starts
            // from a device that has never been set up.
            UserDefaults.standard.removeObject(forKey: hasBeenClaimedKey)
        }
        if ProcessInfo.processInfo.arguments.contains(uiTestKidFlag) {
            let backend = InMemoryChoresBackend()
            backend.seedClaimedChild(childName: "Kid",
                                     choreNames: ["Bins", "Dishes"],
                                     onISOWeekdays: Array(1...7))
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString))
        }
        if ProcessInfo.processInfo.arguments.contains(uiTestFlag) {
            return .preview()
        }
        guard let url = URL(string: Secrets.supabaseURL), !Secrets.supabaseAnonKey.isEmpty else {
            fatalError("""
                Secrets.swift is missing or incomplete.
                Copy Secrets.swift.example to Secrets.swift and fill it in.
                """)
        }
        return AppEnvironment(
            backend: SupabaseChoresBackend(url: url, anonKey: Secrets.supabaseAnonKey),
            directory: SnapshotCache.defaultDirectory())
    }

    /// Backed by in-memory fakes, for SwiftUI previews. A fresh temporary
    /// directory each call, so previews never share cache or outbox state.
    static func preview() -> AppEnvironment {
        AppEnvironment(
            backend: InMemoryChoresBackend(),
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
    }
}
