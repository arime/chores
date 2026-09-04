import SwiftUI
import ChoresCore

struct ClaimCodeView: View {
    let onFinished: () async -> Void
    /// Non-nil only when this view is presented as the root of its own
    /// navigation stack, where nothing else offers a way back. Pushed
    /// presentations show a back button and leave this nil.
    let onCancel: (() -> Void)?

    @State private var model: OnboardingViewModel

    init(environment: AppEnvironment,
         onFinished: @escaping () async -> Void,
         onCancel: (() -> Void)? = nil) {
        self.onFinished = onFinished
        self.onCancel = onCancel
        _model = State(initialValue: OnboardingViewModel(backend: environment.backend))
    }

    var body: some View {
        OnboardingScaffold(navigation: .forScreen(onCancel: onCancel),
                           kicker: Text("Child"), title: Text("Enter code")) {
            VStack(alignment: .leading, spacing: 6) {
                NocturneField(kicker: Text("Your code"), placeholder: "ABC123",
                              text: $model.code, style: .code,
                              autocapitalization: .characters,
                              identifier: "claimCode.code")
                Footnote(text: Text("Ask a parent to open Manage → People and show you a code."))
            }

            if let failure = model.failure {
                Text(failure.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
            }

            Button {
                Task {
                    if await model.claim() { await onFinished() }
                }
            } label: {
                if model.isBusy {
                    ProgressView().tint(Theme.accent)
                } else {
                    Text("Continue")
                }
            }
            .buttonStyle(.primary)
            .disabled(model.isBusy)
            .accessibilityIdentifier("claimCode.submit")
        } footer: {
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        ClaimCodeView(environment: .preview(), onFinished: {})
    }
}
