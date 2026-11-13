import AppKit
import SwiftUI
import GlyphCapture

/// Studio's look. Dark is the family's, token for token (the vault skill
/// `apply-glyph-app-design-system`, the same ground, raised, hairline and accent as Glyph Jot and
/// Glyph Time); light keeps the design renders in design/ (gen.py is the source). Every dark value
/// here is a family token, never a value derived from the light one.
enum Ink {
    /// Titles (family text).
    static let text = Color(hex: 0x111111, dark: 0xF5F5F7)
    /// Body (family text soft).
    static let secondary = Color(hex: 0x5F6460, dark: 0xE6E6EA)
    /// Meta: the contrast floor, nothing dimmer carries words (family text quiet).
    static let tertiary = Color(hex: 0x8A8F8B, dark: 0x8E8E93)
    /// The dark ladder, named so it can be checked rather than eyeballed. In light the page is
    /// white and everything laid on it steps DOWN (bubble F6F7F5, chip F1F2F0, border E3E5E2). On
    /// near-black the same stack has to step UP, and giving those tokens the light values unchanged
    /// is what put a 0x232325 bubble on a 0x232325 page, where it had no edge at all.
    enum Dark {
        /// The board ground, under everything.
        static let ground: UInt32 = 0x1C1C1E
        /// The window, the rail, and a card raised off the ground.
        static let page: UInt32 = 0x232325
        /// A bubble or card laid ON the page.
        static let raised: UInt32 = 0x2C2C2E
        /// A chip, a border or a rule on top of that.
        static let edge: UInt32 = 0x3A3A3C
    }

    static let line = Color(hex: 0xEEEFED, dark: Dark.raised)
    static let chip = Color(hex: 0xF1F2F0, dark: Dark.edge)
    static let bubble = Color(hex: 0xF6F7F5, dark: Dark.raised)
    /// The board ground (family ground), with the dots just above it.
    static let canvas = Color(hex: 0xF5F5F3, dark: Dark.ground)
    static let dot = Color(hex: 0xDCDEDB, dark: Dark.raised)
    /// The accent is a fill, never a word: #008000 fails as text on near-black.
    static let green = Color(hex: 0x008000, dark: 0x008000)
    /// Green as words (family accent light): headings, ticks, chip labels.
    static let greenText = Color(hex: 0x0B6B16, dark: 0x4AA96C)
    static let greenSoft = Color(hex: 0xE8F3E8, dark: 0x10240F)
    static let warn = Color(hex: 0x9A5B00, dark: 0xE5A23D)
    static let warnSoft = Color(hex: 0xFBEFDC, dark: 0x2A2114)
    /// A mark that has to stay grey in BOTH modes: the one tick meaning you owe it something.
    /// Not `secondary`, which is near-white on near-black and would outshout the green it must not;
    /// not `tertiary`, which is about 3:1 on a light bubble and too faint to find.
    static let mark = Color(hex: 0x5F6460, dark: 0x8E8E93)
    static let border = Color(hex: 0xE3E5E2, dark: Dark.edge)
    /// The window and card surface: white, the family's page in dark mode.
    static let surface = Color(hex: 0xFFFFFF, dark: Dark.page)
    /// Text on an ink fill (your own messages, the selected tab).
    static let onInk = Color(hex: 0xFFFFFF, dark: 0x111111)
}

extension Color {
    /// A design colour that follows the appearance, for the greys the screens still name inline.
    /// Prefer an `Ink` token; this is the floor under the ones that are not one yet.
    init(hex: UInt32) { self.init(hex: hex, dark: Self.darkVariant(hex)) }

