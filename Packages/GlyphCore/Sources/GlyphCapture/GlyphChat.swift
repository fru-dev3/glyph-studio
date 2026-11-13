#if os(iOS)
import GlyphAI
import GlyphVault
import SwiftUI

/// One line on a Glyph chat screen. Mine (a bubble in the app's colour, three lines then "More"), or the app's:
/// a `card` (one line that never wraps, a tick when it made something, Undo), an `answer` (longer text, several
/// paragraphs, wrapped) or an `ask` (the app asked back; the next turn carries it in the history).
public struct ChatEntry: Identifiable {
    public enum Kind: Sendable { case card, answer, ask }
    public var id = UUID()
    public var mine: Bool
    public var text: String
    public var kind: Kind
    /// The whole answer, shown on a tap; `text` is its one short line.
    public var detail: String?
    /// It made something: semibold, and Undo when `undo` is set.
    public var done: Bool
    public var working: Bool
    public var mood: FaceMood
    public var undo: (@MainActor () -> Void)?
    /// Where a tap goes (the app that holds it).
    public var link: URL?
    /// Offered, not done yet (another app's job): Save runs it and the card becomes what it returns; Dismiss drops it.
    public var save: (@MainActor () async -> ChatEntry)?
    /// Another app's agent speaking (its face beside the line, "time"), nil for this app's own.
    public var agent: String?
    /// Still going once shown (waiting on another app): ChatModel runs it, the first line it returns takes this
    /// one's place and the rest follow.
    public var then: (@MainActor () async -> [ChatEntry])?

    public init(mine: Bool = false, text: String, kind: Kind = .card, detail: String? = nil, done: Bool = false, working: Bool = false,
                mood: FaceMood? = nil, undo: (@MainActor () -> Void)? = nil, link: URL? = nil, save: (@MainActor () async -> ChatEntry)? = nil,
                agent: String? = nil, then: (@MainActor () async -> [ChatEntry])? = nil) {
        self.mine = mine; self.text = text; self.kind = kind; self.detail = detail; self.done = done; self.working = working
        self.mood = mood ?? (kind == .ask ? .asking : done ? .happy : .rest)
        self.undo = undo; self.link = link; self.save = save; self.agent = agent; self.then = then
    }
    /// An answer to show in full.
    public static func answer(_ text: String) -> ChatEntry { ChatEntry(text: text, kind: .answer) }
    /// A question back.
    public static func ask(_ text: String) -> ChatEntry { ChatEntry(text: text, kind: .ask) }
}

/// A chat's lines and its turn-taking, kept by the app (so it can say something from outside, as Time does
/// with what Glyph Native hands over). `respond` gets what was said and the turns before it (for /understand's
/// `history`) and returns the app's entries; the first replaces the "working" line, the rest follow. Nil means
/// Glyph can't be reached: a calm bubble says so and the words are kept, said again by `resend()` (when the
/// screen shows) once it answers.
@MainActor @Observable public final class ChatModel {
    public var entries: [ChatEntry] = []
    public let app: String
    public var working = "Working on it"
    @ObservationIgnored public var respond: @MainActor (String, [ChatTurn]) async -> [ChatEntry]?
    /// Past chats (optional): each turn is saved here, and the screen shows the history button.
    @ObservationIgnored public var log: ChatLog?
    @ObservationIgnored public var device: String?
    public private(set) var chatID = ChatLog.newID()

    public init(app: String, log: ChatLog? = nil, device: String? = nil, respond: @escaping @MainActor (String, [ChatTurn]) async -> [ChatEntry]?) {
        self.app = app; self.log = log; self.device = device; self.respond = respond
    }

    /// The turns so far, as /understand's history wants them.
    public var turns: [ChatTurn] {
        entries.filter { !$0.working }.map { ChatTurn(mine: $0.mine, text: $0.mine ? $0.text : ($0.detail ?? $0.text)) }
    }

