import SwiftUI

/// The server answered and refused. Distinct from `BackendUnavailableView`
/// because nothing the user can do fixes it — no amount of checking the Wi-Fi
/// resolves a missing GRANT — so this screen is aimed at whoever maintains the
/// project, and its whole job is to show the message rather than bury it.
struct BackendFailureView: View {
    let detail: String
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        OnboardingScaffold(kicker: Text("Something's wrong"),
                           title: Text("The server refused the request")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This is a fault in the app or its database, not in this device's connection.")
                    .font(.system(size: 15))
                    .lineSpacing(15 * 0.5)
                    .foregroundStyle(Theme.neutral300)
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.neutral500)
                    .textSelection(.enabled)
            }
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

#Preview {
    BackendFailureView(detail: "permission denied for table profiles", retry: {})
}