    init(hex: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgb: isDark ? dark : hex)
        })
    }

    /// Exactly this colour in both appearances (a teammate's avatar).
    init(fixed hex: UInt32) { self.init(nsColor: NSColor(srgb: hex)) }

    /// The family's dark greys, the only ones allowed on near-black (the vault skill's table):
    /// sunken, ground, raised, panel hairline, border, a control track, the text floor, body, titles.
    /// `0x6E6E73` and `0x5A5A5F` are deliberately absent: they fail 4.5:1 and must never carry words,
    /// and an inline grey gives no way to tell a timestamp from a dot.
    static let familyGreys: [UInt32] = [0x141416, 0x1C1C1E, 0x232325, 0x242427, 0x2C2C2E, 0x3A3A3C,
                                        0x8E8E93, 0xE6E6EA, 0xF5F5F7]

    /// A grey flips (white becomes a surface, ink becomes light text) and then SNAPS to the nearest
    /// family grey, so no invented value reaches the screen. Anything with a hue is left alone: a
    /// tint or a coloured word needs a chosen dark value on its `Ink` token, not a formula.
    static func darkVariant(_ hex: UInt32) -> UInt32 {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        let s = mx == mn ? 0 : (l > 0.5 ? (mx - mn) / (2 - mx - mn) : (mx - mn) / (mx + mn))
        guard s < 0.12 || mx - mn < 0.04 else { return hex }
        let want = 0.11 + (1 - l) * 0.84
        func lightness(_ c: UInt32) -> Double {
            let cr = Double((c >> 16) & 0xFF) / 255, cg = Double((c >> 8) & 0xFF) / 255, cb = Double(c & 0xFF) / 255
            return (max(cr, cg, cb) + min(cr, cg, cb)) / 2
        }
        return familyGreys.min { abs(lightness($0) - want) < abs(lightness($1) - want) } ?? 0x232325
    }
}

extension NSColor {
    convenience init(srgb hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// SF at an exact size, as the renders use.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// New York for the owner's own words (whys, the purpose).
}

/// A section label: small caps grey, as above every board group.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.ui(12, .semibold)).tracking(0.7).foregroundStyle(Ink.greenText)
    }
}

// MARK: teammates

/// How a teammate looks: a shape, a colour, a glyph. Stored in the domain's manifest.json (`studio`).
struct Look: Codable, Hashable {
    enum Shape: String, Codable, CaseIterable { case circle, squircle, leaf, drop, square }
    var shape: Shape
    var color: UInt32
    var glyph: String // an SF Symbol name, or "figure" for the chief of staff's petroglyph

    /// Green and grey, nothing else (the owner, 2026-11-07): office green for the one who runs the team, a
    /// family grey for every other agent. A face reads by its shape and its mark, not by a hue, and six
    /// colours competing with the accent made the rail look like a toy. A manifest that still stores a
    /// retired hue keeps working: `settled(_:)` below brings it onto this list.
    static let palette: [UInt32] = [0x008000, 0x2C2C2E, 0x3A3A3C, 0x48484C, 0x56565B, 0x6E6E73]

    /// A colour a manifest stored before green and grey, brought onto the palette. The ink that stood
    /// for the lead tile becomes the accent; any other retired hue lands on a grey, the same one
    /// every launch, so the rail does not reshuffle. Settled once, where a manifest is read
    /// (`AppModel.look(for:)`); nothing downstream needs to know a hue ever existed.
    static func settled(_ color: UInt32) -> UInt32 {
        if palette.contains(color) { return color }
        if color == 0x111111 { return 0x008000 }
        // The channels are folded rather than taken modulo whole, because the retired hues are
        // close together in their low byte and a plain modulo put eight of them on two shades.
        let greys = Array(palette.dropFirst())
        let mixed = ((color >> 16) & 0xFF) &+ ((color >> 8) & 0xFF) &* 3 &+ (color & 0xFF) &* 7
        return greys[Int(mixed % UInt32(greys.count))]
    }
}

/// The coloured shape that stands for a teammate (Grok Bot's idea), with a living face on it
/// (Shared/Face.swift): it reacts to what the agent is doing. The chief of staff is office green.
struct Avatar: View {
    let look: Look
    var size: CGFloat = 44
    var mood: FaceMood = .rest

