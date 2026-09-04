import SwiftUI

/// Each failure gets its own screen because each has a different remedy. This
/// one is for a server that cannot be reached at all, as distinct from one that
/// answered and refused.
struct BackendUnavailableView: View {
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        OnboardingScaffold(kicker: Text("Something's wrong"), title: Text("Can't reach the server")) {
            Text("Check this device's connection first.")
                .font(.system(size: 15))
                .lineSpacing(15 * 0.5)
                .foregroundStyle(Theme.neutral300)
                .frame(maxWidth: 320, alignment: .leading)
        } footer: {
            Button("Try again") {
                Task {
                    isRetrying = true
                    await retry()
                    isRetrying = false
                }
            }
            .buttonStyle(.primary)
            .disabled(isRetrying)
        }
    }
}

#Preview { BackendUnavailableView(retry: {}) }
