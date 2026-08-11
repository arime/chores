import Testing
import Foundation
import Supabase
@testable import ChoresCore

@Suite struct SupabaseErrorMappingTests {

    @Test func mapsClaimCodeErrorCodes() {
        // These SQLSTATEs are raised deliberately by claim_profile().
        #expect(SupabaseErrorMapping.map(
            PostgrestError(code: "P0001", message: "unknown code")) == .unknownClaimCode)
        #expect(SupabaseErrorMapping.map(
            PostgrestError(code: "P0002", message: "code already used")) == .claimCodeAlreadyUsed)
        #expect(SupabaseErrorMapping.map(
            PostgrestError(code: "P0003", message: "code expired")) == .claimCodeExpired)
    }

    @Test func mapsOfflineAndUnreachableHostToProjectUnavailable() {
        #expect(SupabaseErrorMapping.map(URLError(.notConnectedToInternet)) == .projectUnavailable)
        #expect(SupabaseErrorMapping.map(URLError(.cannotFindHost)) == .projectUnavailable)
        #expect(SupabaseErrorMapping.map(URLError(.timedOut)) == .projectUnavailable)
        #expect(SupabaseErrorMapping.map(URLError(.networkConnectionLost)) == .projectUnavailable)
    }

    @Test func mapsUnrecognisedPostgrestCodeToUnderlyingWithItsMessage() {
        #expect(SupabaseErrorMapping.map(
            PostgrestError(code: "23505", message: "duplicate key")) == .underlying("duplicate key"))
    }

    @Test func mapsPostgrestErrorWithNoCodeToUnderlying() {
        #expect(SupabaseErrorMapping.map(
            PostgrestError(message: "something broke")) == .underlying("something broke"))
    }

    @Test func passesThroughAnAlreadyMappedError() {
        #expect(SupabaseErrorMapping.map(ChoresBackendError.alreadyClaimed) == .alreadyClaimed)
    }

    /// A URLError that is not a connectivity problem must not be reported as a
    /// paused project — that would send the maintainer to the wrong dashboard.
    @Test func mapsNonConnectivityURLErrorToUnderlying() {
        let mapped = SupabaseErrorMapping.map(URLError(.badServerResponse))
        #expect(mapped != .projectUnavailable)
        if case .underlying = mapped {} else {
            Issue.record("expected .underlying, got \(mapped)")
        }
    }
}
