import SwiftUI
#if os(iOS)

/// The family's sidebar: the panel that slides in from the left edge, with the app's block at the
/// top, the ways in as tiled rows, the rest in quiet groups under their headings, and whatever the
/// app wants to say at the foot.
///
/// Fru, 2026-11-10, opening Glyph Omega: "Omega is missing the sidebar." It was the fifth drawer
/// in the family and the first that did not exist: Glyph Jot, Glyph Well, Glyph CRM and Glyph
/// Wealth each drew their own. This is Glyph Wealth's, which is the one he last approved, with its
/// colours taken from the system so an app that follows the phone into light mode is not handed a
/// black panel. The four that came first should come here too; until they do, this is the one any
/// new app uses, and the shape they are measured against.
///
/// An app passes its places and their names. It does not pass a width, a row height, a corner
/// radius or a padding: those are the drawer, not the content.
///
/// Accessibility identifiers: `drawer` (the panel), `drawer.<id>` (a row), `drawer.scrim`.
public struct GlyphDrawer: View {
    /// One place in the drawer. `figure` is a number or a word at the trailing edge, for a row
    /// that has one worth showing.
    public struct Row: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let symbol: String
        public let figure: String?
        public init(id: String, name: String, symbol: String, figure: String? = nil) {
            self.id = id; self.name = name; self.symbol = symbol; self.figure = figure
        }
    }

    /// A group of places. A section with no title holds the ways in and is drawn as tiles; a
    /// titled one is a quiet list under its heading.
    public struct Section: Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let rows: [Row]
        /// The ways in, at the top, drawn as tiles.
        public init(_ rows: [Row]) { self.id = "ways-in"; self.title = nil; self.rows = rows }
        /// A group under its heading.
        public init(_ title: String, _ rows: [Row]) { self.id = title; self.title = title; self.rows = rows }
    }

    let name: String
    let mark: String
    let tint: Color
    let sections: [Section]
    /// The place the app is on, so the drawer can say where you are.
    let here: String
    /// A line at the foot: the version, whether the hub was reached, whatever the app keeps there.
    let foot: AnyView?
    let choose: (String) -> Void

    public init(name: String, mark: String, tint: Color, sections: [Section], here: String,
                foot: AnyView? = nil, choose: @escaping (String) -> Void) {
        self.name = name; self.mark = mark; self.tint = tint; self.sections = sections
        self.here = here; self.foot = foot; self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: mark).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(name).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            if let ways = sections.first(where: { $0.title == nil }) {
                VStack(spacing: 4) { ForEach(ways.rows) { tile($0) } }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections.filter { $0.title != nil }) { s in
                        VStack(alignment: .leading, spacing: 9) {
                            Text((s.title ?? "").uppercased())
                                .font(.system(size: 11.5, weight: .semibold)).tracking(0.5)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                            VStack(spacing: 2) { ForEach(s.rows) { quiet($0) } }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if let foot {
                VStack(alignment: .leading, spacing: 2) {
                    Divider()
                    foot.padding(.horizontal, 8).padding(.vertical, 7)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 58)
        .padding(.bottom, 20)
        .frame(width: 296)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
        .ignoresSafeArea()
        // Named, with its rows still their own elements. An identifier on a container alone left
        // a check able to see the panel and none of the places in it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer")
    }

    /// A way in: the 54pt row with the filled tile, as Glyph Wealth draws Chat, Today and Jot.
    /// Without `contentShape` the hit area is the glyphs themselves and not the row, so a row that
    /// looked 54 tall was 17.
    func tile(_ r: Row) -> some View {
        let on = r.id == here
        return Button { choose(r.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: r.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 30, height: 30)
                    .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: 9, style: .continuous))
                Text(r.name).font(.system(size: 17, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
                if let f = r.figure { Text(f).font(.system(size: 13)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 12)
            .frame(height: 54)
            .background(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 13, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawer.\(r.id)")
    }

    /// Everything else: a quieter row, the same tap, no tile.
    func quiet(_ r: Row) -> some View {
        let on = r.id == here
        return Button { choose(r.id) } label: {
            HStack(spacing: 11) {
                Image(systemName: r.symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary).frame(width: 22)
                Text(r.name).font(.system(size: 15, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
                if let f = r.figure { Text(f).font(.system(size: 13)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawer.\(r.id)")
    }
}

/// How a screen asks for the drawer. The shell owns whether it is open; a screen only asks, so a
/// screen never has to be handed a binding it has no business holding.
public struct GlyphDrawerOpenKey: EnvironmentKey {
    // The default is nil, which has nothing to share; the closure an app puts here is made and read
    // on the main actor, as every SwiftUI view body is.
    nonisolated(unsafe) public static let defaultValue: (() -> Void)? = nil
}

public extension EnvironmentValues {
    var glyphDrawerOpen: (() -> Void)? {
        get { self[GlyphDrawerOpenKey.self] }
        set { self[GlyphDrawerOpenKey.self] = newValue }
    }
}

/// The corner control that opens the drawer, drawn only where there is one to open.
public struct GlyphDrawerButton: View {
    @Environment(\.glyphDrawerOpen) private var open
    public init() {}
    public var body: some View {
        if let open {
            GlyphDisc("line.3.horizontal", label: "Open the drawer", id: "chrome.drawer", action: open)
        }
    }
}

public extension View {
    /// The drawer over this screen: the scrim, the slide, the swipe from the left edge to open and
    /// the tap or swipe back to close. The gesture lives on a narrow strip of its own, never on
    /// the whole screen: a drag gesture on the container competes with every button inside it for
    /// the same touch, and a tap that loses that race simply does nothing.
    func glyphDrawer(open: Binding<Bool>, @ViewBuilder drawer: () -> GlyphDrawer) -> some View {
        let panel = drawer()
        return ZStack(alignment: .leading) {
            self
            if !open.wrappedValue {
                Color.clear.frame(width: 24).frame(maxHeight: .infinity).contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                        if g.translation.width > 50 { open.wrappedValue = true }
                    })
            }
            if open.wrappedValue {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { open.wrappedValue = false }
                    .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                        if g.translation.width < -50 { open.wrappedValue = false }
                    })
                    .accessibilityLabel("Close the drawer")
                    .accessibilityIdentifier("drawer.scrim")
                panel.transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.22), value: open.wrappedValue)
    }
}
#endif
