import SwiftUI
import GlyphCapture

/// A teammate's conversation: its thread from the vault, what it is waiting on, and a composer that
/// runs `prevail chat --domain <id> --json` and streams the reply in. With Ben and an empty thread,
/// the opening ask ("What needs me tonight?") answers from what is waiting and today.
struct ChatScreen: View {
    let teammateID: String
    @Environment(AppModel.self) private var model
    @State private var chat = ChatSession()
    @State private var draft = ""
    @State private var bringIn: [String] = []
    /// Sources turned on or off by hand in this chat; the rest follow the words typed.
    @State private var picked: [SourceID: Bool] = [:]
    @State private var available: Set<SourceID> = []
    @State private var cheer = false
    @State private var files: [Pending] = []
    private var state: TeamState { TeamState.shared }

    private var lit: Set<SourceID> {
        var s = Sources.relevant(draft, agent: teammateID)
        for (k, v) in picked { if v { s.insert(k) } else { s.remove(k) } }
        return s.intersection(available)
    }

    private var mate: Teammate? { model.teammate(teammateID) }
    private var name: String { mate?.name ?? (teammateID == AppModel.chiefID ? model.chiefName : teammateID.capitalized) }
    private var isChief: Bool { teammateID == AppModel.chiefID }
    private var mine: [Ask] { state.asks.filter { isChief || $0.domain == teammateID } }

