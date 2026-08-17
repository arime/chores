import AuthenticationServices
import SwiftUI
import ChoresCore

/// The parent door. Everything a parent does begins here, because their family
/// hangs off their Apple ID rather than off this device.
struct ParentSignInView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Sign in to keep your family")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("""
                Signing in with Apple is what lets your family come back if this \
                phone is replaced, wiped, or the app is reinstalled.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            Spacer()

            if environment.appleTokens.presentsSystemUI {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { _ in
                    // The provider drives its own controller; this button only
                    // supplies Apple's required appearance and hit target.
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .allowsHitTesting(false)
                .overlay {
                    Button { Task { await signIn() } } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sign in with Apple")
                    .accessibilityIdentifier("parentSignIn.button")
                }
            } else {
                Button("Sign in with Apple") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("parentSignIn.button")
            }
        }
        .disabled(isBusy)
        .padding(32)
        .navigationTitle("Parent")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let token = try await environment.appleTokens.requestToken()
            try await environment.backend.signInWithApple(idToken: token.idToken,
                                                          nonce: token.nonce)
            await onFinished()
        } catch is CancellationError {
            // The user backed out of Apple's sheet; nothing to report.
        } catch {
            errorMessage = "Couldn't sign in. Please try again."
        }
    }
}
