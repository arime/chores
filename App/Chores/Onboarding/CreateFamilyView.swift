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
        Form {
            Section("Household") {
                TextField("Family name", text: $model.familyName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("createFamily.familyName")
            }
            Section("You") {
                TextField("Your name", text: $model.parentName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("createFamily.parentName")
            }

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        if await model.createFamily() { await onFinished() }
                    }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("createFamily.submit")
            }
        }
        .navigationTitle("New family")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CreateFamilyView(environment: .preview(), onFinished: {})
    }
}