    /// Mine, then the working line, then what the app did. Returns the app's entries.
    @discardableResult
    public func say(_ words: String) async -> [ChatEntry] {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return [] }
        let before = turns
        withAnimation(.snappy) {
            entries.append(ChatEntry(mine: true, text: said))
            entries.append(ChatEntry(text: working, working: true, mood: .thinking))
        }
        let slot = entries[entries.count - 1].id
        guard let got = await respond(said, before) else {
            keep(said)
            let off = [ChatEntry(text: Self.offline, mood: .rest)]
            withAnimation(.snappy) { if let i = entries.firstIndex(where: { $0.id == slot }) { var e = off[0]; e.id = slot; entries[i] = e } }
            persist()
            return off
        }
        withAnimation(.snappy) {
            guard let i = entries.firstIndex(where: { $0.id == slot }) else { return }
            if var first = got.first { first.id = slot; entries[i] = first; entries.insert(contentsOf: got.dropFirst(), at: i + 1) }
            else { entries.remove(at: i) }
        }
        persist()
        let mine = Set(got.dropFirst().map(\.id) + [slot])
        for e in entries where e.then != nil && mine.contains(e.id) { finish(e) }
        return got
    }

    /// A line still going (`then`): once it returns, its first line takes this one's place and the rest follow.
    func finish(_ e: ChatEntry) {
        guard let then = e.then else { return }
        update(e.id) { $0.then = nil }
        Task {
            let more = await then()
            withAnimation(.spring(duration: 0.45)) {
                guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
                if var first = more.first { first.id = e.id; entries[i] = first; entries.insert(contentsOf: more.dropFirst(), at: i + 1) }
                for n in more.dropFirst() where n.then != nil { finish(n) }
            }
            persist()
        }
    }

    public static let offline = "Can't reach Glyph right now, saved to send."
    var pendingKey: String { "glyphChatPending.\(app)" }
    /// Words said while Glyph was away, kept on this phone.
    public var pending: [String] { UserDefaults.standard.stringArray(forKey: pendingKey) ?? [] }
    func keep(_ said: String) { UserDefaults.standard.set(pending + [said], forKey: pendingKey) }
    /// Says each kept sentence again, in order, while Glyph answers; stops (keeping the rest) when it doesn't.
    public func resend() async {
        while let next = pending.first {
            UserDefaults.standard.set(Array(pending.dropFirst()), forKey: pendingKey)
            let got = await say(next)
            if got.first?.text == Self.offline { break }
        }
    }

    public func update(_ id: UUID, _ change: (inout ChatEntry) -> Void) {
        if let i = entries.firstIndex(where: { $0.id == id }) { change(&entries[i]); persist() }
    }

    public func newChat() { withAnimation { entries = [] }; chatID = ChatLog.newID() }

    /// Picks up the last conversation instead of opening on a blank screen. A chat screen that
    /// starts empty every time is not a thread: what was said a minute ago is gone, and the only
    /// way back to it is the history sheet. Call it when the screen appears; it does nothing when
    /// there is already something on screen, when there is no log, or when nothing was ever said,
    /// so the first chat still opens on the welcome. `newChat()` is how you deliberately start over.
    public func resume() {
        guard entries.isEmpty, let log, let last = log.chats().first else { return }
        reopen(last)
    }

    /// A past chat back on the screen, to carry on.
    public func reopen(_ c: Chat) {
        chatID = c.id
        entries = c.lines.map { l in
            ChatEntry(mine: l.mine, text: l.short ?? l.text, kind: l.status == "asking" ? .ask : l.short == nil && !l.mine && l.status == nil ? .answer : .card,
                      detail: l.short == nil ? nil : l.text, done: l.status == "done")
        }
    }

    func persist() {
        guard let log else { return }
        let lines = entries.enumerated().filter { !$0.element.working }.map { n, e in
            ChatLine(n: n, mine: e.mine, text: e.detail ?? e.text, short: e.detail == nil ? nil : e.text,
                     status: e.kind == .ask ? "asking" : e.done ? "done" : e.text == "Undone" ? "undone" : e.kind == .answer || e.mine ? nil : "failed")
        }
        try? log.save(lines, to: chatID, device: device)
    }
}

