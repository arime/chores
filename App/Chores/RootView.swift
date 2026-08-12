import SwiftUI
import ChoresCore

/// The only place the parent/child split is decided. Which mode a device shows is
/// fixed at claim time, so there is no switcher and no PIN gate.
struct RootView: View {
    let environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _session = State(initialValue: SessionViewModel(backend: environment.backend))
    }

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .unclaimed:
                OnboardingView(environment: environment) {
                    await session.refresh()
                }
            case .parent(let profile):
                ParentRootView(environment: environment, profile: profile)
            case .child(let profile):
                KidRootView(environment: environment, profile: profile)
            case .unavailable:
                BackendUnavailableView { await session.start() }
            }
        }
        .task { await session.start() }
        .onChange(of: scenePhase) { _, newPhase in
            // Anything queued while offline goes out as soon as the app is frontmost.
            guard newPhase == .active else { return }
            Task { await environment.outbox.flush() }
        }
    }
}