    var body: some View {
        VStack(spacing: 0) {
            // Ben's header carries one control and it is The team (the canvas, board 20). Role and
            // the screen belong to a domain agent: Ben has no routines of his own to show and no
            // computer to watch, and what every agent may do without asking is on the team screen.
            // It also keeps the corner to one control, which three never did.
            let lead = teammateID == AppModel.chiefID
            ChatHeader(look: mate?.look ?? Teammate.look(for: teammateID), title: name, subtitle: chat.roleLine, mood: mood,
                       onRole: lead ? nil : { model.go(.role(teammateID)) },
                       onWatch: lead ? nil : { model.go(.watch(teammateID)) }) {
                if lead {
                    HeaderChip(title: "The team", filled: true, id: "the-team") { model.go(.team) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if let stamp = chat.stamp {
                            Text(stamp).font(.ui(12)).foregroundStyle(Ink.tertiary).padding(.bottom, 12)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(chat.lines) { line($0) }
                            ForEach(chat.extraCards) { a in ApprovalCard(ask: a, label: from(a)) }
                            if chat.loaded, !chat.spoken, isChief { opener }
                            else if chat.loaded, chat.lines.isEmpty, chat.extraCards.isEmpty {
                                Text("Nothing here yet. Write to \(name) below.").font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.leading, 6)
                            }
                        }
                        .column()
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.top, 24).padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .onChange(of: chat.revision) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            SourceChips(lit: lit, available: available) { s in picked[s] = !lit.contains(s) }
                .padding(.top, 10)
            Composer(who: name, text: $draft, busy: chat.sending, others: model.team.filter { $0.id != teammateID },
                     bringIn: $bringIn, files: $files, send: send)
                .padding(.top, -10)
        }
        .task(id: teammateID) {
            draft = ""; bringIn = []; picked = [:]
            available = Set(Sources.enabled().filter { Sources.status($0, now: AppClock.now).state == .connected })
            chat.load(teammateID, chief: model.chiefName)
            chat.merge(mine)
            // A hand-off from another screen ("Ben can interview you"): send it as if typed.
            if let message = model.outbox.removeValue(forKey: teammateID), message.nonEmpty != nil { chat.send(message) }
        }
        .onChange(of: state.asks.map(\.id)) { chat.merge(mine) }
        // The team arrives from the engine, so a thread opened first has nobody to address a brief
        // to yet: read the hand-off again once the team is known (it never shows the same job
        // twice). And when the team goes, the cards go with it. the owner's invariant, 2026-10-31: take
        // the vault away and none of these apps should work. A brief naming an agent you can no
        // longer be shown is exactly the last good picture surviving its source.
        .onChange(of: model.team.map(\.id)) { _, team in
            if team.isEmpty { chat.dropHandOff() } else { Task { await chat.showHandOff() } }
        }
        .onChange(of: chat.savedCount) { old, new in
            guard new > old else { return }
            cheer = true
            Task { try? await Task.sleep(for: .seconds(1.6)); cheer = false }
        }
        .onDisappear { chat.stop() }
    }

    private func send() {
        guard !chat.sending else { return }
        let text = draft.nonEmpty ?? (files.isEmpty ? nil : "Here you go.")
        guard let text else { return }
        let sources = lit, sending = files
        draft = ""; files = []
        chat.send(text, bringIn: bringIn, sources: sources, files: sending)
    }

    /// What the face shows: happy just after a save, then whatever the turn is doing.
    private var mood: FaceMood { cheer ? .happy : chat.mood(typing: !draft.isEmpty, waiting: !mine.isEmpty) }

    private func from(_ a: Ask) -> String { "From \(model.teammate(a.domain)?.name ?? a.domain.capitalized)" }

    @ViewBuilder private func line(_ l: ChatSession.Line) -> some View {
        switch l.kind {
        case .me:
            if !l.attachments.isEmpty { AttachmentStrip(paths: l.attachments).frame(maxWidth: .infinity, alignment: .trailing) }
            ChatBubble(text: l.text, side: .me)
        case .them:
            ChatBubble(text: l.text, streaming: l.streaming) {
                ForEach(l.pages, id: \.self) { p in DocCard(p) { model.go(.chat(p.domain)) } }
            }
            if let slow = l.slow { Text(slow).font(.ui(12.5)).foregroundStyle(Ink.secondary).padding(.leading, 6).accessibilityIdentifier("slow") }
            ReadsView(reads: l.reads, steps: l.steps, reply: l.text, lineID: l.id)
            ForEach(l.saves) { item in
                SaveCard(item: item, save: { chat.save(line: l.id, item: item.id) }, skip: { chat.skip(line: l.id, item: item.id) },
                         undo: { chat.undo(line: l.id, item: item.id) })
            }
        case .failed: ChatBubble(text: l.text, failed: true)
        case .briefing(let b):
            ChatBubble(text: b.lead)
            ForEach(b.approvals) { a in ApprovalCard(ask: a, label: from(a), buttons: a.style != .review) }
            Text(b.closing).font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.leading, 6)
        case .handedOff(let h):
            let owed = Set(mine.map(\.domain))
            ForEach(h.cards) { c in
                HandOffCard(card: c, at: ChatSession.clock(l.ts),
                            waiting: mine.contains { $0.domain == c.domain }) { model.go(.chat(c.domain)) }
                // Money never moves on its own: if that agent is waiting on you for this, the ask
                // comes with the brief rather than only in Needs you.
                // Indented under the brief, so it reads as that agent's answer to that brief and
                // not as a second, unrelated thing the screen is asking for.
                ForEach(mine.filter { $0.domain == c.domain }) { a in
                    ApprovalCard(ask: a, label: from(a), buttons: a.style != .review)
                        .padding(.leading, 26)
                }
            }
            if let working = h.working(waiting: owed) {
                Text(working).font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.leading, 6)
                    .accessibilityIdentifier("still-working")
            }
        }
    }

    /// Ben with an empty thread: the question the design opens with, as a suggestion.
    private var opener: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask \(name)").font(.ui(12)).foregroundStyle(Ink.tertiary).padding(.leading, 6)
            Button(action: openBriefing) {
                Text(Briefing.question).font(.ui(15)).padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Capsule().fill(Ink.surface)).overlay(Capsule().strokeBorder(Ink.border)).contentShape(Capsule())
            }
            .buttonStyle(.plain).probe(Briefing.question, action: openBriefing)
        }
    }

    private func openBriefing() { chat.brief(Briefing.build(mine)) }
}

/// One conversation's state: the lines, the thread it continues, and the reply being streamed.
/// A file waiting to go with the next message.
struct Pending: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var data: Data
    var isImage: Bool { Attachments.isImage(name) }
}

