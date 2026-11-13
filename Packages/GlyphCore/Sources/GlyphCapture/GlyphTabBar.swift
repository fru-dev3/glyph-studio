import SwiftUI

/// The family's floating bar of places, under the composer: a 64pt pill, 16 off each side, the
/// place you are on in a filled chip. Drawn once here because Fru's governing rule is one model
/// for every app: "the same design, the same layout, the same pixel, the same placement that just
/// repeats throughout every single page". An app passes its places, its tint and the chip colour,
/// and never a dimension.
///
/// Glyph Well drew this first and its own `WellTabBar` is now this view with Well's places and
/// colours; Glyph Wealth draws the same bar with its own.
public struct GlyphTabBar: View {
    public struct Place: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let symbol: String
        public init(id: String, name: String, symbol: String) {
            self.id = id; self.name = name; self.symbol = symbol
        }
    }

    /// The bar's own height. A page that pins anything above it clears this plus the air, because
    /// the bar is an overlay and reserves nothing of its own.
    public static let height: CGFloat = 64

    @Binding var place: String
    let places: [Place]
    let on: Color
    let chip: Color
    let card: Color
    let edge: Color

    public init(place: Binding<String>, places: [Place], on: Color, chip: Color, card: Color, edge: Color) {
        self._place = place; self.places = places; self.on = on; self.chip = chip; self.card = card; self.edge = edge
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(places) { item in
                let here = place == item.id
                Button { place = item.id } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 19, weight: .medium))
                        Text(item.name).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(here ? on : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    // The place you are on sits in a filled chip, as the system draws a chosen
                    // chip: colour alone is a thin signal on a bar of six.
                    .background(here ? chip : Color.clear, in: .rect(cornerRadius: 20, style: .continuous))
                    .contentShape(.rect)
                    // One element per place, not an icon and a word: VoiceOver reads six buttons
                    // rather than twelve pieces.
                    .accessibilityElement(children: .ignore)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                // The place you are on is "selected" to VoiceOver as well as filled on screen,
                // which is also how a check asks where it is.
                .accessibilityAddTraits(here ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tab.\(item.id)")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: GlyphTabBar.height)
        .background(card, in: .rect(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(edge, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
