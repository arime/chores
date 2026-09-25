import SwiftUI

extension View {
    /// The wrap-up card's box: surface fill, 8pt corners, a 1pt neutral800
    /// edge, 14pt padding. The parent card ends in a list of rows and wants
    /// less at the bottom.
    func wrapUpCard(bottomPadding: CGFloat = 14) -> some View {
        self
            .padding(.top, 14)
            .padding(.horizontal, 14)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.neutral800, lineWidth: 1)
            }
            // A container, so the card's own identifier reaches the
            // accessibility tree while its texts and the × stay reachable.
            .accessibilityElement(children: .contain)
    }
}

/// The × in a card's top-right corner: a 32pt target around a 14pt glyph, pulled
/// into the card's padding so the glyph sits where the eye expects it.
struct CardDismissButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.neutral600)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -6)
        .padding(.trailing, -8)
        .accessibilityLabel(Text("Dismiss"))
        .accessibilityIdentifier(identifier)
    }
}