@MainActor @Observable
final class ChatSession {
    struct Line: Identifiable {
        enum Kind { case me, them, failed, briefing(Briefing), handedOff(HandOff) }
        let id = UUID()
        var kind: Kind
        var text: String
        var ts: Date = AppClock.now
        var streaming = false
        var pages: [Brief] = []
        /// What the agent was given to read for this reply, numbered as it cites them.
        var reads: [SourceExcerpt] = []
        /// Steps the agent took itself (files it opened, tools it ran), from the engine.
        var steps: [String] = []
        /// What the reply asked to save, and what became of each.
        var saves: [SaveItem] = []
        /// Shown under the thinking face when a turn has been quiet a while.
        var slow: String?
        /// Files sent with this message (vault-relative paths).
        var attachments: [String] = []
    }

    struct SaveItem: Identifiable, Equatable {
        enum State: Equatable { case proposed, saving, saved(Turn.Told), skipped, failed(String) }
        let id = UUID()
        var text: String
        var state: State = .proposed
    }

    var slug = ""
    var lines: [Line] = []

    var savedCount: Int { lines.reduce(0) { n, l in n + l.saves.filter { if case .saved = $0.state { true } else { false } }.count } }

    /// The agent's face for this moment of the conversation.
    func mood(typing: Bool, waiting: Bool) -> FaceMood {
        if let last = lines.last {
            if last.streaming { return last.text.isEmpty ? .thinking : .speaking }
            if case .failed = last.kind { return typing ? .listening : .sad }
        }
        if typing { return .listening }
        if lines.last?.saves.contains(where: { $0.state == .proposed }) == true || waiting { return .asking }
        return .rest
    }
    var session: String?
    var sending = false
    var loaded = false
    var roleLine = ""
    var revision = 0
    /// Waiting items for this teammate seen while the chat is open; they stay to show their outcome.
    var cards: [Ask] = []
    private var briefs: [Brief] = []
    private var task: Task<Void, Never>?

