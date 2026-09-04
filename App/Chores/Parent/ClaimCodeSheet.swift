import SwiftUI
import ChoresCore

struct ClaimCodeSheet: View {
    let profile: Profile
    let backend: any ChoresBackend

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            SheetHeader(title: Text(profile.displayName)) {
                SheetPrimaryButton(title: Text("Done")) { dismiss() }
            }

            if let code {
                Text("Enter this on \(profile.displayName)'s device")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral500)
                    .padding(.top, 12)

                // Shown in two groups of three, which is how someone reads a
                // code out across a room. VoiceOver — and the UI tests — get the
                // raw six characters.
                Text(verbatim: Self.formatted(code))
                    .font(.system(size: 48, weight: .medium))
                    .tracking(48 * 0.14)
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent300)
                    .textSelection(.enabled)
                    .accessibilityLabel(code)
                    .accessibilityIdentifier("claimCodeSheet.code")

                Footnote(text: Text("Expires in 7 days. Generating a new code cancels this one."))

                Button("New code") { Task { await generate() } }
                    .buttonStyle(.secondary)
                    .frame(width: 140)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
                    .padding(.top, 12)
                Button("New code") { Task { await generate() } }
                    .buttonStyle(.secondary)
                    .frame(width: 140)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .nocturneSheet()
        .task { await generate() }
    }

    /// "KX74QM" → "KX7 4QM". Anything not six characters long is left alone.
    static func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
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
