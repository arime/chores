import SwiftUI

/// The "Nocturne" palette the kid screens are drawn in: a near-neutral blue-grey
/// ground, medium-weight type, and three evenly weighted hues — the child's own
/// colour, a mint for done, an amber for a past day left unfinished.
///
/// Every value here is a dark-appearance colour. The kid screens force dark, so
/// nothing in this file has to adapt; the two exceptions (`divider`, and the
/// text colours `ChoreRow` picks) go through system colours so the shared row
/// still reads on a parent's light screen.
enum Theme {
    // MARK: Ground & neutrals
    static let bg = Color(hexString: "#161826")
    static let surface = Color(hexString: "#232532")
    static let text = Color(hexString: "#e9e9ed")
    static let neutral300 = Color(hexString: "#cfd3e5")
    static let neutral500 = Color(hexString: "#9397ab")
    static let neutral600 = Color(hexString: "#75798c")
    static let neutral800 = Color(hexString: "#3f424d")
    static let neutral900 = Color(hexString: "#292b31")
    /// The text colour at 16%. `.primary` rather than `text` so the same hairline
    /// also shows on a light parent screen; in dark they are indistinguishable.
    static let divider = Color.primary.opacity(0.16)

    // MARK: Status hues (fixed, not per child)
    static let done = Color(hexString: "#3ca977")
    static let doneSoft = Color(hexString: "#a3e2bf")
    static let doneTint = done.opacity(0.18)
    static let warn = Color(hexString: "#cd9130")

    // MARK: Spacing & shape
    /// Horizontal padding of a kid screen.
    static let screenInset: CGFloat = 22
    /// Vertical gap between the header, strip and list blocks.
    static let blockGap: CGFloat = 17
    static let cornerRadius: CGFloat = 8
}

/// A child's colour and the two darker steps the selected-day cell is built
/// from. `Profile.color` stays a hex string; this is only how a screen reads it.
struct ChildHue {
    let base: Color
    /// The selected cell's 1pt stroke.
    let step700: Color
    /// The selected cell's fill.
    let step900: Color

    /// Steps are looked up by base hex. A colour that predates this palette —
    /// still stored on children added before it — gets its own base dimmed
    /// instead, so an old profile never renders without a selection colour.
    init(hex: String) {
        let base = Color(hexString: hex)
        if let steps = ProfilePalette.steps[hex.lowercased()] {
            self.base = base
            self.step700 = Color(hexString: steps.step700)
            self.step900 = Color(hexString: steps.step900)
        } else {
            self.base = base
            self.step700 = base.opacity(0.6)
            self.step900 = base.opacity(0.25)
        }
    }
}

/// A 1pt hairline that is transparent at both ends — the Nocturne signature.
/// Under each chore row (40pt ramps) and along the top of the kid tab bar (48pt).
struct FadingRule: View {
    var ramp: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            // The ramps cannot overlap on a rule narrower than two of them; clamp
            // so the gradient stops still ascend.
            let edge = min(ramp / width, 0.5)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Theme.divider, location: edge),
                    .init(color: Theme.divider, location: 1 - edge),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}
