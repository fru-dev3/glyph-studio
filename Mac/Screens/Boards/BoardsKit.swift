import AppKit
import SwiftUI

// Pieces the three boards share, sized from design/gen.py (goal_card, board_card, ring).

/// The card shadows of the renders, CSS box-shadows with a negative spread (a soft shadow that shows
/// only below the card): `0 1px 2px rgba(0,0,0,.06), 0 Ypx Bpx -Spx rgba(0,0,0,A)`.
struct BoardShadow: ViewModifier {
    var radius: CGFloat
    // alpha is fitted, not the CSS one: SwiftUI's shadow at radius blur/2 matches the falloff of the
    // renders' box-shadow but draws lighter (profiles measured below each card, 2026-10-26).
    var y: CGFloat = 8, blur: CGFloat = 24, spread: CGFloat = 14, alpha: Double = 0.33
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                // CSS's negative spread: the shadow of a smaller shape, hidden under the card. A shadow,
                // not a blur, so window snapshots (cacheDisplay) draw it too.
                shape.fill(.black).padding(spread).shadow(color: .black.opacity(alpha), radius: blur / 2, y: y)
                shape.fill(Ink.surface).shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
        }
    }
}

extension View {
    /// Goal cards (`0 8px 24px -14px .25`), the opened goal (`0 18px 50px -24px .35`).
    func boardSurface(_ radius: CGFloat = 16, big: Bool = false) -> some View {
        modifier(big ? BoardShadow(radius: radius, y: 18, blur: 50, spread: 24, alpha: 0.4) : BoardShadow(radius: radius))
    }
    /// Board cards: `0 10px 28px -16px .3`.
    func tileSurface(_ radius: CGFloat = 14) -> some View { modifier(BoardShadow(radius: radius, y: 10, blur: 28, spread: 16, alpha: 0.28)) }
    /// Places a view on the canvas at the render's left/top.
    func at(_ x: CGFloat, _ y: CGFloat) -> some View { offset(x: x, y: y) }
}

/// A goal on a board: ring, domain, title, the why in the owner's words, its status line and,
/// when its teammate is moving it, a live "working" mark.
struct GoalCard: View {
    let domain: String
    let outcome: Outcome
    let status: String
    let warn: Bool
    let working: Bool
    var width: CGFloat = 238
    let open: () -> Void

    var body: some View {
        let look = Teammate.look(for: domain)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    BoardRing(percent: outcome.progress ?? 0, warn: warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domainLabel.uppercased()).font(.ui(11.5, .semibold)).tracking(0.25).foregroundStyle(Ink.greenText)
                        Greedy(text: outcome.title, font: .ui(16, .semibold), width: width - 90).lineLimit(3).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let why = outcome.why {
                    Greedy(text: "\"\(why)\"", font: .board(13.5), width: width - 32).lineLimit(2).help(why).foregroundStyle(Color(hex: 0x4A4F4B)).lineSpacing(3.6)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10.8)
                }
                HStack(alignment: .center, spacing: 0) {
                    Greedy(text: status, font: .ui(12), width: width - 32 - (working ? 83 : 0)).foregroundStyle(warn ? Ink.warn : Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if working {
                        HStack(spacing: 6) {
                            // At 20pt every teammate shape rounds off to a circle, as in the renders.
                            Avatar(look: Look(shape: .circle, color: look.color, glyph: look.glyph), size: 20)
                            Text("working").font(.ui(12)).foregroundStyle(Ink.secondary)
                            Circle().fill(Ink.green).frame(width: 6, height: 6)
                        }
                        .fixedSize()
                    }
                }
                .padding(.top, 13.8)
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            .boardSurface(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.text)
        .probe("goal:\(outcome.id)", action: open)
    }

    private var domainLabel: String { IntentStore().contract(domain).title }
}

/// A board card: a white tile with a title, and an optional label above it on the canvas.
struct BoardCard<Content: View>: View {
    let title: String
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.ui(15, .semibold)).padding(.horizontal, 16).padding(.top, 13)
            content
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .tileSurface()
    }
}

/// The label above a board group ("Your contract", "Pages agents wrote").
struct CanvasLabel: View {
    let text: String
    var body: some View { Text(text).font(.ui(12.5, .semibold)).foregroundStyle(Color(hex: 0x3F4440)) }
}

