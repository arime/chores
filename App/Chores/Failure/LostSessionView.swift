import SwiftUI

/// Shown when an anonymous device that was set up no longer maps to a profile.
///
/// A claim code is the usual remedy, so it leads. Signing in is offered second:
/// if this is really a parent's device, their family is one sign-in away, and
/// without it a family that has genuinely gone would leave this screen a dead
/// end. A child can no longer start a family here by mistake — the database
/// refuses an anonymous caller — which is what the old wording was worried about.
struct LostSessionView: View {
    let onReclaim: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This device isn't set up", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Ask a parent to open Manage → People and show you a new code.")
        } actions: {
            VStack(spacing: 16) {
                Button("Enter a code") { onReclaim() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("lostSession.reclaim")

                Button("I'm a parent — sign in") { onSignIn() }
                    .font(.footnote)
                    .accessibilityIdentifier("lostSession.signIn")
            }
        }
    }
}

#Preview { LostSessionView(onReclaim: {}, onSignIn: {}) }
