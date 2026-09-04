import SwiftUI
import ChoresCore

/// The door: a parent goes one way, a device with a code the other.
struct OnboardingView: View {
    let environment: AppEnvironment
    let onFinished: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The only centred screen: the app icon's ring, the name, and
                // one line, sitting in the middle of the space above the buttons.
                Spacer(minLength: Theme.blockGap)

                VStack(spacing: 0) {
                    Image("RingMark")
                        .resizable()
                        .frame(width: 168, height: 168)
                        .accessibilityHidden(true)
                    // The app's own name, read from the bundle: not a word to
                    // translate, and not a literal to keep in step with the
                    // project file by hand. A key of its own would also collide
                    // with the chore list's "Chores" title, which does become
                    // "Tehtävät".
                    Text(verbatim: AppIdentity.displayName)
                        .font(.system(size: 44, weight: .medium))
                        .tracking(-44 * 0.03)
                        .foregroundStyle(Theme.text)
                        .padding(.top, 32)
                    Text("Set up this device.")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.neutral500)
                        .padding(.top, 8)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)

                Spacer(minLength: Theme.blockGap)

                NavigationLink {
                    ParentSignInView(environment: environment, onFinished: onFinished)
                } label: {
                    Text("I'm a parent")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("onboarding.parent")

                NavigationLink {
                    ClaimCodeView(environment: environment, onFinished: onFinished)
                } label: {
                    Text("I have a code")
                }
                .buttonStyle(.secondary)
                .padding(.top, 10)
                .accessibilityIdentifier("onboarding.child")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.screenInset)
            .padding(.bottom, 16)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// What sits above an onboarding screen's header: nothing on a root, "Back" on
/// a pushed screen, or "Cancel" on one presented as the root of its own stack
/// with nothing behind it.
enum OnboardingNavigation {
    case none
    case back
    case cancel(() -> Void)

    /// `Back` when pushed, `Cancel` when the caller supplied a way out.
    static func forScreen(onCancel: (() -> Void)?) -> OnboardingNavigation {
        if let onCancel { return .cancel(onCancel) }
        return .back
    }
}

/// The shape every onboarding and failure screen shares: a header at the top,
/// content beneath it, and whatever goes at the foot pinned above the home
/// indicator. The navigation bar is hidden throughout; the way back is drawn
/// here, in the content, where the system's glass capsule cannot squeeze it.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    var navigation: OnboardingNavigation = .none
    let kicker: Text
    let title: Text
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            switch navigation {
            case .none:
                EmptyView()
            case .back:
                BackButton(label: Text("Back"))
                    .padding(.leading, -6)
                    .padding(.bottom, -Theme.blockGap + 4)
            case .cancel(let onCancel):
                Button("Cancel") { onCancel() }
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .padding(.bottom, -Theme.blockGap + 4)
            }
            ScreenHeader(kicker: kicker, title: title)
            content
            Spacer(minLength: Theme.blockGap)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.screenInset)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    OnboardingView(environment: .preview(), onFinished: {})
}
