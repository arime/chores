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
        ContentUnavailableView {
            Label("The server refused the request", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text("This is a fault in the app or its database, not in this device's connection.")
                Text(detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Try again") {
                Task {
                    isRetrying = true
                    await retry()
                    isRetrying = false
                }
            }
            .disabled(isRetrying)
        }
    }
}

#Preview {
    BackendFailureView(detail: "permission denied for table profiles", retry: {})
}
