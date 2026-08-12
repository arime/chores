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

    static func live() -> AppEnvironment {
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
