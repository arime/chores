import SwiftUI
import ChoresCore

// Temporary destinations so each task in the plan is independently buildable.
// Each is deleted by the task that replaces it:
//   OnboardingView          → Task 14
//   ParentRootView          → Task 16
//   ParentTodayView         → Task 19
//   ParentWeekView          → Task 20
//   ChoresView              → Task 17
//   ScheduleEditorView      → Task 18
//   KidRootView             → Task 21
//   KidWeekView             → Task 22
//   BackendUnavailableView  → Task 24 (which deletes this file)

struct OnboardingView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void
    var body: some View { Text("Onboarding") }
}

struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    var body: some View { Text("Parent: \(profile.displayName)") }
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
