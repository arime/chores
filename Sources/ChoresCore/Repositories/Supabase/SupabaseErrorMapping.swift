import Foundation
import Supabase

/// Translates transport and PostgREST failures into the app's error vocabulary.
///
/// The claim-code cases rely on the custom SQLSTATEs raised by `claim_profile()`,
/// which is what lets the UI say "ask for a new code" rather than "an error
/// occurred".
public enum SupabaseErrorMapping {

    public static func map(_ error: Error) -> ChoresBackendError {
        if let alreadyMapped = error as? ChoresBackendError { return alreadyMapped }

        if let postgrestError = error as? PostgrestError {
            switch postgrestError.code {
            case "P0001": return .unknownClaimCode
            case "P0002": return .claimCodeAlreadyUsed
            case "P0003": return .claimCodeExpired
            default:      return .underlying(postgrestError.message)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                // Covers both "this device is offline" and "the project is paused".
                // Distinguishing them from the client is not possible, and the
                // failure screen names both possibilities.
                return .projectUnavailable
            default:
                return .underlying(urlError.localizedDescription)
            }
        }

        return .underlying(error.localizedDescription)
    }
}
