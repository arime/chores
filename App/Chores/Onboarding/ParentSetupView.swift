import SwiftUI
import ChoresCore

/// Signed in, but in no family yet — a new parent, or one who has just left.
/// The app cannot tell which, and does not need to: both choices are offered.
struct ParentSetupView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "house")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("You're signed in")
                    .font(.title2.bold())
                Text("Start a new family, or join one you've been given a code for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                NavigationLink("Start a family") {
                    CreateFamilyView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("parentSetup.createFamily")

                NavigationLink("I have a code") {
                    ClaimCodeView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("parentSetup.claimCode")
            }
            .padding(32)
        }
    }
}
