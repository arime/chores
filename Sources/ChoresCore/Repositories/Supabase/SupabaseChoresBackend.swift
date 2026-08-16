import Foundation
import Supabase

/// The live `ChoresBackend`, talking to Supabase over PostgREST.
///
/// Every call funnels through `run`, so no Supabase-specific error ever escapes
/// this type — callers only ever see `ChoresBackendError`.
public final class SupabaseChoresBackend: ChoresBackend, @unchecked Sendable {

    private let client: SupabaseClient

    /// - Parameter sessionStorage: Where the anonymous session is persisted. The
    ///   default is the platform keychain, which is what the app wants. Tests pass
    ///   an ephemeral store so runs cannot leak into each other and so two
    ///   instances can act as two separate devices.
    public init(url: URL, anonKey: String, sessionStorage: (any AuthLocalStorage)? = nil) {
        // Opt in early to the session handling supabase-swift will default to in
        // its next major version. The legacy path refreshes before emitting the
        // initial session and reports a runtime issue for it, which breaks into
        // the debugger on every launch.
        let auth: SupabaseClientOptions.AuthOptions =
            if let sessionStorage {
                .init(storage: sessionStorage, emitLocalSessionAsInitialSession: true)
            } else {
                .init(emitLocalSessionAsInitialSession: true)
            }
        let options = SupabaseClientOptions(
            db: .init(encoder: ChoresJSON.encoder, decoder: ChoresJSON.decoder),
            auth: auth)
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey, options: options)
    }

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw SupabaseErrorMapping.map(error)
        }
    }

    // MARK: Session

    public func signInAnonymouslyIfNeeded() async throws {
        try await run {
            guard client.auth.currentSession != nil else {
                _ = try await client.auth.signInAnonymously()
                return
            }
            // A stored session outlives the user it names more often than it
            // looks: `supabase db reset` in development, a restore from backup
            // in production. The keychain is untouched by either, and the JWT
            // stays signed and unexpired, so requests keep being accepted while
            // `auth.uid()` names a row that is gone. Nothing complains until the
            // first profile write, which fails as a foreign key violation
            // (`23503`) an unhelpful distance from the actual cause.
            //
            // Asking who we are is the only way to tell a live session from a
            // hollow one, so it happens once per launch rather than being
            // inferred.
            do {
                _ = try await client.auth.user()
            } catch {
                // Only a refusal from the server counts. Anything else — offline,
                // a 500 — leaves the session alone: discarding a good session
                // because the network blinked would strand a device that has a
                // perfectly valid one, and whatever call comes next reports the
                // failure on its own terms.
                guard let authError = error as? AuthError,
                      Self.serverDisownsSession(authError) else { return }
                try? await client.auth.signOut()
                _ = try await client.auth.signInAnonymously()
            }
        }
    }

    /// The server was reached and did not recognise the session — the user was
    /// deleted, or the token no longer refers to anything it will honour.
    private static func serverDisownsSession(_ error: AuthError) -> Bool {
        [.userNotFound, .sessionNotFound, .sessionExpired, .badJWT,
         .refreshTokenNotFound, .refreshTokenAlreadyUsed].contains(error.errorCode)
    }

    public func currentProfile() async throws -> Profile? {
        try await run {
            guard let userID = client.auth.currentSession?.user.id else { return nil }
            let rows: [Profile] = try await client
                .from("profiles")
                .select()
                .eq("auth_user_id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first
        }
    }

    // MARK: Bootstrap

    public func createFamily(familyName: String, parentName: String,
                             timezone: String) async throws -> UUID {
        try await run {
            try await client
                .rpc("create_family", params: [
                    "family_name": familyName,
                    "parent_name": parentName,
                    "family_timezone": timezone
                ])
                .execute()
                .value
        }
    }

    public func claimProfile(code: String) async throws -> UUID {
        try await run {
            try await client
                .rpc("claim_profile", params: ["p_code": code])
                .execute()
                .value
        }
    }

    // MARK: Reads

    public func fetchSnapshot(familyID: UUID,
                             weekOf day: CalendarDay) async throws -> FamilySnapshot {
        try await run {
            let week = WeekCalendar.isoWeek(containing: day)
            let firstDay = ChoresJSON.encodedDay(week.first!)
            let lastDay = ChoresJSON.encodedDay(week.last!)

            // Five small queries in parallel. The whole family is ~100 rows, so this
            // is one round trip's worth of latency rather than five.
            async let families: [Family] = client.from("families")
                .select().eq("id", value: familyID).execute().value
            async let profiles: [Profile] = client.from("profiles")
                .select().eq("family_id", value: familyID).execute().value
            async let chores: [Chore] = client.from("chores")
                .select().eq("family_id", value: familyID).execute().value
            async let template: [ScheduleEntry] = client.from("schedule_entries")
                .select().eq("family_id", value: familyID).execute().value
            async let completions: [Completion] = client.from("completions")
                .select().eq("family_id", value: familyID)
                .gte("due_on", value: firstDay).lte("due_on", value: lastDay)
                .execute().value

            guard let family = try await families.first else {
                throw ChoresBackendError.underlying("family not found")
            }
            return FamilySnapshot(
                family: family,
                profiles: try await profiles,
                chores: try await chores,
                template: try await template,
                completions: try await completions,
                fetchedAt: Date())
        }
    }

    // MARK: Children

    public func addChild(familyID: UUID, name: String, color: String,
                         sortOrder: Int) async throws -> Profile {
        try await run {
            let payload = NewProfile(familyID: familyID, displayName: name,
                                     role: "child", color: color, sortOrder: sortOrder)
            let rows: [Profile] = try await client
                .from("profiles").insert(payload).select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("insert returned no row")
            }
            return created
        }
    }

    public func addParent(familyID: UUID, name: String) async throws -> Profile {
        try await run {
            // Colour and sort order only drive the child-facing rings and
            // ordering, so parents take the defaults.
            let payload = NewProfile(familyID: familyID, displayName: name,
                                     role: "parent", color: "#8E8E93", sortOrder: 0)
            let rows: [Profile] = try await client
                .from("profiles").insert(payload).select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("insert returned no row")
            }
            return created
        }
    }

    public func updateProfile(_ profile: Profile) async throws {
        try await run {
            let payload = ProfileUpdate(displayName: profile.displayName,
                                        color: profile.color,
                                        sortOrder: profile.sortOrder)
            _ = try await client
                .from("profiles").update(payload).eq("id", value: profile.id).execute()
        }
    }

    public func generateClaimCode(profileID: UUID) async throws -> String {
        try await run {
            try await client
                .rpc("generate_claim_code", params: ["p_profile_id": profileID])
                .execute()
                .value
        }
    }

    // MARK: Chores

    public func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        try await run {
            let payload = NewChore(familyID: familyID, name: name, icon: icon)
            let rows: [Chore] = try await client
                .from("chores").insert(payload).select().execute().value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("insert returned no row")
            }
            return created
        }
    }

    public func updateChore(_ chore: Chore) async throws {
        try await run {
            let payload = ChoreUpdate(name: chore.name, icon: chore.icon,
                                      isArchived: chore.isArchived)
            _ = try await client
                .from("chores").update(payload).eq("id", value: chore.id).execute()
        }
    }

    // MARK: Schedule

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int) async throws -> ScheduleEntry {
        try await run {
            let payload = NewScheduleEntry(familyID: familyID, profileID: profileID,
                                           choreID: choreID, weekday: weekday)
            // Upsert so assigning an already-assigned chore is a no-op rather than
            // a unique-violation the UI would have to interpret.
            let rows: [ScheduleEntry] = try await client
                .from("schedule_entries")
                .upsert(payload, onConflict: "profile_id,chore_id,weekday")
                .select()
                .execute()
                .value
            guard let created = rows.first else {
                throw ChoresBackendError.underlying("upsert returned no row")
            }
            return created
        }
    }

    public func removeScheduleEntry(id: UUID) async throws {
        try await run {
            _ = try await client
                .from("schedule_entries").delete().eq("id", value: id).execute()
        }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        try await run {
            let source: [ScheduleEntry] = try await client
                .from("schedule_entries")
                .select()
                .eq("family_id", value: familyID)
                .eq("weekday", value: fromWeekday)
                .execute()
                .value

            for target in toWeekdays where target != fromWeekday {
                // Replace rather than merge: copying Monday onto Tuesday should
                // leave Tuesday looking like Monday.
                _ = try await client
                    .from("schedule_entries").delete()
                    .eq("family_id", value: familyID)
                    .eq("weekday", value: target)
                    .execute()

                let copies = source.map {
                    NewScheduleEntry(familyID: familyID, profileID: $0.profileID,
                                     choreID: $0.choreID, weekday: target)
                }
                if !copies.isEmpty {
                    _ = try await client.from("schedule_entries").insert(copies).execute()
                }
            }
        }
    }

    // MARK: Completions

    public func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                         dueOn: CalendarDay, completedBy: UUID) async throws {
        try await run {
            let payload = NewCompletion(familyID: familyID, profileID: profileID,
                                        choreID: choreID, dueOn: dueOn,
                                        completedBy: completedBy)
            // Idempotent by the (profile_id, chore_id, due_on) constraint, which is
            // what lets the outbox replay without tracking what it already sent.
            _ = try await client
                .from("completions")
                .upsert(payload, onConflict: "profile_id,chore_id,due_on",
                        ignoreDuplicates: true)
                .execute()
        }
    }

    public func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        try await run {
            _ = try await client
                .from("completions").delete()
                .eq("profile_id", value: profileID)
                .eq("chore_id", value: choreID)
                .eq("due_on", value: ChoresJSON.encodedDay(dueOn))
                .execute()
        }
    }
}

// MARK: - Insert and update payloads
//
// Separate from the models because writes omit server-generated columns, and
// because updates must not touch columns the database protects (auth_user_id).

private struct NewProfile: Encodable {
    let familyID: UUID
    let displayName: String
    let role: String
    let color: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case role, color
        case familyID = "family_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

private struct ProfileUpdate: Encodable {
    let displayName: String
    let color: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case color
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

private struct NewChore: Encodable {
    let familyID: UUID
    let name: String
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case name, icon
        case familyID = "family_id"
    }
}

private struct ChoreUpdate: Encodable {
    let name: String
    let icon: String?
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case name, icon
        case isArchived = "is_archived"
    }
}

private struct NewScheduleEntry: Encodable {
    let familyID: UUID
    let profileID: UUID
    let choreID: UUID
    let weekday: Int

    enum CodingKeys: String, CodingKey {
        case weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
    }
}

private struct NewCompletion: Encodable {
    let familyID: UUID
    let profileID: UUID
    let choreID: UUID
    let dueOn: CalendarDay
    let completedBy: UUID

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case dueOn = "due_on"
        case completedBy = "completed_by"
    }
}
