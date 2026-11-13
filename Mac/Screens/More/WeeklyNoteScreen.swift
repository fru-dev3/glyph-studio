import SwiftUI

/// The chief of staff's weekly note (was Insights and For You), as a conversation: the note from the
/// vault's newest review, the rule you keep restating (from `recommendations`, category rules) with
/// "Make it a standing rule", the trade-offs your history suggests with Yes and No, and a composer.
struct WeeklyNoteScreen: View {
    @Environment(AppModel.self) private var model
    @State private var review: WeeklyReview?
    @State private var rule: RuleRecs.Item?
    @State private var ruleState: String?      // what happened to the rule ("saved", "later")
    @State private var problem: String?
    @State private var thread: [Turn] = []
    @State private var draft = ""
    @State private var loaded = false

    struct Turn: Identifiable { let id = UUID(); var mine: Bool; var text: String; var failed = false }

    var body: some View {
        VStack(spacing: 0) {
            MoreChatHeader(teammate: AppModel.chiefID, title: model.chiefName, subtitle: "Chief of staff · weekly note")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        messages
                        ForEach(thread) { t in
                            if t.mine { MoreMine(text: t.text) } else { MoreBubble(from: model.chiefName, text: t.text, muted: t.failed) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .column()
                    .padding(.top, 24).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .onChange(of: thread.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            MoreComposer(who: model.chiefName, text: $draft, id: "weekly:composer") { send() }
        }
        .task { await load() }
    }

    @ViewBuilder private var messages: some View {
        if let review {
            MoreBubble(from: "\(model.chiefName) · \(weekday(review.date)) weekly note", text: review.note)
        } else if loaded {
            MoreBubble(from: model.chiefName, text: "No weekly note yet. I write one every Sunday from what happened across your teammates.", muted: true)
        }
        if let rule { ruleMessage(rule) }
        proposalsMessage
        if let problem { Text(problem).font(.ui(13)).foregroundStyle(Ink.warn).padding(.leading, 6) }
    }

    // MARK: the repeated rule

    private func ruleMessage(_ r: RuleRecs.Item) -> some View {
        let n = r.times.map { "in \($0) separate sessions" } ?? "again and again"
        let text = "One thing I noticed: you have told your agents the same rule \(n): \(lowerFirst(r.rule))"
        return MoreBubble(from: model.chiefName, text: text) {
            Group {
                switch ruleState {
                case "saved": done("A standing rule now. Every teammate follows it without being told.")
                case "later": done("I'll bring it up again next week.")
                default:
                    HStack(spacing: 8) {
                        PillButton(title: "Make it a standing rule", primary: true) { Task { await adopt(r) } }
                        PillButton(title: "Not now") { Task { await later(r) } }
                    }
                    .fixedSize()
                }
            }
            .padding(.top, 12)
        }
    }

    private func adopt(_ r: RuleRecs.Item) async {
        var args = ["intent", "verdict", r.action?.finding ?? "repeated_rules", "true"]
        if let item = r.action?.item { args += ["--item", item] }
        args += ["--rule", r.rule]
        do { _ = try await Engine.json(args, as: Verdict.self); ruleState = "saved"; problem = nil } catch { problem = error.localizedDescription }
    }

    private func later(_ r: RuleRecs.Item) async {
        var args = ["intent", "verdict", r.action?.finding ?? "repeated_rules", "later"]
        if let item = r.action?.item { args += ["--item", item] }
        do { _ = try await Engine.json(args, as: Verdict.self); ruleState = "later"; problem = nil } catch { problem = error.localizedDescription }
    }

    private struct Verdict: Decodable { var ok: Bool? }

    // MARK: proposed trade-offs

    @ViewBuilder private var proposalsMessage: some View {
        let groups = Dictionary(grouping: review?.proposals ?? [], by: \.domain)
        ForEach(groups.keys.sorted(), id: \.self) { domain in
            let ps = groups[domain] ?? []
            let open = ps.filter { $0.status == "proposed" }
            let text = ps.count == 1
                ? "A trade-off your history suggests for \(domain). Is this yours?"
                : "\(Spoken.count(ps.count)) trade-offs your history suggests for \(domain). Are these yours?"
            MoreBubble(from: model.chiefName, text: open.isEmpty ? "The trade-offs I suggested for \(domain):" : text) {
                VStack(spacing: 8) { ForEach(ps) { row($0) } }.padding(.top, 10)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func row(_ p: WeeklyReview.Proposal) -> some View {
        HStack(spacing: 0) {
            Text(p.text).font(.ui(14)).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12)
            switch p.status {
            case "accepted": Text("Added to \(p.domain)").font(.ui(12.5)).foregroundStyle(Ink.greenText).frame(height: 34)
            case "dismissed": Text("Not yours").font(.ui(12.5)).foregroundStyle(Ink.tertiary).frame(height: 34)
            default:
                PillButton(title: "Yes", primary: true, id: "yes:\(p.text)") { answer(p, yes: true) }.fixedSize().padding(.trailing, 8)
                PillButton(title: "No", id: "no:\(p.text)") { answer(p, yes: false) }.fixedSize().padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11) // CSS padding 10 12 plus its 1 px border, drawn inside here
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xECEEEB)))
    }

    private func answer(_ p: WeeklyReview.Proposal, yes: Bool) {
        guard let url = review?.url else { return }
        do {
            try WeeklyReview.answer(p, yes: yes, review: url)
            review = WeeklyReview.newest()
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    // MARK: talking to the chief of staff

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        thread.append(Turn(mine: true, text: text))
        thread.append(Turn(mine: false, text: "…"))
        let i = thread.count - 1
        Task {
            do {
                try await MoreChat.send(text, to: AppModel.chiefID) { reply in thread[i].text = reply }
            } catch {
                thread[i].text = "I couldn't answer just now: \(error.localizedDescription)"
                thread[i].failed = true
            }
        }
    }

    // MARK: loading

    private func load() async {
        review = WeeklyReview.newest()
        do {
            let recs = try await Engine.json(["recommendations"], as: RuleRecs.self)
            rule = recs.recommendations.first { $0.category == "rules" }
            problem = nil
        } catch { problem = error.localizedDescription }
        loaded = true
    }

    private func weekday(_ d: Date?) -> String { d.map { MoreDate.format($0, "EEEE") } ?? "This week's" }
    private func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
    private func done(_ s: String) -> some View { Text(s).font(.ui(13)).foregroundStyle(Ink.greenText) }
}
