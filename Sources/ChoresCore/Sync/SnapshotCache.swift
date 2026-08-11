import Foundation

/// Persists the last successfully fetched snapshot so the app opens instantly and
/// stays readable with no connectivity.
public actor SnapshotCache {

    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("snapshot.json")
    }

    /// Application Support/Chores, created on first use.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Chores", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public func load() -> FamilySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // A corrupt cache is never fatal: the app refetches. Trapping here would
        // make a bad write permanently unrecoverable without deleting the app.
        return try? ChoresJSON.decoder.decode(FamilySnapshot.self, from: data)
    }

    public func save(_ snapshot: FamilySnapshot) {
        guard let data = try? ChoresJSON.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
