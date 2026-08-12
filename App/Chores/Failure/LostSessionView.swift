import SwiftUI

/// Shown when a device that was set up no longer maps to a profile — for example
/// after the profile was removed server-side. The remedy is a new claim code, so
/// this offers that alone: sending a child back to full onboarding invites them
/// to create a second family by mistake.
struct LostSessionView: View {
    let onReclaim: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This device isn't set up", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Ask a parent to open Manage → Children and show you a new code.")
        } actions: {
            Button("Enter a code") { onReclaim() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("lostSession.reclaim")
        }
    }
}

#Preview { LostSessionView(onReclaim: {}) }
