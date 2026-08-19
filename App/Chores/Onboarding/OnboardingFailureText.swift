import Foundation
import ChoresCore

extension OnboardingFailure {
    /// Every message names what to do next. "An error occurred" would leave an
    /// eleven-year-old stuck.
    var text: String {
        switch self {
        case .bothNamesRequired:
            String(localized: "Please fill in both names.")
        case .codeRequired:
            String(localized: "Enter the code from your parent.")
        case .unknownClaimCode:
            String(localized: "We don't recognise that code. Check for typos and try again.")
        case .claimCodeAlreadyUsed:
            String(localized: "That code has already been used. Ask your parent for a new one.")
        case .claimCodeExpired:
            String(localized: "That code has expired. Ask your parent for a new one.")
        case .alreadyClaimed:
            String(localized: "This device is already set up.")
        case .projectUnavailable:
            String(localized: "Can't reach the server. Check your connection and try again.")
        case .sessionUnavailable:
            String(localized: "Couldn't start a session. Try restarting the app.")
        case .mustSignIn:
            String(localized: "Only a parent who has signed in with Apple can start a family. Sign in with Apple, then try again.")
        case .notPermitted:
            String(localized: "You're not able to do that.")
        case .other(let detail):
            detail
        }
    }
}
