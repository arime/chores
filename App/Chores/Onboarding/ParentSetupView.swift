import SwiftUI
import ChoresCore

/// Signed in, but not yet in a family. Filled in by Task 10.
struct ParentSetupView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View { ProgressView() }
}
