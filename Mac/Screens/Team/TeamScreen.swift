import SwiftUI

/// The whole team on one screen (the canvas, board 23, "Mac: the whole team"). The rail lists who
/// you can talk to; this says what each one is for, what it is doing right now and when it last
/// needed you, which is the question the rail cannot answer. Reached from the chat header, and
/// "Back to the thread" returns to where you came from.
///
/// State is a dot, never a tick: green is working, amber is waiting on you, grey is quiet. the owner,
/// 2026-11-07: "Grey tick always means you owe it something. An agent still working gets a
/// different mark, so the tick never points both ways." A dot is that different mark.
struct TeamScreen: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [Watch.Job] = []
    @State private var toward: [String: String] = [:]
    @State private var loaded = false

    /// What an agent is doing, in the order the eye should find it.
    enum Doing: Equatable {
        case working(String)
        case asking
        case quiet(String)

        var dot: Color {
            switch self {
            case .working: Ink.green
            case .asking: Ink.warn
            case .quiet: Ink.tertiary
            }
        }
        var words: String {
            switch self {
            case .working(let w): w
            case .asking: "Waiting on your answer"
            case .quiet(let w): w
            }
        }
        var label: String {
            switch self {
            case .working: "working"
            case .asking: "waiting on you"
            case .quiet: "quiet"
            }
        }
        var quiet: Bool { if case .quiet = self { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    columns
                    ForEach(model.team) { t in row(t) }
                    if model.team.isEmpty, loaded { empty }
                }
                // The whole pane, not the reading column: this is a table, and its header and
                // footer span the pane, so a centred column would sit under them out of line. The
                // column rule is for the thread.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .task(id: model.team.map(\.id).joined()) { await load() }
    }

    // MARK: the header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The team").font(.ui(30, .bold)).tracking(-0.5)
                Text(saying).font(.ui(13, .semibold)).foregroundStyle(Ink.greenText)
            }
            Spacer(minLength: 12)
            HeaderChip(title: "Back to the thread", filled: true, id: "back-to-thread") {
                model.go(.chat(AppModel.chiefID))
            }
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 4)
    }

    /// "Ben and seven domain agents", counted rather than asserted.
    private var saying: String {
        let others = max(model.team.count - 1, 0)
        guard others > 0 else { return model.chiefName }
        return "\(model.chiefName) and \(Self.spelled(others)) domain agent\(others == 1 ? "" : "s")"
    }

    /// Small counts read better as words in a sentence; past twelve the numeral is clearer.
    static func spelled(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six",
                     "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return n < words.count ? words[n] : String(n)
    }

    /// "2 working · 1 waiting on you · 5 quiet", leaving out whatever is zero.
    private var tally: String {
        let all = model.team.map { doing(for: $0) }
        let parts = [("working", all.filter { if case .working = $0 { true } else { false } }.count),
                     ("waiting on you", all.filter { $0 == .asking }.count),
                     ("quiet", all.filter(\.quiet).count)]
        return parts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tally).font(.ui(12.5)).foregroundStyle(Ink.tertiary)
                .padding(.top, 10).padding(.bottom, 18)
            HStack(spacing: 14) {
                Color.clear.frame(width: 32, height: 1)
                heading("Who", 150)
                heading("Works toward", nil)
                heading("Doing now", 250)
                heading("Last needed you", 118, trailing: true)
            }
            .padding(.bottom, 9)
        }
    }

    private func heading(_ t: String, _ w: CGFloat?, trailing: Bool = false) -> some View {
        Text(t.uppercased()).font(.ui(11.5, .semibold)).tracking(0.6).foregroundStyle(Ink.greenText)
            .frame(width: w, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: a row

    private func row(_ t: Teammate) -> some View {
        let state = doing(for: t)
        let open = { model.go(.chat(t.id)) }
        return Button(action: open) {
            HStack(spacing: 14) {
                Avatar(look: t.look, size: 32, mood: state == .asking ? .asking : .rest)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.ui(14.5, .semibold)).lineLimit(1)
                    Text(t.id == AppModel.chiefID ? Self.role(t.id) : "Domain agent")
                        .font(.ui(12)).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
                Text(toward[t.id] ?? "")
                    .font(.ui(14)).lineSpacing(4).foregroundStyle(Ink.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Circle().fill(state.dot).frame(width: 6, height: 6)
                        .accessibilityLabel(state.label)
                    Text(state.words).font(.ui(13))
                        .foregroundStyle(state.quiet ? Ink.tertiary : Ink.secondary).lineLimit(2)
                }
                .frame(width: 250, alignment: .leading)
                Text(t.time).font(.ui(12.5)).monospacedDigit().foregroundStyle(Ink.tertiary)
                    .frame(width: 118, alignment: .trailing)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .probe("team-row:\(t.id)", action: open)
    }

    private var empty: some View {
        Text("No teammates yet. The vault's domains become your team.")
            .font(.ui(14)).foregroundStyle(Ink.tertiary).padding(.top, 20)
    }

    // MARK: the footer

    private var footer: some View {
        HStack(spacing: 10) {
            HeaderChip(title: "What an agent may do without asking", filled: true, id: "may-do") {
                model.go(.role(model.team.first { $0.id != AppModel.chiefID }?.id ?? AppModel.chiefID))
            }
            // The one promise that holds whatever any of the ticks above say.
            Text("Money always comes to you, whatever is ticked.")
                .font(.ui(12.5)).foregroundStyle(Ink.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }

    // MARK: what each one is doing

    private func doing(for t: Teammate) -> Doing {
        if t.needsYou { return .asking }
        if let job = Watch.running(jobs, domain: t.id) {
            return .working(job.ask.nonEmpty.map { "\($0.prefix(60))" } ?? Watch.position(job))
        }
        return .quiet("Nothing to do")
    }

    private func load() async {
        toward = model.team.reduce(into: [:]) { out, t in out[t.id] = Self.purpose(t.id) }
        jobs = (try? await Engine.json(["job", "list"], as: [Watch.Job].self)) ?? []
        loaded = true
    }

    /// The role, taken from the front of the same line rather than written again here, so the team
    /// screen and the chat header can never disagree about what the one who runs the team is called.
    static func role(_ slug: String, root: URL = Vault.root) -> String {
        let line = ChatSession.roleLine(slug, root: root)
        return line.components(separatedBy: " · works toward: ").first ?? line
    }

    /// What this one works toward, in its own words from the vault, with the role prefix
    /// `ChatSession.roleLine` puts in front of it taken off: the role has its own column here.
    static func purpose(_ slug: String, root: URL = Vault.root) -> String {
        let line = ChatSession.roleLine(slug, root: root)
        guard let r = line.range(of: " · works toward: ") else { return "" }
        return String(line[r.upperBound...])
    }
}
