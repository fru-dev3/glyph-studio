import SwiftUI
import GlyphCapture

// Pieces the More screens share: a board's frame, the chat parts of the weekly note (private until
// Screens/Team ships reusable ones), a domain mark, a floating panel, and the dates the engine prints.

/// A board: the breadcrumb bar ("Life / People"), then the dotted canvas with the content on it.
struct MoreBoard<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            BoardBar(crumbs: [title], onCrumb: { _ in }) { trailing }
            ZStack(alignment: .topLeading) {
                DotCanvas()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

/// The grey words at the right of a board's bar ("3 open · nearest first").
struct MoreBarNote: View {
    let text: String
    var body: some View { Text(text).font(.ui(13)).foregroundStyle(Color(hex: 0x6B706C)).lineLimit(1) }
}

/// A domain's teammate mark, as small as 18 points next to a label.
struct DomainMark: View {
    let domain: String
    var size: CGFloat = 18
    var body: some View { Avatar(look: Teammate.look(for: domain), size: size) }
}

extension Teammate {
    /// The display name of a domain ("estate" -> "Estate"; the chief of staff by name).
    @MainActor static func label(_ slug: String) -> String {
        if slug == AppModel.chiefID { return AppModel.shared.chiefName }
        return AppModel.shared.teammate(slug)?.name ?? slug.capitalized
    }
    static func color(_ slug: String) -> Color { Color(hex: look(for: slug).color) }
}

// MARK: chat parts (09)

/// The bar above a conversation: avatar, name and line, then Role and the screen button.
struct MoreChatHeader: View {
    let teammate: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            DomainMark(domain: teammate, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.ui(15, .semibold))
                Text(subtitle).font(.ui(12)).foregroundStyle(Color(hex: 0x7A7F7B)).lineLimit(1)
            }
            Spacer()
            Button { AppModel.shared.go(.role(teammate)) } label: {
                Text("Role").font(.ui(13, .medium)).padding(.horizontal, 14).frame(height: 32).background(Capsule().fill(Ink.chip)).contentShape(Capsule())
            }
            .buttonStyle(.plain).probe("Role") { AppModel.shared.go(.role(teammate)) }
            RoundIcon(symbol: "display", label: "Watch it work") { AppModel.shared.go(.watch(teammate)) }
        }
        .padding(.horizontal, 22).frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

/// A teammate's message: a grey bubble, an optional small "from" line, the text, then anything below.
struct MoreBubble<Extra: View>: View {
    var from: String?
    let text: String
    var muted = false
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let from { Text(from).font(.ui(12)).foregroundStyle(Ink.tertiary).padding(.bottom, 9) }
            Text(ChatBubble<EmptyView>.inline(Turn.saves(in: text).text)).font(.ui(15)).lineSpacing(3.6).foregroundStyle(muted ? Ink.tertiary : Ink.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.top, 2).padding(.bottom, 1) // CSS line-height 1.5 leaves half a line's leading below the text
            extra
        }
        .columnMax(0.75, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.bubble))
        .columnMax(0.80, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MoreBubble where Extra == EmptyView {
    init(from: String? = nil, text: String, muted: Bool = false) { self.init(from: from, text: text, muted: muted) { EmptyView() } }
}

/// The owner's own message: black, on the right.
struct MoreMine: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(15)).foregroundStyle(Ink.onInk).padding(.horizontal, 16).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.text))
            .columnMax(0.74, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// "Message Ben": the rounded field at the bottom of a conversation.
struct MoreComposer: View {
    let who: String
    @Binding var text: String
    var id = "composer"
    let send: () -> Void

    @State private var dictation = LiveDictation()
    /// Send stops a take first, so all of what was said goes, and nothing said after comes back.
    private func go() { dictation.finishForSend(); send() }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34).background(Circle().fill(Ink.chip))
            // The prompt is drawn by hand: a field's own placeholder doesn't show in window snapshots.
            TextField("", text: $text).textFieldStyle(.plain).font(.ui(15)).onSubmit(go)
                .overlay(alignment: .leading) { if text.isEmpty { Text("Message \(who)").font(.ui(15)).foregroundStyle(Color(hex: 0x9A9F9B)).allowsHitTesting(false) } }
                .probeField(id, text: $text, submit: go)
            Mic(text: $text, dictation: dictation, id: id)
        }
        .padding(.leading, 10).padding(.trailing, 8).column(height: 50)
        .background(Capsule().fill(Ink.surface).shadow(color: .black.opacity(0.08), radius: 10, y: 6))
        .overlay(Capsule().strokeBorder(Ink.border))
        .padding(.top, 14).padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }
}

/// A chat turn with a teammate through the engine's NDJSON stream; `onText` gets the reply so far.
enum MoreChat {
    static func send(_ message: String, to domain: String, onText: @MainActor @escaping (String) -> Void) async throws {
        var reply = ""
        for try await line in Engine.lines(["chat", "--domain", domain, "--json"], stdin: Data(message.utf8)) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "delta": reply += obj["text"] as? String ?? ""; await onText(reply)
            case "assistant": reply = obj["text"] as? String ?? reply; await onText(reply)
            case "error": throw EngineError(message: obj["error"] as? String ?? "The chat stopped.")
            default: break
            }
        }
        if reply.isEmpty { throw EngineError(message: "No reply came back.") }
    }
}

// MARK: surfaces

/// A white sheet floating over the screen (settings, a person, an event), on a quiet ground.
struct MorePanel<Content: View>: View {
    var width: CGFloat = 640
    var dim = true
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            (dim ? Color.black.opacity(0.12) : Color(hex: 0xEEF0ED)).ignoresSafeArea()
            ScrollView {
                content
                    .padding(.horizontal, 30).padding(.vertical, 24)
                    .frame(width: width, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.surface)
                        .shadow(color: .black.opacity(0.22), radius: 30, y: 18))
                    .padding(.top, 22).padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}

/// The small grey heading inside a panel or card ("VAULT", "YOUR GUT").
struct MoreLabel: View {
    let text: String
    var size: CGFloat = 12
    var body: some View { Text(text.uppercased()).font(.ui(size, .semibold)).foregroundStyle(Ink.tertiary) }
}

/// A grey link-like text button (Done, Cancel).
struct MoreTextButton: View {
    let title: String
    var id: String?
    var color = Ink.tertiary
    var size: CGFloat = 13
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.ui(size)).foregroundStyle(color).contentShape(Rectangle()) }
            .buttonStyle(.plain).probe(id ?? title, action: action)
    }
}

/// A one-line field in the look of the renders (grey well, rounded).
struct MoreField: View {
    let prompt: String
    @Binding var text: String
    let id: String
    let submit: () -> Void
    var body: some View {
        TextField(prompt, text: $text).textFieldStyle(.plain).font(.ui(14)).studioDictatable($text)
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.bubble))
            .onSubmit(submit)
            .probeField(id, text: $text, submit: submit)
    }
}

// MARK: dates

/// The engine's `YYYY-MM-DD` dates, read and shown in the renders' short form ("Nov 6").
enum MoreDate {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = posix; f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = posix; f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "2026-12-01" -> "Dec 1"; anything else is shown as written.
    static func short(_ s: String?) -> String {
        guard let s else { return "" }
        return parse(s).map { format($0, "MMM d") } ?? s
    }

    static func day(_ d: Date) -> String { format(d, "yyyy-MM-dd") }

    /// Monday to Sunday of the week holding `now`.
    static func week(of now: Date = AppClock.today) -> [Date] {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