/// The family's chat screen (extracted from Glyph Time's Chat and Glyph Native's home): a bright welcome with the
/// app's face, then a back and forth. Voice first (the talk button, "Type instead"), "New chat", and past chats
/// when the model has a `ChatLog`. Accessibility identifiers: chat-welcome, chat-mine, chat-reply, chat-answer,
/// chat-ask, chat-detail, chat-undo, chat-save, chat-dismiss, chat-field, chat-send, chat-type, chat-new,
/// fru-composing, chat-history.
public struct GlyphChat: View {
    @Bindable var model: ChatModel
    /// nil draws no face anywhere in the chat: no tile over the welcome and none beside an answer.
    /// Fru, 2026-11-09, looking at Glyph CRM's chat on his phone: "I should'nt have any design like
    /// this". An app that wants the mascot still passes a colour and is unchanged.
    let face: Color?
    let tint: Color
    let agent: String
    let name: String
    let title: String
    let subtitle: String?
    let examples: [String]
    let placeholder: String
    let caption: String
    /// .center is the family's welcome, stacked down the middle. .leading is the CRM artboards,
    /// which put the title and its line at the 20pt gutter with the conversation under them.
    let align: HorizontalAlignment
    /// An app's own top bar. It has to be insetted inside this NavigationStack: attached outside
    /// it, the inset never reaches this ScrollView and the conversation scrolls up under the bar
    /// (Fru, 2026-11-09, "Text is hidding", with a message half behind Glyph CRM's header).
    let top: AnyView?
    /// The composer's plus: what an app offers to attach. nil leaves it out.
    let attach: (() -> Void)?
    let attachLabel: String
    /// nil keeps the family's composer (the talk button and its text row). An app that draws its
    /// own bottom passes one here and is handed the two things only the chat can do: say these
    /// words, and open the keyboard.
    let bottom: ((@escaping (String) -> Void, @escaping () -> Void) -> AnyView)?
    @Environment(\.openURL) private var openURL
    @State private var opened: Set<UUID> = []
    @State private var talking = false
    @State private var showHistory = false
    private var composing: Bool { talking }