    var stamp: String? {
        guard let first = lines.first?.ts else { return nil }
        let cal = Calendar.current, today = AppClock.today
        let day = cal.isDate(first, inSameDayAs: today) ? "Today"
            : cal.date(byAdding: .day, value: -1, to: today).map { cal.isDate(first, inSameDayAs: $0) } == true ? "Yesterday"
            : first.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) \(first.formatted(date: .omitted, time: .shortened))"
    }

    /// Cards not already shown inside the thread: the briefing covers its approvals and names its
    /// questions, and a hand-off shows the ask beside the brief it belongs to. Either way the ask
    /// appears once, where it means something, rather than twice on the same screen.
    var extraCards: [Ask] {
        var covered = Set<String>(), handed = Set<String>()
        for l in lines {
            switch l.kind {
            case .briefing(let b): covered.formUnion(b.covered)
            case .handedOff(let h): handed.formUnion(h.cards.map(\.domain))
            default: break
            }
        }
        return cards.filter { !covered.contains($0.id) && !handed.contains($0.domain) }
    }

    func load(_ slug: String, chief: String) {
        stop()
        self.slug = slug
        briefs = Brief.all()
        roleLine = Self.roleLine(slug)
        cards = []
        session = nil
        lines = []
        if let file = Threads.newest(slug), let text = Vault.read(file) {
            session = file.deletingPathExtension().lastPathComponent
            var pending: [SourceExcerpt] = []
            lines = Threads.turns(text).suffix(200).map { t in
                let ts = Date(timeIntervalSince1970: t.ts / 1000)
                if t.role == "user" {
                    let (said, reads) = Turn.split(t.text)
                    let files = Turn.attachments(in: t.text)
                    pending = reads
                    return Line(kind: .me, text: said, ts: ts, attachments: files)
                }
                let (reply, saves) = Turn.saves(in: t.text)
                defer { pending = [] }
                return Line(kind: .them, text: reply, ts: ts, pages: Brief.referenced(in: reply, from: briefs),
                            reads: pending, saves: saves.map { SaveItem(text: $0) })
            }
        }
        loaded = true
        revision += 1
        markSaved()
        // What was handed out belongs to the job, not to this screen's memory. Re-reading it here
        // means leaving the thread and coming back does not lose it, and that the cards are the
        // engine's current answer rather than the one from when you happened to be watching.
        Task { [weak self] in await self?.showHandOff() }
    }

    /// Saves asked for in earlier replies that the engine has already filed show as saved.
    private func markSaved() {
        guard lines.contains(where: { !$0.saves.isEmpty }) else { return }
        Task { [weak self] in
            guard let told = try? await Engine.json(["tell", "list", "--limit", "200"], as: [Turn.Told].self) else { return }
            guard let self else { return }
            let byText = Dictionary(told.map { ($0.text.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            for i in self.lines.indices {
                for j in self.lines[i].saves.indices {
                    let key = self.lines[i].saves[j].text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    if let t = byText[key] ?? told.first(where: { key.hasPrefix($0.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))) }) {
                        self.lines[i].saves[j].state = .saved(t)
                    }
                }
            }
            self.revision += 1
        }
    }

    /// Saves one asked-for item through the engine (`prevail tell`), or takes a save back.
    func save(line: UUID, item: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == line }), let j = lines[i].saves.firstIndex(where: { $0.id == item }) else { return }
        let text = lines[i].saves[j].text
        lines[i].saves[j].state = .saving
        revision += 1
        Task { [weak self, slug] in
            let state: SaveItem.State
            do { state = .saved(try await Turn.save(text, agent: slug)) } catch { state = .failed(error.localizedDescription) }
            guard let self, let i = self.lines.firstIndex(where: { $0.id == line }), let j = self.lines[i].saves.firstIndex(where: { $0.id == item }) else { return }
            self.lines[i].saves[j].state = state
            self.revision += 1
        }
    }

    func skip(line: UUID, item: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == line }), let j = lines[i].saves.firstIndex(where: { $0.id == item }) else { return }
        lines[i].saves[j].state = .skipped
        revision += 1
    }

    func undo(line: UUID, item: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == line }), let j = lines[i].saves.firstIndex(where: { $0.id == item }),
              case .saved(let told) = lines[i].saves[j].state else { return }
        Task { [weak self] in
            let state: SaveItem.State
            do { try await Turn.undo(told); state = .proposed } catch { state = .failed(error.localizedDescription) }
            guard let self, let i = self.lines.firstIndex(where: { $0.id == line }), let j = self.lines[i].saves.firstIndex(where: { $0.id == item }) else { return }
            self.lines[i].saves[j].state = state
            self.revision += 1
        }
    }

    func merge(_ asks: [Ask]) {
        let have = Set(cards.map(\.id))
        let new = asks.filter { !have.contains($0.id) }
        if !new.isEmpty { cards += new; revision += 1 }
    }

    func brief(_ b: Briefing) {
        lines.append(Line(kind: .me, text: Briefing.question))
        lines.append(Line(kind: .briefing(b), text: b.lead))
        revision += 1
    }

    /// Sends a message and streams the reply: deltas as they come, then the final text.
    /// Sends a message and streams the reply: deltas as they come, then the final text. The sources
    /// chosen for the turn are read first and go with the message, numbered for citing.
    func send(_ text: String, bringIn: [String] = [], sources: Set<SourceID>? = nil, files: [Pending] = []) {
        guard !sending else { return }
        var saved: [String] = []
        for f in files {
            do { saved.append(try Attachments.save(f.data, name: f.name, agent: slug).path) }
            catch { lines.append(Line(kind: .failed, text: "\(f.name) wasn't attached: \(error.localizedDescription)")) }
        }
        let chosen = sources ?? Sources.relevant(text, agent: slug)
        let reads = Sources.excerpts(for: text, agent: slug, using: chosen, now: AppClock.now)
        lines.append(Line(kind: .me, text: text, attachments: saved))
        lines.append(Line(kind: .them, text: "", streaming: true, reads: reads))
        let at = lines.count - 1
        sending = true
        revision += 1
        var args = ["chat", "--domain", slug, "--json"]
        if let session { args += ["--session", session] }
        for d in bringIn { args += ["--ref-domain", d] }
        let message = Turn.message(text, excerpts: reads, attachments: saved)
        var last = Date.now
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.lines.indices.contains(at), self.lines[at].streaming else { return }
                let quiet = Date.now.timeIntervalSince(last)
                self.lines[at].slow = quiet >= 20 ? Turn.slowHint(quiet) : nil
            }
        }
        task = Task { [weak self] in
            let r = await Self.consume(Engine.lines(args, stdin: Data(message.utf8)), step: { label in last = .now; self?.step(label, at: at) }) { partial in last = .now; self?.show(partial, at: at) }
            beat.cancel()
            guard let self, !Task.isCancelled else { return }
            if self.lines.indices.contains(at) { self.lines[at].slow = nil }
            if let t = r.thread { self.session = t }
            if let failure = r.failure {
                let who = AppModel.shared.teammate(self.slug)?.name ?? self.slug.capitalized
                self.lines[at] = Line(kind: .failed, text: "\(who) couldn't answer: \(failure)")
            } else {
                let (reply, saves) = Turn.saves(in: r.reply)
                self.lines[at].text = reply
                self.lines[at].streaming = false
                self.lines[at].pages = Brief.referenced(in: reply, from: self.briefs)
                self.lines[at].saves = saves.map { SaveItem(text: $0) }
            }
            self.sending = false
            self.revision += 1
            await self.showHandOff()
        }
    }

    /// What the engine handed out for this thread: read when the thread opens and again after each
    /// reply. Only the one who runs the team hands work on, and only a job it still owns; a job
    /// already on screen is not added twice.
    func showHandOff() async {
        guard slug == AppModel.chiefID else { return }
        guard let jobs = try? await Engine.json(["job", "list"], as: [Watch.Job].self),
              let job = HandOff.mine(jobs, owner: slug),
              let handed = HandOff.build(job, team: AppModel.shared.team) else { return }
        let shown = lines.contains { if case .handedOff(let h) = $0.kind { h.jobID == handed.jobID } else { false } }
        guard !shown else { return }
        lines.append(Line(kind: .handedOff(handed), text: handed.working() ?? ""))
        revision += 1
    }

    /// Whether anyone has actually said anything. A hand-off and an ask are things the screen is
    /// showing you, not a conversation, so the opener still belongs under them.
    var spoken: Bool {
        lines.contains { if case .handedOff = $0.kind { false } else { true } }
    }

    /// Drops what was handed out. Called when the team it names is gone.
    func dropHandOff() {
        let kept = lines.filter { if case .handedOff = $0.kind { false } else { true } }
        guard kept.count != lines.count else { return }
        lines = kept
        revision += 1
    }

    /// "9:06 AM", the clock the thread stamps everything else with.
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    private func step(_ label: String, at i: Int) {
        guard lines.indices.contains(i), !lines[i].steps.contains(label) else { return }
        lines[i].steps.append(label)
        revision += 1
    }

    struct Outcome: Equatable { var reply = ""; var thread: String?; var failure: String?; var steps: [String] = [] }

    /// Reads a `chat --json` stream: `start` names the thread, `delta`s build the reply (shown as
    /// they come), `assistant` is the final text, `error` (or the stream failing) is the failure.
    static func consume(_ stream: AsyncThrowingStream<String, Error>, step: (String) -> Void = { _ in }, partial: (String) -> Void) async -> Outcome {
        var o = Outcome()
        do {
            for try await raw in stream {
                guard let e = ChatEvent.parse(raw) else { continue }
                switch e.type {
                case "start": if let t = e.thread?.nonEmpty { o.thread = t }
                case "delta": o.reply += e.text ?? ""; partial(o.reply)
                case "assistant": if let t = e.text, t.nonEmpty != nil { o.reply = t; partial(t) }
                case "error": o.failure = e.error?.nonEmpty ?? "The chat stopped."
                case "tool": if let l = (e.step?.label ?? e.text)?.nonEmpty, e.step?.status != "failed" { o.steps.append(l); step(l) }
                default: break
                }
            }
        } catch is CancellationError {
        } catch {
            o.failure = o.failure ?? error.localizedDescription
        }
        if o.failure == nil, o.reply.nonEmpty == nil { o.failure = "No reply came back. Check that a model is set up for the engine." }
        return o
    }

    private func show(_ text: String, at i: Int) {
        guard lines.indices.contains(i) else { return }
        lines[i].text = Turn.saves(in: text).text
        revision += 1
    }

    func stop() { task?.cancel(); task = nil; sending = false }

    /// "Chief of staff · works toward: <life purpose>", or "<Name> · works toward: <domain purpose>".
    static func roleLine(_ slug: String, root: URL = Vault.root) -> String {
        let store = IntentStore(root: root)
        if slug == AppModel.chiefID {
            let p = store.life().purpose.replacingOccurrences(of: "\n", with: " ")
            return p.isEmpty ? "Chief of staff" : "Chief of staff · works toward: \(p)"
        }
        let c = store.contract(slug)
        let p = c.purpose.replacingOccurrences(of: "\n", with: " ")
        return p.isEmpty ? c.title : "\(c.title) · works toward: \(p)"
    }
}

