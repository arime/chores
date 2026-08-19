import SwiftUI
import ChoresCore

struct ClaimCodeView: View {
    let onFinished: () async -> Void
    /// Non-nil only when this view is presented as the root of its own
    /// navigation stack, where nothing else offers a way back. Pushed
    /// presentations rely on the system back button and leave this nil.
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
        Form {
            Section {
                TextField("ABC123", text: $model.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced))
                    .accessibilityIdentifier("claimCode.code")
            } header: {
                Text("Your code")
            } footer: {
                Text("Ask a parent to open Manage → People and show you a code.")
            }

            if let failure = model.failure {
                Section {
                    Text(failure.text).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        if await model.claim() { await onFinished() }
                    }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("claimCode.submit")
            }
        }
        .navigationTitle("Enter code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ClaimCodeView(environment: .preview(), onFinished: {})
    }
}
