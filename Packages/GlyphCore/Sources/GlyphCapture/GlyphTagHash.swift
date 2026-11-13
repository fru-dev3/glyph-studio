import SwiftUI

/// The family's tag mark: a bold `#` in the tag's own colour, 16 wide so every name in a list
/// starts at the same place. Glyph Jot has drawn tags this way all along, and Fru asked for the
/// same in Glyph Wealth: "Look at how I did it for Jot and the Well app. It should be obvious what
/// you need to do there, so you're not reinventing the wheel."
///
/// The colour: an app that knows a tag's own colour passes it. Otherwise one is picked from the
/// palette by the same hash Glyph Jot uses, so a tag keeps its colour across launches and across
/// apps, and two apps showing the same tag show it the same.
public struct GlyphTagHash: View {
    private let name: String
    private let size: CGFloat
    private let known: Color?

    public init(name: String, size: CGFloat = 15.5, color: Color? = nil) {
        self.name = name; self.size = size; self.known = color
    }

    public static let palette: [Color] = [.officeGreen, .blue, .indigo, .purple, .pink, .teal, .red, .brown, .cyan, .mint]

    /// djb2 over the lowercased name, which is what Glyph Jot has used since its tags began. The
    /// same name must land on the same colour in every app, so the algorithm is the shared thing
    /// here, not a table someone has to keep in step.
    public static func index(_ name: String, of count: Int) -> Int {
        let hash = name.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff }
        return hash % max(count, 1)
    }

    public static func color(_ name: String) -> Color { palette[index(name, of: palette.count)] }

    public var body: some View {
        Text("#")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(known ?? Self.color(name))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}
