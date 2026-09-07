import SwiftUI

// MARK: Rows

extension View {
    /// A list row's shape: left-aligned, a minimum height, a little vertical
    /// padding, and the fading rule along its bottom edge.
    func ruledRow(minHeight: CGFloat, verticalPadding: CGFloat = 6) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: minHeight)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, 2)
            .overlay(alignment: .bottom) { FadingRule() }
    }

    /// A `List` drawn on the Nocturne ground: no grouped chrome, no inset
    /// backgrounds. Rows opt in with `nocturneRow()`.
    func nocturneList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .environment(\.defaultMinListRowHeight, 1)
    }

    /// Strips the system separator, background and insets from a row so the
    /// content draws its own rule and sits on the screen inset.
    func nocturneRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.screenInset,
                                      bottom: 0, trailing: Theme.screenInset))
    }
}

/// Plus glyph and label in accent300. Replaces toolbar buttons and section
/// footers as the way to add something to a list.
struct AddRow: View {
    let label: Text
    var minHeight: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                label
                    .font(.system(size: 15))
            }
            .foregroundStyle(Theme.accent300)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: minHeight)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A hub entry on Manage: icon tile, label, a line of meta, a chevron.
struct HubRow: View {
    let systemImage: String
    let label: Text
    var meta: Text? = nil

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.surface)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent300)
                }
            label
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if let meta {
                meta
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.neutral500)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.neutral600)
        }
        .ruledRow(minHeight: 56, verticalPadding: 4)
        .contentShape(Rectangle())
    }
}

// MARK: Navigation

/// How a pushed screen goes back when `dismiss()` cannot be relied on — from a
/// row inside a `List`, the environment's dismiss action does not reach the
/// navigation stack. A stack that owns its path sets this on its destinations.
private struct PopActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var popAction: (() -> Void)? {
        get { self[PopActionKey.self] }
        set { self[PopActionKey.self] = newValue }
    }
}

/// Chevron plus the name of the screen behind, in the accent. Replaces the
/// system back button on every pushed screen.
struct BackButton: View {
    let label: Text
    @Environment(\.dismiss) private var dismiss
    @Environment(\.popAction) private var popAction

    var body: some View {
        Button {
            if let popAction { popAction() } else { dismiss() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                label
                    .font(.system(size: 15))
            }
            .foregroundStyle(Theme.accent)
            // The whole width, so a tap anywhere along the row goes back.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nav.back")
    }
}

extension View {
    /// A pushed screen's chrome: none. The navigation bar is hidden and the
    /// screen draws its own `BackButton` at the top of its content, where the
    /// system's glass capsule cannot squeeze it.
    func nocturneNavigation() -> some View {
        self
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Hiding the navigation bar switches off the swipe-from-the-left-edge pop
/// gesture with it. This hands the gesture a delegate that allows it whenever
/// there is somewhere to pop back to, which is the behaviour a visible bar has.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

extension View {
    /// The tab bar is the system's: Liquid Glass on iOS 26, where it also
    /// shrinks to the active icon while the content scrolls down and comes
    /// back on the way up. Earlier systems draw their usual bar and ignore this.
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

// MARK: Buttons

/// Full-width, 50pt, an outline. Primary is the accent; secondary is a
/// neutral800 outline with a text-coloured label.
struct OutlineButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    private var color: Color { kind == .primary ? Theme.accent : Theme.text }
    private var outline: Color { kind == .primary ? Theme.accent : Theme.neutral800 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(configuration.isPressed
                          ? (kind == .primary ? Theme.accent.opacity(0.1) : Theme.surface)
                          : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(outline, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var primary: OutlineButtonStyle { OutlineButtonStyle(kind: .primary) }
    static var secondary: OutlineButtonStyle { OutlineButtonStyle(kind: .secondary) }
}

// MARK: Fields

/// A text field on a surface: radius 8, a 1pt edge that turns accent while
/// focused, an optional kicker above.
struct NocturneField: View {
    enum Style {
        case text
        /// 28pt, spaced out, for a six-character setup code.
        case code
    }

    var kicker: Text? = nil
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var style: Style = .text
    var autocapitalization: TextInputAutocapitalization = .words
    let identifier: String

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let kicker {
                Kicker(text: kicker)
            }
            TextField(placeholder, text: $text)
                .font(style == .code
                      ? .system(size: 28, weight: .regular, design: .monospaced)
                      : .system(size: 17))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(style == .code)
                .focused($isFocused)
                .padding(.vertical, style == .code ? 14 : 13)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(isFocused ? Theme.accent : Theme.neutral800, lineWidth: 1)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)
                }
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: Sheets

/// Cancel (left) · title (centre) · the primary action (right).
struct SheetHeader<Primary: View>: View {
    var onCancel: (() -> Void)? = nil
    let title: Text
    @ViewBuilder let primary: Primary

    var body: some View {
        ZStack {
            HStack {
                if let onCancel {
                    Button("Cancel") { onCancel() }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                primary
                    .font(.system(size: 15, weight: .medium))
                    .buttonStyle(.plain)
            }
            title
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .frame(minHeight: 44)
    }
}

/// The right-hand action in a `SheetHeader`: accent, or neutral600 when it
/// cannot be used yet.
struct SheetPrimaryButton: View {
    let title: Text
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.accent : Theme.neutral600)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

extension View {
    /// A sheet's chrome: surface background, 16pt corners, medium and large
    /// detents, 22pt side padding. Applied by the sheet's own body.
    func nocturneSheet() -> some View {
        self
            .padding(.horizontal, Theme.screenInset)
            .padding(.top, 14)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.surface)
            .presentationDetents([.medium, .large])
            .presentationBackground(Theme.surface)
            .presentationCornerRadius(16)
    }
}
