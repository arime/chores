import SwiftUI
import ChoresCore

struct ClaimCodeSheet: View {
    let profile: Profile
    let backend: any ChoresBackend

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let code {
                    Text("Enter this on \(profile.displayName)'s device")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("claimCodeSheet.code")
                    Text("Expires in 7 days. Generating a new code cancels this one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    ProgressView()
                }

                Spacer()

                Button("New code") { Task { await generate() } }
                    .buttonStyle(.bordered)
            }
            .padding(32)
            .navigationTitle(profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generate() }
        }
    }

    private func generate() async {
        do {
            code = try await backend.generateClaimCode(profileID: profile.id)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn't create a code. Check your connection and try again.")
        }
    }
}
