import SwiftUI
import ChoresCore

/// The only place the parent/child split is decided. Which mode a device shows is
/// fixed at claim time, so there is no switcher and no PIN gate.
struct RootView: View {
    let environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionViewModel
    /// Set once this device resolves to a profile. If it later resolves to
    /// nothing, that is a lost session rather than a fresh device — a different
    /// screen with a different remedy.
    @AppStorage(AppEnvironment.hasBeenClaimedKey) private var hasBeenClaimed = false
    @State private var isReclaiming = false

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
                if !hasBeenClaimed {
                    OnboardingView(environment: environment) {
                        await session.refresh()
                    }
                } else if isReclaiming {
                    NavigationStack {
                        ClaimCodeView(environment: environment) {
                            await session.refresh()
                        }
                    }
                } else {
                    LostSessionView { isReclaiming = true }
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
        .onChange(of: session.state) { _, newState in
            switch newState {
            case .parent, .child:
                hasBeenClaimed = true
                isReclaiming = false
            default:
                break
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Anything queued while offline goes out as soon as the app is frontmost.
            guard newPhase == .active else { return }
            Task { await environment.outbox.flush() }
        }
    }
}