    /// - face: the agent's tile colour; tint: bubbles, buttons, dots; agent: its id (the face's seed);
    ///   name: under the face ("Time"); title and examples: the welcome; placeholder: the text field's.
    public init(model: ChatModel, face: Color?, tint: Color, agent: String, name: String, title: String,
                subtitle: String? = nil, examples: [String] = [],
                placeholder: String, caption: String = "Tap to talk",
                align: HorizontalAlignment = .center,
                top: AnyView? = nil,
                attach: (() -> Void)? = nil,
                attachLabel: String = "Attach",
                bottom: ((@escaping (String) -> Void, @escaping () -> Void) -> AnyView)? = nil) {
        self.model = model; self.face = face; self.tint = tint; self.agent = agent; self.name = name
        self.title = title; self.subtitle = subtitle
        self.examples = examples; self.placeholder = placeholder; self.caption = caption
        self.align = align; self.top = top; self.bottom = bottom
        self.attach = attach; self.attachLabel = attachLabel
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 14) {
                        if model.entries.isEmpty { welcome } else {
                            ForEach(model.entries) { l in bubble(l).id(l.id) }
                            if composing { fruDots.id("fru-dots") }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .clipped()   // inside the safe area: a scrolled bubble never runs under the clock
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color(uiColor: .systemBackground), Color(uiColor: .systemBackground).opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20).allowsHitTesting(false)
                }
                .onChange(of: model.entries.count) { _, _ in withAnimation { scroll.scrollTo(model.entries.last?.id, anchor: .bottom) } }
                .onChange(of: composing) { _, on in if on { withAnimation { scroll.scrollTo("fru-dots", anchor: .bottom) } } }
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) { if let top { top } }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.resend() }
            .sheet(isPresented: $showHistory) {
                if let log = model.log { ChatHistorySheet(log: log, current: model.chatID, tint: tint) { model.reopen($0) } }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: align, spacing: 18) {
            if let face {
                FaceTile(color: face, size: 76, mood: composing ? .listening : .rest, seed: FaceMood.seed(agent))
                    .padding(.top, 48)
            } else {
                Color.clear.frame(height: 24)
            }
            // System sans, which is the family's type token. The rounded face was drawn to go with
            // the mascot tile, and reads as a toy without it.
            Text(title)
                .font(.system(size: 32, weight: .bold)).kerning(-0.7).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: edge)
                .accessibilityIdentifier("chat-welcome")
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: edge)
                    .padding(.top, -10)
            }
            VStack(alignment: align, spacing: 10) {
                ForEach(examples, id: \.self) { e in
                    Button { send(e) } label: {
                        Text(e).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: edge)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func bubble(_ l: ChatEntry) -> some View {
        if l.mine {
            // At most three lines, so a long dictation never pushes the answers away; a tap shows it all.
            let long = l.text.count > 110 && !opened.contains(l.id)
            VStack(alignment: .trailing, spacing: 4) {
                Text(l.text).font(.body).foregroundStyle(.white).lineLimit(long ? 3 : nil)
                if long { Text("More").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85)) }
            }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 48)
                .onTapGesture { withAnimation(.snappy) { _ = opened.insert(l.id) } }
                .accessibilityElement(children: .combine).accessibilityIdentifier("chat-mine")
                .springIn(from: .trailing)
        } else {
            // The agent's face beside each answer: it works, then nods (or asks, or droops) as the answer lands.
            HStack(alignment: .bottom, spacing: 10) {
                let other = l.agent.flatMap(GlyphAgent.named)  // another app's agent at work: its own face
                if let face {
                    FaceTile(color: other.map { Color(hex: $0.color) } ?? face,
                             size: 32, mood: l.working ? .thinking : composing && l.id == model.entries.last?.id ? .listening : l.mood,
                             seed: FaceMood.seed(other?.id ?? agent), name: other?.name ?? name)
                        .padding(.bottom, 6)
                }
                reply(l)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .springIn(from: .leading)
        }
    }

    private func reply(_ l: ChatEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if l.kind == .card || l.working {
                    // One line that never wraps (cut short, not folded); the whole answer is on a tap.
                    Text(l.text).font(.body.weight(l.done ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                        .accessibilityIdentifier("chat-reply")
                } else {
                    Text(l.text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier(l.kind == .ask ? "chat-ask" : "chat-answer")
                }
                if let d = l.detail, opened.contains(l.id) {
                    Text(d).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-detail")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let link = l.link { openURL(link) }
                else if l.detail != nil { withAnimation(.snappy) { if !opened.insert(l.id).inserted { opened.remove(l.id) } } }
            }
            if l.working { ThinkingDots(color: tint) }
            Spacer(minLength: 4)
            if let save = l.save, !l.working {
                Button("Save") {
                    model.update(l.id) { $0.working = true }
                    Task { let e = await save(); withAnimation(.snappy) { model.update(l.id) { old in var e = e; e.id = old.id; old = e } } }
                }
                .font(.subheadline.weight(.semibold)).tint(tint).accessibilityIdentifier("chat-save")
                Button("Dismiss") { model.update(l.id) { $0.save = nil; $0.text = "Not saved"; $0.detail = nil; $0.mood = .rest } }
                    .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("chat-dismiss")
            }
            if let undo = l.undo {
                Button("Undo") { undo(); model.update(l.id) { $0.undo = nil; $0.done = false; $0.text = "Undone"; $0.mood = .rest } }
                    .font(.subheadline.weight(.semibold)).tint(tint)
                    .accessibilityIdentifier("chat-undo")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .settle(on: l.working)
    }

    /// The family's one input row, `GlyphComposer`, which every Glyph phone screen now draws.
    private var composer: some View {
        GlyphComposer(tint: tint, placeholder: placeholder, attach: attach, attachLabel: attachLabel) { words, _ in send(words) }
    }

    /// The welcome's two lines read against the same edge the stack uses.
    private var edge: Alignment { align == .leading ? .leading : (align == .trailing ? .trailing : .center) }

    /// The person's side, alive while they talk or type: three dots in a small bubble.
    private var fruDots: some View {
        ThinkingDots(color: .white, size: 6)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(tint, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .springIn(from: .trailing)
            .accessibilityElement().accessibilityLabel("You're talking").accessibilityIdentifier("fru-composing")
    }

    @ViewBuilder private var newChat: some View {
        if model.log != nil {
            Button("Past chats") { showHistory = true }.accessibilityIdentifier("chat-history")
        }
        if !model.entries.isEmpty {
            Button("New chat") { model.newChat(); opened = [] }.accessibilityIdentifier("chat-new")
        }
    }

    private func send(_ words: String) {
        Task { _ = await model.say(words) }
    }
}
#endif