    var body: some View {
        shape.fill(Color(fixed: look.color))
            .frame(width: size, height: size)
            .overlay {
                // The agent's own mark on its forehead (its domain's line icon), the face below it.
                if TeamGlyph.drawn.contains(look.glyph) {
                    let m = (size * 0.24).rounded()
                    TeamGlyph(name: look.glyph).stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: max(1, 3.6 * m / 40), lineCap: .round, lineJoin: .round))
                        .frame(width: m, height: m).offset(y: -size * 0.27)
                }
                FaceFeatures(mood: mood, size: size, seed: FaceMood.seed(look.glyph + String(look.color)))
            }
            .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        let r = size / 2
        switch look.shape {
        case .circle: return AnyShape(Circle())
        case .squircle: return AnyShape(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
        case .square: return AnyShape(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous))
        case .leaf: return AnyShape(UnevenRoundedRectangle(topLeadingRadius: r * 0.45, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous))
        case .drop: return AnyShape(UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r * 0.36, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)) // CSS 22 22 22 8: bottom-left
        }
    }

    @ViewBuilder private var glyph: some View {
        if TeamGlyph.drawn.contains(look.glyph) {
            // The design's own 40x40 line drawings, at its size (52%) and stroke (3.4 of 40).
            let s = (size * 0.52).rounded(.down) // as gen.py: int(size * .52)
            TeamGlyph(name: look.glyph).stroke(style: StrokeStyle(lineWidth: 3.4 * s / 40, lineCap: .round, lineJoin: .round))
                .frame(width: s, height: s)
        } else {
            Image(systemName: look.glyph).font(.system(size: size * 0.36, weight: .medium))
        }
    }
}

/// The teammates' line icons, drawn from the design's 40x40 SVG paths (design/gen.py ICONS), keyed by
/// the SF Symbol name each stands in for; any other glyph is drawn as that SF Symbol.
struct TeamGlyph: Shape {
    let name: String
    static let drawn: Set<String> = ["figure", "house", "doc.text", "chart.bar", "chart.line.uptrend.xyaxis", "heart",
                                     "briefcase", "person.2", "line.3.horizontal", "magnifyingglass"]
    func path(in r: CGRect) -> Path {
        let k = r.width / 40
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var path = Path()
        func line(_ pts: [(CGFloat, CGFloat)]) { path.move(to: p(pts[0].0, pts[0].1)); pts.dropFirst().forEach { path.addLine(to: p($0.0, $0.1)) } }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { path.addRect(CGRect(origin: p(x, y), size: CGSize(width: w * k, height: h * k))) }
        func circle(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat) { path.addEllipse(in: CGRect(origin: p(x - rad, y - rad), size: CGSize(width: 2 * rad * k, height: 2 * rad * k))) }
        switch name {
        case "figure": circle(20, 9, 4.5); line([(20, 14), (20, 26)]); line([(11, 19), (20, 16), (29, 19)]); line([(14, 35), (20, 26), (26, 35)])
        case "chart.bar": line([(8, 30), (32, 30)]); line([(12, 30), (12, 18)]); line([(20, 30), (20, 12)]); line([(28, 30), (28, 22)])
        case "house": line([(10, 33), (10, 15), (20, 8), (30, 15), (30, 33)]); line([(16, 33), (16, 24), (24, 24), (24, 33)])
        case "doc.text": rect(12, 8, 16, 24); line([(16, 15), (24, 15)]); line([(16, 21), (24, 21)]); line([(16, 27), (21, 27)])
        case "chart.line.uptrend.xyaxis": line([(8, 30), (17, 21), (23, 27), (32, 15)]); line([(26, 15), (32, 15), (32, 21)])
        case "heart":
            path.move(to: p(20, 32)); path.addCurve(to: p(9, 17), control1: p(20, 32), control2: p(9, 25))
            path.addCurve(to: p(20, 14), control1: p(9, 9.5), control2: p(18, 8.5))
            path.addCurve(to: p(31, 17), control1: p(22, 8.5), control2: p(31, 9.5))
            path.addCurve(to: p(20, 32), control1: p(31, 25), control2: p(20, 32)); path.closeSubpath()
        case "briefcase": rect(8, 14, 24, 18); line([(15, 14), (15, 10), (25, 10), (25, 14)])
        case "person.2":
            circle(14, 13, 4); circle(27, 15, 3.5)
            path.move(to: p(6, 32)); path.addCurve(to: p(14, 23), control1: p(7, 26), control2: p(10, 23))
            path.addCurve(to: p(22, 32), control1: p(18, 23), control2: p(21, 26))
            path.move(to: p(22, 32)); path.addCurve(to: p(27, 26), control1: p(23, 28), control2: p(25, 26))
            path.addCurve(to: p(33, 32), control1: p(29, 26), control2: p(32, 28))
        case "line.3.horizontal": line([(8, 12), (32, 12)]); line([(8, 20), (32, 20)]); line([(8, 28), (24, 28)])
        case "magnifyingglass": circle(18, 18, 8); line([(24, 24), (32, 32)])
        default: break
        }
        return path
    }
}

