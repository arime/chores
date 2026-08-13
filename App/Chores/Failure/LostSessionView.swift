import SwiftUI

/// Shown when a device that was set up no longer maps to a profile — for example
/// after the profile was removed server-side.
///
/// A claim code is the usual remedy, so it leads. Full onboarding is offered
/// second and quietly, because a child who takes it would start a family of
/// their own by mistake — but it must be offered: if the family really is gone,
/// a code is impossible to obtain and this screen would otherwise be a dead end
/// with no way out but deleting the app.
struct LostSessionView: View {
    let onReclaim: () -> Void
    let onStartOver: () -> Void

    @State private var isConfirmingStartOver = false

    var body: some View {
        ContentUnavailableView {
            Label("This device isn't set up", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Ask a parent to open Manage → Children and show you a new code.")
        } actions: {
            VStack(spacing: 16) {
                Button("Enter a code") { onReclaim() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("lostSession.reclaim")

                Button("Set up as a new family") { isConfirmingStartOver = true }
                    .font(.footnote)
                    .accessibilityIdentifier("lostSession.startOver")
            }
        }
        .confirmationDialog("Set up as a new family?",
                            isPresented: $isConfirmingStartOver,
                            titleVisibility: .visible) {
            Button("Start a new family", role: .destructive) { onStartOver() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
                Only do this if your family is really gone. If it still exists on another \
                device, ask for a code instead — starting over here creates a second, \
                separate family.
                """)
        }
    }
}

#Preview { LostSessionView(onReclaim: {}, onStartOver: {}) }
