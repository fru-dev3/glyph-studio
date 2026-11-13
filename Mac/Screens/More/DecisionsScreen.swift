import SwiftUI

/// Open decisions, nearest first (`decide list`), each with your gut and the recommendation. The
/// recommendation stays hidden until you log your gut (the engine's rule, so the gut is honest).
/// Log your gut (`decide gut`), Decide from the options (`decide decide`), Ask the council
/// (`decide recommend`). Below, decisions made in the last 90 days, to look back on.
struct DecisionsScreen: View {
    @State private var records: [DecisionRecord] = []
    @State private var loaded = false
    @State private var problem: String?

    private var open: [DecisionRecord] {
        records.filter(\.isOpen).sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }
    }
    private var lookingBack: [DecisionRecord] {
        let since = MoreDate.day(Calendar.current.date(byAdding: .day, value: -90, to: AppClock.today) ?? AppClock.today)
        let today = MoreDate.day(AppClock.today)
        return records.filter { !$0.isOpen && (($0.decided ?? "") >= since || ($0.retroDue.map { $0 <= today } ?? false)) }
            .sorted { ($0.decided ?? "") > ($1.decided ?? "") }
    }

    var body: some View {
        MoreBoard(title: "Decisions") {
            if loaded { MoreBarNote(text: open.isEmpty ? "Nothing open" : "\(open.count) open · nearest first") }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(320), spacing: 22, alignment: .top), count: 3), alignment: .leading, spacing: 22) {
                        ForEach(open) { r in DecisionCard(record: r, reload: load) }
                    }
                    .padding(.leading, 30)
                    .frame(minHeight: lookingBack.isEmpty ? 0 : 400, alignment: .top)
                    if loaded && open.isEmpty {
                        Text("No open decisions. When a teammate needs your call, it lands here with a date.").font(.ui(14)).foregroundStyle(Ink.tertiary).padding(.leading, 40)
                    }
                    if let problem { Text(problem).font(.ui(13)).foregroundStyle(Ink.warn).padding(.leading, 40).padding(.top, 12) }
                    if !lookingBack.isEmpty {
                        SectionLabel(text: "Looking back · 90 days").padding(.leading, 40)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(320), spacing: 22, alignment: .top), count: 3), alignment: .leading, spacing: 22) {
                            ForEach(lookingBack) { r in DecisionCard(record: r, reload: load) }
                        }
                        .padding(.leading, 40).padding(.top, 11)
                    }
                }
                .padding(.top, 30).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            records = try await Engine.json(["decide", "list", "--all"], as: [DecisionRecord].self)
            problem = nil
        } catch { problem = error.localizedDescription }
        loaded = true
    }
}

/// One decision on the board.
struct DecisionCard: View {
    let record: DecisionRecord
    let reload: () async -> Void
    @State private var mode: Mode = .idle
    @State private var gut = ""
    @State private var other = ""
    @State private var problem: String?
    @State private var asking = false

    enum Mode { case idle, gut, decide }

    /// Recommendations the council returned this session, by decision id.
    @MainActor static var council: [String: DecisionRecord] = [:]

    private var r: DecisionRecord {
        guard record.recommendation == nil, let c = Self.council[record.id], record.gut != nil else { return record }
        var m = record; m.recommendation = c.recommendation; m.confidence = c.confidence; return m
    }
    private var waitingRecommendation: Bool { record.gut == nil && (record.recommendationReady == true || Self.council[record.id] != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    DomainMark(domain: r.domain)
                    Text(Teammate.label(r.domain).uppercased()).font(.ui(12, .semibold)).foregroundStyle(Teammate.color(r.domain))
                }
                Spacer()
                Text(r.isOpen ? (r.due.map { "Due \(MoreDate.short($0))" } ?? "No date") : "Decided \(MoreDate.short(r.decided))")
                    .font(.ui(12)).foregroundStyle(Ink.tertiary)
            }
            Text(Greedy.wrap(r.question, font: .ui(17, .semibold), width: 284)).font(.ui(17, .semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if let g = r.gut { field("Your gut", g) }
            else if !r.isOpen, let chose = r.chose { field("You chose", chose) }
            else if r.isOpen && mode != .gut {
                Button { mode = .gut } label: { Text("Log your gut first").font(.ui(13)).foregroundStyle(Ink.green) }
                    .buttonStyle(.plain).padding(.top, 10).probe("gut:\(r.slug)") { mode = .gut }
            }
            if mode == .gut {
                MoreLabel(text: "Your gut, in a line").padding(.top, 10)
                MoreField(prompt: "What would you do if you had to say now?", text: $gut, id: "gutfield:\(r.slug)") { Task { await logGut() } }.padding(.top, 6)
            }
            if let rec = r.recommendation { field("Recommendation", rec) }
            else if waitingRecommendation { Text(Greedy.wrap("A recommendation is ready. Log your gut to see it.", font: .ui(12.5), width: 284)).font(.ui(12.5)).foregroundStyle(Ink.tertiary).padding(.top, 10) }
            if asking { Text("Asking the council…").font(.ui(12.5)).foregroundStyle(Ink.tertiary).padding(.top, 10) }
            if mode == .decide { options }
            if let problem { Text(problem).font(.ui(12.5)).foregroundStyle(Ink.warn).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
            if r.isOpen && mode == .idle {
                HStack(spacing: 8) {
                    PillButton(title: "Decide", primary: true, id: "decide:\(r.slug)") { mode = .decide }
                    PillButton(title: "Ask the council", id: "council:\(r.slug)") { Task { await askCouncil() } }
                }
                .fixedSize()
                .padding(.top, 14)
            }
        }
        .frame(width: 284, alignment: .leading)
        .card(padding: 18)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.ui(12)).foregroundStyle(Ink.tertiary)
            Text(Greedy.wrap(value, font: .ui(14), width: 284)).font(.ui(14)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    @ViewBuilder private var options: some View {
        MoreLabel(text: "Your call").padding(.top, 12)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(r.options, id: \.self) { o in
                Button { Task { await decide(o) } } label: {
                    Text(o).font(.ui(13.5)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).probe("option:\(o)") { Task { await decide(o) } }
            }
            MoreField(prompt: r.options.isEmpty ? "What did you decide?" : "Something else", text: $other, id: "other:\(r.slug)") { Task { await decide(other) } }
            MoreTextButton(title: "Cancel", id: "cancel:\(r.slug)") { mode = .idle }.padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func logGut() async {
        let g = gut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        do { _ = try await Engine.json(["decide", "gut", r.id, g], as: DecisionRecord.self); mode = .idle; problem = nil; await reload() }
        catch { problem = error.localizedDescription }
    }

    private func decide(_ choice: String) async {
        let c = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        do { _ = try await Engine.json(["decide", "decide", r.id, c], as: DecisionRecord.self); mode = .idle; problem = nil; await reload() }
        catch { problem = error.localizedDescription }
    }

    private func askCouncil() async {
        asking = true; defer { asking = false }
        do {
            let a = try await Engine.json(["decide", "recommend", r.id], as: CouncilAnswer.self)
            Self.council[r.id] = a.record
            problem = nil
            await reload()
        } catch { problem = error.localizedDescription }
    }
}
