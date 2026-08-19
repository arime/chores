import SwiftUI
import ChoresCore

struct OnboardingView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "checklist")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                // The app's own name, not a word to translate — and it would
                // otherwise share a key with the chore list's "Chores" title,
                // which does become "Tehtävät".
                Text(verbatim: "Chores")
                    .font(.largeTitle.bold())
                Text("Set up this device.")
                    .foregroundStyle(.secondary)

                Spacer()

                NavigationLink("I'm a parent") {
                    ParentSignInView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.parent")

                NavigationLink("I have a code") {
                    ClaimCodeView(environment: environment, onFinished: onFinished)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.child")
            }
            .padding(32)
        }
    }
}

#Preview {
    OnboardingView(environment: .preview(), onFinished: {})
}
