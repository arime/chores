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
                // The app's own name, read from the bundle: not a word to
                // translate, and not a literal to keep in step with the project
                // file by hand. A key of its own would also collide with the
                // chore list's "Chores" title, which does become "Tehtävät".
                Text(verbatim: AppIdentity.displayName)
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
