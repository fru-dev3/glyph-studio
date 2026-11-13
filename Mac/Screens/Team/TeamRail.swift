import SwiftUI

/// The left rail on every screen: the team (Ben first, then whoever spoke last), what needs you,
/// and the boards. Sizes from design/gen.py `rail()`.
struct TeamRail: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var boards = BoardLines()
    @FocusState private var searchFocused: Bool
    private var state: TeamState { TeamState.shared }

    var body: some View {
        @Bindable var model = model
        let asks = state.asks
        let waitingOn = Set(asks.map(\.domain))
        VStack(alignment: .leading, spacing: 0) {
            // The brand block, and it comes first (the owner, 2026-10-31, twice: "which app is this. I've
            // told you the branding on top left should be consistent"). Before this the row opened
            // with a Spacer and three icons pushed right, so the top left corner named no app at all.
            // No tagline: he rejected it as wrapping and redundant. The gear stays a place in the
            // content pane, never a window ("I don't want pop-up config pages").
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 30, height: 30)
                // The app's own name, so the sidebar can never disagree with the app that is installed.
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Glyph Bot")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Spacer(minLength: 6)
                RoundIcon(symbol: "magnifyingglass", label: "Search teammates") { toggleSearch() }
                if Vault.handWritable { RoundIcon(symbol: "plus", label: "New teammate") { model.go(.newTeammate) } }
                RoundIcon(symbol: "gearshape", label: "Settings") { model.go(.settings) }
            }
            .padding(.horizontal, 14).frame(height: 54)

            if model.searching { searchField } else { tabs(count: asks.count) }

            ScrollView {
                VStack(spacing: 0) {
                    if model.tab == .sources && !model.searching {
                        ForEach(SourceID.allCases) { s in sourceRow(s) }
                        Text("Record").font(.ui(12, .semibold)).foregroundStyle(Ink.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 4)
                        decisionsRow
                    } else {
                        let rows = teammates(waitingOn: waitingOn, anyWaiting: !asks.isEmpty)
                        ForEach(rows) { t in row(t, unread: t.id == AppModel.chiefID ? !asks.isEmpty : waitingOn.contains(t.id)) }
                        if rows.isEmpty { empty }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
        }
        .background(Ink.surface)
        .task(id: "\(model.team.map(\.id))\(model.tab)") { boards = BoardLines.read() }
        .onChange(of: model.searching) { if model.searching { searchFocused = true } else { query = "" } }
    }

    // MARK: header

    private func tabs(count: Int) -> some View {
        HStack(spacing: 6) {
            tab(.all, "All")
            tab(.needsYou, count > 0 ? "Needs you \(count)" : "Needs you")
            tab(.sources, "Sources")
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }

    private func tab(_ t: AppModel.RailTab, _ title: String) -> some View {
        let on = model.tab == t
        let go = {
            model.tab = t
            if t == .needsYou { model.go(.needsYou) }
            if t == .sources, !Self.isSourcePlace(model.route) { model.go(.sources(nil)) }
        }
        return Button(action: go) {
            Text(title).font(.ui(13, on ? .semibold : .medium)).foregroundStyle(on ? Ink.onInk : Ink.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(on ? Ink.text : Ink.chip)).contentShape(Capsule())
        }
        .buttonStyle(.plain).probe("tab:\(t.rawValue)", action: go)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.tertiary)
            TextField("", text: $query, prompt: Text("Search teammates").foregroundStyle(Color(hex: 0x9A9F9B)))
                .studioDictatable($query)
                .textFieldStyle(.plain).font(.ui(13.5)).focused($searchFocused)
                .onExitCommand { toggleSearch() }
                .probeField("rail-search", text: $query)
            Button { toggleSearch() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(hex: 0xB0B4B1))
            }
            .buttonStyle(.plain).help("Close search").probe("close-search") { toggleSearch() }
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Ink.chip))
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }

    private func toggleSearch() { model.searching.toggle() }

    // MARK: rows

    /// All: the whole team. Needs you: Ben (who holds every ask) and whoever is waiting.
    /// Searching filters by name or last line.
    private func teammates(waitingOn: Set<String>, anyWaiting: Bool) -> [Teammate] {
        var list = model.team
        if model.searching, let q = query.nonEmpty?.lowercased() {
            return list.filter { $0.name.lowercased().contains(q) || lastLine($0).lowercased().contains(q) }
        }
        if model.tab == .needsYou { list = list.filter { $0.id == AppModel.chiefID ? anyWaiting : waitingOn.contains($0.id) } }
        return list
    }

    /// What the teammate said last (its own words, not the engine's task title).
    private func lastLine(_ t: Teammate) -> String {
        t.needsYou ? (TeamActivity.latest(for: t.id).0.nonEmpty ?? t.last) : t.last
    }

    private var selected: String? {
        switch model.route {
        case .chat(let id), .role(let id), .watch(let id): return id
        case .needsYou: return state.asks.first?.domain
        // The team screen is Ben's own place, reached from his header, so his row stays lit.
        case .weekly, .newTeammate, .settings, .team: return AppModel.chiefID
        case .sources(let s): return "source:\(s ?? "vault")"
        case .decisions: return "decisions"
        }
    }

    static func isSourcePlace(_ r: AppModel.Route) -> Bool {
        if case .sources = r { return true }
        return r == .decisions
    }

    private func row(_ t: Teammate, unread: Bool) -> some View {
        let open = { model.go(.chat(t.id)) }
        return Button(action: open) {
            HStack(spacing: 12) {
                Avatar(look: t.look, size: 42, mood: unread ? .asking : .rest)
                // Name and one fact (when it last spoke); the sentence lives in the chat (the owner: "too wordy").
                HStack(alignment: .firstTextBaseline) {
                    Text(t.name).font(.ui(14.5, .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(t.time).font(.ui(12)).monospacedDigit().foregroundStyle(Ink.tertiary)
                }
                Circle().fill(unread ? Ink.green : .clear).frame(width: 9, height: 9)
                    .accessibilityLabel(unread ? "Waiting on you" : "")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected == t.id ? Ink.chip : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .probe("row:\(t.id)", action: open)
    }

    private func sourceRow(_ src: SourceID) -> some View {
        let st = boards.sources[src]
        let open = { model.go(.sources(src.rawValue)) }
        let live = st?.state == .connected
        return placeRow(id: "source:\(src.rawValue)", title: src.title,
                        line: st.map { $0.state == .connected ? $0.detail : "\(SourcesScreen.word($0.state)) · \($0.detail)" } ?? "", action: open) {
            Image(systemName: src.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(live ? Ink.greenText : Ink.secondary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(live ? Ink.greenSoft : Ink.chip))
        }
    }

    private var decisionsRow: some View {
        placeRow(id: "decisions", title: "Decisions", line: boards.decisions, action: { model.go(.decisions) }) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.chip))
        }
    }

    private func placeRow<Icon: View>(id: String, title: String, line: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: -1) {
                    Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Ink.text)
                    Text(line).font(.ui(13)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected == id ? Ink.chip : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .probe("board:\(id)", action: action)
    }

    private var empty: some View {
        Text(model.searching ? "No teammate matches \u{201C}\(query)\u{201D}."
             : model.problem != nil ? "No vault, so no team. Glyph Bot shows nothing it cannot read."
             : model.tab == .needsYou ? "Nobody is waiting on you."
             : model.loaded ? "No teammates yet." : "")
            .font(.ui(12.5)).foregroundStyle(Ink.tertiary).padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The Sources tab's one-line summaries: each source's status, and the open decisions.
struct BoardLines: Equatable {
    var sources: [SourceID: SourceStatus] = [:]
    var decisions = ""

    static func read(root: URL = Vault.root, today: Date = AppClock.now) -> BoardLines {
        var out = BoardLines()
        for s in SourceID.allCases { out.sources[s] = Sources.status(s, root: root, now: today) }
        let fm = FileManager.default
        var open: [String] = []
        for slug in Sources.domainSlugs(root) {
            let dir = root.appending(path: "data/domains/\(slug)/memory/decisions")
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".md") {
                let m = Frontmatter.read(dir.appending(path: f))
                if (m["status"] ?? "open") == "open" { open.append(m["due"] ?? "") }
            }
        }
        let nearest = open.filter { !$0.isEmpty }.min()
        out.decisions = open.isEmpty ? "None open" : "\(open.count) open" + (nearest.map { ", nearest \(short($0))" } ?? "")
        return out
    }

    /// "2026-11-06" -> "Nov 6".
    static func short(_ ymd: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: ymd) else { return ymd }
        f.dateFormat = "MMM d"; return f.string(from: d)
    }
}