// MARK: controls

/// The rounded buttons of the renders: green filled for the yes, white with a hairline otherwise.
struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    var id: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(small ? 12.5 : 14, primary ? .semibold : .medium))
                .padding(.horizontal, small ? 11 : 16).frame(height: small ? 26 : 34)
                .foregroundStyle(primary ? .white : Ink.text)
                .background(Capsule().fill(primary ? Ink.green : (small ? Ink.chip : Ink.surface)))
                .overlay(Capsule().strokeBorder(primary || small ? .clear : Ink.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .probe(id ?? title, action: action)
    }
}

/// A grey round icon button (search, plus, screen).
struct RoundIcon: View {
    let symbol: String
    let label: String
    var size: CGFloat = 32
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                .frame(width: size, height: size).background(Circle().fill(Ink.chip)).contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .probe(label, action: action)
    }
}

/// A small tinted label (feeds, tags).
struct Chip: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(.ui(12)).padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(warn ? Ink.warn : Ink.greenText)
            .background(Capsule().fill(warn ? Ink.warnSoft : Ink.greenSoft))
    }
}

/// The switch of the renders (38x22, green when on).
struct Toggle38: View {
    @Binding var isOn: Bool
    var label: String
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Ink.green : Color(hex: 0xD6D9D5)).frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
            }
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(isOn ? "on" : "off")
        .probe(label) { isOn.toggle() }
    }
}

/// Progress toward a goal as a ring with the percent inside.
struct Ring: View {
    let percent: Int
    var warn = false
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0xE8EAE7, dark: 0x3A3A3C), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(warn ? Ink.warn : Ink.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%").font(.ui(size < 50 ? 11 : 14, .bold))
        }
        .padding(4) // the renders' radius: size/2 - 4
        .frame(width: size, height: size)
        .accessibilityElement().accessibilityLabel("\(percent) percent")
    }
}

// MARK: surfaces

/// A white card on the canvas: rounded, a soft shadow.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.surface)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 8))
    }
}
extension View {
    func card(radius: CGFloat = 16, padding: CGFloat = 16) -> some View { modifier(CardStyle(radius: radius, padding: padding)) }
}

/// Muse's canvas: a light ground with a fine dot grid, as the renders draw it
/// (`radial-gradient(#dcdedb 1px, transparent 1px)` on 22px tiles: a 2pt dot at each tile's centre).
struct DotCanvas: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var y: CGFloat = 11
            while y < size.height {
                var x: CGFloat = 11
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(Ink.dot))
                    x += step
                }
                y += step
            }
        }
        .background(Ink.canvas)
    }
}

/// The breadcrumb bar above a board: "Life / Wealth" on the left, extras and search on the right.
struct BoardBar<Trailing: View>: View {
    let crumbs: [String]
    var onCrumb: (Int) -> Void = { _ in }
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Text("/").foregroundStyle(Color(hex: 0xB0B4B1)).padding(.horizontal, 6) }
                Button(c) { onCrumb(i) }.buttonStyle(.plain).probe("crumb:\(c)") { onCrumb(i) }
                    .font(.ui(13.5, i == crumbs.count - 1 ? .semibold : .regular))
                    .foregroundStyle(i == crumbs.count - 1 ? Ink.text : Color(hex: 0x6B706C))
            }
            Spacer()
            trailing
            RoundIcon(symbol: "magnifyingglass", label: "Search") { AppModel.shared.searching = true }
        }
        .padding(.horizontal, 20).frame(height: 54)
    }
}