/// Grey placeholder bars, a thumbnail of text.
struct MiniLines: View {
    var widths: [Double]
    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xECEEEB)).frame(width: min(g.size.width - 32, g.size.width * w), height: 7) // CSS width: N% of the whole card
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}

/// Lays chips left to right and wraps, as the renders' flex-wrap rows do.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [], row = Row()
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + s.width > maxWidth {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + s.width
            row.height = max(row.height, s.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Text that becomes a field on click; return saves, escape cancels. `id` names it for tests:
/// press "edit:<id>", type and submit "<id>".
struct InlineEdit<Label: View>: View {
    let id: String
    let value: String
    var font: Font = .ui(14)
    var placeholder = ""
    let save: (String) -> Void
    @ViewBuilder var label: Label

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft, axis: .vertical)
                .studioDictatable($draft)
                .textFieldStyle(.plain).font(font).focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, f in if !f && editing { commit() } }
                .onAppear { focused = true }
                .probeField(id, text: $draft, submit: commit)
        } else {
            label
                .contentShape(Rectangle())
                .onTapGesture(perform: begin)
                .help("Click to edit")
                .probe("edit:\(id)", action: begin)
        }
    }

    private func begin() { draft = value; editing = true }

    private func commit() {
        guard editing else { return }
        editing = false
        let t = GoalsDoc.clean(draft)
        if t != GoalsDoc.clean(value) { save(t) }
    }
}

/// A one-line "add" field at the foot of a card.
struct AddLine: View {
    let id: String
    let prompt: String
    var shown = true
    let add: (String) -> Void
    @State private var text = ""
    @State private var open = false

    var body: some View {
        if open {
            TextField(prompt, text: $text)
                .studioDictatable($text)
                .textFieldStyle(.plain).font(.ui(13.5))
                .onSubmit(commit).onExitCommand { open = false; text = "" }
                .probeField(id, text: $text, submit: commit)
        } else {
            Button { open = true } label: {
                Text("+ Add").font(.ui(12)).foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain).opacity(shown ? 1 : 0).probe("add:\(id)") { open = true }
        }
    }

    private func commit() {
        let t = GoalsDoc.clean(text)
        open = false; text = ""
        if !t.isEmpty { add(t) }
    }
}

/// A board-level error line (a write the vault refused).
struct BoardProblem: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(12.5)).foregroundStyle(Ink.warn).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Ink.warnSoft))
    }
}

/// The renders' canvas: `radial-gradient(#dcdedb 1px, transparent 1px)` on a 22px grid, so each dot
/// sits at the centre of its tile (DotCanvas draws them at the corners, faint).
struct BoardCanvas: View {
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

extension Font {
    /// The owner's own words. The system sans, like everything else: he rejected the serif the early
    /// renders set these in ("it's like tech slop"), so the family has one face, body and headings
    /// alike. Bold is the renders' weight 600.
    static func board(_ size: CGFloat, bold: Bool = false) -> Font { .system(size: size, weight: bold ? .semibold : .regular) }
}

/// Text broken into lines greedily, the way the renders' browser breaks them. SwiftUI's Text keeps
/// a lone last word off its own line (it moves one more down), which the designs don't do.
struct Greedy: View {
    let text: String
    let font: NSFont
    let width: CGFloat
    var body: some View { Text(Greedy.wrap(text, font: font, width: width)).font(Font(font)) }

    static func wrap(_ text: String, font: NSFont, width: CGFloat) -> String {
        let w = { (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ").map(String.init) {
            let next = line.isEmpty ? word : line + " " + word
            if !line.isEmpty, w(next) > width { lines.append(line); line = word } else { line = next }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

extension NSFont {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func board(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// gen.py's ring: radius size/2 - 4, a 5pt track and arc, the percent in the middle. (Theme's Ring
/// draws its circle 1.5pt wider; see the report.)
struct BoardRing: View {
    let percent: Int
    var warn = false
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0xE8EAE7), lineWidth: 5).padding(4)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(warn ? Ink.warn : Ink.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(4)
            Text("\(percent)%").font(.ui(size < 50 ? 11 : 14, .bold))
        }
        .frame(width: size, height: size)
        .accessibilityElement().accessibilityLabel("\(percent) percent")
    }
}
