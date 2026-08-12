import SwiftUI
import ChoresCore

struct ClaimCodeView: View {
    let onFinished: () async -> Void

    @State private var model: OnboardingViewModel

    init(environment: AppEnvironment, onFinished: @escaping () async -> Void) {
        self.onFinished = onFinished
        _model = State(initialValue: OnboardingViewModel(backend: environment.backend))
    }

    var body: some View {
        Form {
            Section {
                TextField("ABC123", text: $model.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced))
            } header: {
                Text("Your code")
            } footer: {
                Text("Ask a parent to open Manage → Children and show you a code.")
            }

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
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
            }
        }
        .navigationTitle("Enter code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ClaimCodeView(environment: .preview(), onFinished: {})
    }
}
