import SwiftUI
import ChoresCore

struct ClaimCodeSheet: View {
    let profile: Profile
    let backend: any ChoresBackend
    /// A parent making a code for their own profile, rather than for a child's
    /// device. Same mechanism, different thing to say about it.
    var isOwnProfile = false

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let code {
                    Text(isOwnProfile
                         ? "Enter this on the device you want to use as parent"
                         : "Enter this on \(profile.displayName)'s device")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("claimCodeSheet.code")
                    Text(isOwnProfile
                         ? """
                           Expires in 7 days. Entering it somewhere else moves your \
                           parent access there, and this device will need a code of its own.
                           """
                         : "Expires in 7 days. Generating a new code cancels this one.")
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
            .navigationTitle(isOwnProfile ? "This device" : profile.displayName)
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
            errorMessage = "Couldn't create a code. Check your connection and try again."
        }
    }
}
