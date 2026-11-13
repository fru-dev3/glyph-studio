import SwiftUI

/// The window: the team rail, then whatever place is open.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { g in
            // The rail is a list of names, so it is fixed: it never grows with the window, because a
            // wider window should give its width to what you are reading, not to the index.
            // 329, and fixed: it no longer grows to 379 on a wide screen, because an index should
            // not take width from what you are reading. It does not shrink either. The header has
            // 210 points of fixed chrome (the app icon, five gaps, three round controls, the
            // spacer), so 329 leaves 119 for the name. At 312 that fell to 102 against a title
            // needing about 100: it still "fitted", but SwiftUI tightened the glyphs until they
            // touched, and the brand test read "Giyph Studio" off the render.
            let rail: CGFloat = 329
            let place = g.size.width - rail - 1
            HStack(spacing: 0) {
            TeamRail()
                .frame(width: rail)
            Rectangle().fill(Ink.line).frame(width: 1)
            ZStack {
                Ink.surface
                self.place.id(model.route) // a fresh screen per place, so nothing from the last one lingers
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.column, min(820, place - 56))
            }
        }
        .background(Ink.surface)
        .ignoresSafeArea()
        .foregroundStyle(Ink.text)
        .overlay(alignment: .top) {
            if let p = model.problem {
                Text(p).font(.ui(13)).padding(10).background(Ink.warnSoft, in: Capsule()).foregroundStyle(Ink.warn).padding(.top, 12)
                    .accessibilityIdentifier("problem")
            }
        }
    }

    @ViewBuilder private var place: some View {
        switch model.route {
        case .chat(let id): ChatScreen(teammateID: id)
        case .team: TeamScreen()
        case .needsYou: NeedsYouScreen()
        case .weekly: WeeklyNoteScreen()
        case .sources(let s): SourcesScreen(open: s)
        case .newTeammate: NewTeammateScreen()
        case .role(let d): TeammateRoleScreen(domain: d)
        case .watch(let d): WatchWorkScreen(domain: d)
        case .decisions: DecisionsScreen()
        case .settings: SettingsScreen()
        }
    }
}
