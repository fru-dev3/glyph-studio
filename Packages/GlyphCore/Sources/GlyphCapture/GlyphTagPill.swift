#if os(iOS)
import SwiftUI

/// The family's tag chip, as Glyph Jot has drawn one since its tags began: the `#` in the tag's
/// own colour, the name, and how many carry it (Fru, 2026-11-11, of Glyph Wealth's ribbon against
/// Glyph Jot's: "match").
///
/// The chosen chip is NEVER filled with the tag's own hue. A blue or pink capsule reads as another
/// app, and this family is office green and grey, with red kept for a live recording. The hue
/// stays on the `#` alone.
///
/// Glyph Jot still draws its own copy (`Jot/Tags.swift`), because that one also carries long-press
/// renaming, the vault domain and the order. It is the one to move onto this next, and it is said
/// here so nobody assumes there is only one.
public struct GlyphTagPill: View {
    private let name: String
    private let on: Bool
    private let count: Int
    /// The "All" chip: no `#`, and the app's own green rather than a tag's hue.
    private let all: Bool
    private let tint: Color

    public init(_ name: String, on: Bool = false, count: Int = 0, all: Bool = false, tint: Color = .officeGreen) {
        self.name = name; self.on = on; self.count = count; self.all = all; self.tint = tint
    }

    /// Jot's own values, so a chip is the same chip in both apps: 42 tall, #1c1c1e on a #2c2c2e
    /// hairline, chosen #10240f on #27512f with #7fd49a lettering.
    static let ground = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    static let edge = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)
    static let litGround = Color(red: 0x10 / 255, green: 0x24 / 255, blue: 0x0f / 255)
    static let litEdge = Color(red: 0x27 / 255, green: 0x51 / 255, blue: 0x2f / 255)
    static let lit = Color(red: 0x7f / 255, green: 0xd4 / 255, blue: 0x9a / 255)
    static let text = Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xea / 255)
    static let quiet = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)

    public var body: some View {
        HStack(spacing: 6) {
            if !all {
                Text("#").font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(GlyphTagHash.color(name))
            }
            Text(name).lineLimit(1)
            if count > 0 {
                Text("\(count)").monospacedDigit().foregroundStyle(on ? Self.lit : Self.quiet)
            }
        }
        .font(.system(size: 14.5, weight: .semibold))
        .padding(.horizontal, 16)
        .frame(height: 42)
        .foregroundStyle(on ? Self.lit : Self.text)
        .background(on ? Self.litGround : Self.ground, in: Capsule())
        .overlay { Capsule().strokeBorder(on ? Self.litEdge : Self.edge, lineWidth: 1) }
    }
}
#endif
