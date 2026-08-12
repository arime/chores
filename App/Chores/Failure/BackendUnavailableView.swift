import SwiftUI

/// Each failure gets its own screen because each has a different remedy. A
/// generic "network error" would send the maintainer debugging the app when the
/// fix is un-pausing a project.
struct BackendUnavailableView: View {
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text("Check this device's connection first.")
                Text("""
                    If other devices can't connect either, the Supabase project has \
                    probably paused after a week of inactivity. Open the Supabase \
                    dashboard and resume it — nothing is lost.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

#Preview { BackendUnavailableView(retry: {}) }
