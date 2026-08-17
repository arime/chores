import AuthenticationServices
import ChoresCore
import CryptoKit
import Foundation

/// Drives `ASAuthorizationController` and returns the identity token.
///
/// The nonce is sent to Apple hashed and to Supabase raw; Supabase re-hashes it
/// and compares, which is what stops a token captured elsewhere being replayed
/// here. Apple's name and email are deliberately ignored — they arrive only on
/// the very first authorization for an Apple ID, so anything built on them
/// breaks after a reinstall.
final class AppleSignInProvider: NSObject, AppleTokenProviding,
                                 ASAuthorizationControllerDelegate, @unchecked Sendable {
    let presentsSystemUI = true

    private var continuation: CheckedContinuation<AppleToken, Error>?
    private var currentNonce = ""

    func requestToken() async throws -> AppleToken {
        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let data = credential.identityToken,
            let token = String(data: data, encoding: .utf8)
        else {
            continuation?.resume(throwing: ChoresBackendError.underlying(
                "Apple returned no identity token."))
            continuation = nil
            return
        }
        continuation?.resume(returning: AppleToken(idToken: token, nonce: currentNonce))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
