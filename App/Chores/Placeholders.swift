import SwiftUI
import ChoresCore

// Temporary destinations so each task in the plan is independently buildable.
// Each is deleted by the task that replaces it:
//   ParentWeekView          → Task 20
//   KidRootView             → Task 21
//   KidWeekView             → Task 22
//   BackendUnavailableView  → Task 24 (which deletes this file)

struct ParentWeekView: View {
    let store: FamilyStore
    var body: some View { Text("Week") }
}

struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    var body: some View { Text("Kid: \(profile.displayName)") }
}

struct BackendUnavailableView: View {
    let retry: () async -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
        } description: {
            Text("The Supabase project may be paused. Open the dashboard and resume it, then try again.")
        } actions: {
            Button("Try again") { Task { await retry() } }
        }
    }
}
