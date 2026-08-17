import Foundation

struct AppleToken: Equatable, Sendable {
    let idToken: String
    let nonce: String
}

/// Where the Apple identity token comes from.
///
/// A seam rather than a direct call, because Apple's sheet is system UI that
/// XCTest cannot drive: every parent UI test would otherwise stall on it. The
/// stub under `-ui-testing` returns a canned token that `InMemoryChoresBackend`
/// accepts like any other.
protocol AppleTokenProviding: Sendable {
    /// False when tapping goes nowhere near Apple, so the view can render an
    /// ordinary button instead of one that promises a sheet it will not show.
    var presentsSystemUI: Bool { get }
    func requestToken() async throws -> AppleToken
}

/// Always the same token, so a relaunch in a UI test is the same person.
struct StubAppleTokenProvider: AppleTokenProviding {
    let presentsSystemUI = false
    func requestToken() async throws -> AppleToken {
        AppleToken(idToken: "ui-testing-parent", nonce: "ui-testing-nonce")
    }
}