/// Ben's answer to "What needs me tonight?", built from what is waiting, the goals in focus and the
/// teammates' own memory: the approvals (soonest first), which one not to let wait and why, then
/// what else there is.
struct Briefing: Hashable {
    static let question = "What needs me tonight?"
    var lead: String
    var approvals: [Ask]
    var closing: String
    var covered: [String]

    @MainActor static func build(_ asks: [Ask], root: URL = Vault.root) -> Briefing {
        let store = IntentStore(root: root)
        let slugs = store.domainSlugs()
        let goals = slugs.flatMap { store.goals($0).outcomes }.filter { $0.inFocus && !$0.done && $0.status == "active" }
        let focus = Set(goals.map(\.id))
        let approvals = asks.filter { $0.style != .question && $0.style != .loop }
            .sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }
        let questions = asks.filter { $0.style == .question }
        let name = { (d: String) in AppModel.shared.teammate(d)?.name ?? store.contract(d).title }

        var lead: String
        let n = approvals.count
        if n == 0 {
            lead = "Nothing needs a yes from you tonight."
        } else {
            let count = number(n)
            let serve = approvals.allSatisfy { $0.goal.map(focus.contains) ?? false }
            lead = serve ? (n == 1 ? "One thing, and it moves what you said matters most."
                                   : "\(count) things, and \(n == 2 ? "both" : "all") move what you said matters most.")
                         : (n == 1 ? "One thing needs you." : "\(count) things need you.")
            if n > 1, let first = approvals.first {
                let f = fact(first.domain, store: store)
                lead += " \(name(first.domain)) is the one I would not let wait" + (f.map { ": \($0)" } ?? ".")
            }
        }
        var closing = questions.isEmpty ? "Everything else is handled." : questionLine(questions.map { name($0.domain) })
        if !goals.isEmpty { closing += " \(goals.count) goal\(goals.count == 1 ? "" : "s") in focus \(goals.count == 1 ? "is" : "are") moving." }
        return Briefing(lead: lead, approvals: approvals, closing: closing, covered: (approvals + questions).map(\.id))
    }

    static func number(_ n: Int) -> String {
        ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"].indices.contains(n)
            ? ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"][n] : "\(n)"
    }

    static func questionLine(_ names: [String]) -> String {
        let u = names.uniqued()
        let who = u.count == 1 ? u[0] : u.dropLast().joined(separator: ", ") + " and " + u.last!
        return "\(who) \(u.count == 1 ? "has a question" : "have questions") for you, no rush."
    }

    /// The first durable fact a teammate keeps that isn't its purpose, as a clause.
    static func fact(_ domain: String, store: IntentStore) -> String? {
        let purpose = store.contract(domain).purpose
        let md = Markdown(Vault.read(store.domainDir(domain).appending(path: "memory/memory.md")) ?? "")
        guard let f = md.bullets(of: "Durable facts").first(where: { $0 != purpose && !$0.contains(":") }) else { return nil }
        var s = TeamActivity.firstSentence(f)
        if let w = s.split(separator: " ").first, ["The", "A", "An", "It", "This", "Your", "My"].contains(String(w)) {
            s = s.prefix(1).lowercased() + s.dropFirst()
        }
        return s.hasSuffix(".") ? s : s + "."
    }
}
