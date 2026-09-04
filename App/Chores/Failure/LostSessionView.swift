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
        OnboardingScaffold(kicker: Text("Something's wrong"), title: Text("This device isn't set up")) {
            Text("Ask a parent to open Manage → People and show you a new code.")
                .font(.system(size: 15))
                .lineSpacing(15 * 0.5)
                .foregroundStyle(Theme.neutral300)
                .frame(maxWidth: 300, alignment: .leading)
        } footer: {
            VStack(spacing: 10) {
                Button("Enter a code") { onReclaim() }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("lostSession.reclaim")

                Button("I'm a parent — sign in") { onSignIn() }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.neutral500)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lostSession.signIn")
            }
        }
    }
}

#Preview { LostSessionView(onReclaim: {}, onSignIn: {}) }
