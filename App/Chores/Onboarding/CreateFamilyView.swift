import SwiftUI
import ChoresCore

struct CreateFamilyView: View {
    let onFinished: () async -> Void

    @State private var model: OnboardingViewModel

    init(environment: AppEnvironment, onFinished: @escaping () async -> Void) {
        self.onFinished = onFinished
        _model = State(initialValue: OnboardingViewModel(backend: environment.backend))
    }

    var body: some View {
        OnboardingScaffold(navigation: .back, kicker: Text("Parent"), title: Text("New family")) {
            NocturneField(kicker: Text("Household"), placeholder: "Family name",
                          text: $model.familyName, identifier: "createFamily.familyName")

            NocturneField(kicker: Text("You"), placeholder: "Your name",
                          text: $model.parentName, identifier: "createFamily.parentName")

            if let failure = model.failure {
                Text(failure.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
            }

            // Right under the fields rather than at the foot: with the keyboard
            // up, this is where the thumb already is.
            Button {
                Task {
                    if await model.createFamily() { await onFinished() }
                }
            } label: {
                if model.isBusy {
                    ProgressView().tint(Theme.accent)
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.primary)
            .disabled(model.isBusy)
            .accessibilityIdentifier("createFamily.submit")
        } footer: {
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        CreateFamilyView(environment: .preview(), onFinished: {})
    }
}
