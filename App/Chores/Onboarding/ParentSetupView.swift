import SwiftUI
import ChoresCore

/// Signed in, but in no family yet — a new parent, or one who has just left.
/// The app cannot tell which, and does not need to: both choices are offered.
struct ParentSetupView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            OnboardingScaffold(kicker: Text("Parent"), title: Text("You're signed in")) {
                Text("Start a new family, or join one you've been given a code for.")
                    .font(.system(size: 15))
                    .lineSpacing(15 * 0.5)
                    .foregroundStyle(Theme.neutral500)
                    .frame(maxWidth: 300, alignment: .leading)
            } footer: {
                VStack(spacing: 10) {
                    NavigationLink {
                        CreateFamilyView(environment: environment, onFinished: onFinished)
                    } label: {
                        Text("Start a family")
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("parentSetup.createFamily")

                    NavigationLink {
                        ClaimCodeView(environment: environment, onFinished: onFinished)
                    } label: {
                        Text("I have a code")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("parentSetup.claimCode")
                }
            }
        }
    }
}
