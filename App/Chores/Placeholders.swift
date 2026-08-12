import SwiftUI
import ChoresCore

// Temporary destinations so each task in the plan is independently buildable.
// Each is deleted by the task that replaces it:
//   ParentTodayView         → Task 19
//   ParentWeekView          → Task 20
//   ChoresView              → Task 17
//   ScheduleEditorView      → Task 18
//   KidRootView             → Task 21
//   KidWeekView             → Task 22
//   BackendUnavailableView  → Task 24 (which deletes this file)

struct ParentTodayView: View {
    let store: FamilyStore
    var body: some View { Text("Today") }
}

struct ParentWeekView: View {
    let store: FamilyStore
    var body: some View { Text("Week") }
}

struct ChoresView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    var body: some View { Text("Chores") }
}

struct ScheduleEditorView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    var body: some View { Text("Schedule") }
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
