import Foundation
import Observation
import SwiftUI

/// Everything the window shows. One window: the team rail on the left, one place on the right.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    /// The places on the right. The chief of staff (Ben) is the vault's General domain, as in VAULT.md.
    enum Route: Hashable {
        case chat(String)               // a teammate's conversation; "general" is the chief of staff
        case team                       // the whole team at once: what each is for and doing now
        case needsYou                   // everything waiting on a yes or an answer
        case weekly                     // the chief of staff's weekly note
        case sources(String?)           // the vault and the Glyph apps agents read (one open, or all)
        case newTeammate
        case role(String)               // a teammate's routines and tools
        case watch(String)              // watch a teammate work
        case decisions
        case settings
    }
    enum RailTab: String, CaseIterable { case all = "All", needsYou = "Needs you", sources = "Sources" }

    var route: Route = .chat(AppModel.chiefID)
    var tab: RailTab = .all
    var searching = false
    /// A message waiting to be sent when a teammate's chat opens (the interview hand-off, "Ask about this").
    var outbox: [String: String] = [:]

    nonisolated static let defaultChiefName = "Ben"
    var chiefName = defaultChiefName
    var team: [Teammate] = []
    var waiting: [WaitingItem] = []
    var problem: String?
    var loaded = false

    nonisolated static let chiefID = "general"

    var needsYouCount: Int { waiting.count }
    var chief: Teammate? { team.first { $0.id == Self.chiefID } }
    func teammate(_ id: String) -> Teammate? { team.first { $0.id == id } }

    init() {
        if let r = Engine.env["STUDIO_ROUTE"] { route = Self.parse(r); tab = Self.tab(for: route, current: tab) }
        if let t = Engine.env["STUDIO_TAB"], let tab = RailTab(rawValue: t) { self.tab = tab }
    }

    /// The rail follows where you are: a board shows the Boards tab, Needs you its own tab, a
    /// teammate's places the team (unless you are already filtering to Needs you).
    static func tab(for r: Route, current: RailTab) -> RailTab {
        switch r {
        case .sources, .decisions: return .sources
        case .needsYou: return .needsYou
        case .settings, .newTeammate: return current
        default: return current == .sources ? .all : current
        }
    }

    /// Where you were before the current place (Settings' Done goes back there).
    var previous: Route?
    func go(_ r: Route) {
        if r != route { previous = route }
        route = r
        tab = Self.tab(for: r, current: tab)
    }

    /// Reloads the team, the chief of staff's name and what is waiting.
    func refresh() async {
        do {
            try Vault.prepare()
            PhoneLink.shared.sync()
            async let domains = Engine.json(["domains"], as: [EngineDomain].self)
            async let chief = Engine.json(["chief", "show"], as: ChiefShow.self)
            async let wait = Engine.json(["waiting"], as: Waiting.self)
            let (d, c, w) = try await (domains, chief, wait)
            chiefName = c.name?.nonEmpty ?? "Ben"
            waiting = w.items
            team = Teammate.build(domains: d, chiefName: chiefName, waiting: w.items)
            problem = nil
            print("team loaded \(team.count)"); fflush(stdout)
        } catch {
            // the owner's invariant, 2026-10-31: "if I take away the vault, then none of these apps should
            // work." A failed read means nothing on screen can be vouched for, so the snapshot goes
            // rather than sitting there looking live. Studio is the most exposed app in the family to
            // this, because what it holds it also hands to agents as context.
            problem = error.localizedDescription
            team = []
            waiting = []
            chiefName = Self.defaultChiefName
        }
        loaded = true
    }

    /// "life", "domain:wealth", "goal:estate:g-1", "chat:tax", "role:wealth", "watch:wealth", "needs-you", ...
    static func parse(_ s: String) -> Route {
        let p = s.split(separator: ":").map(String.init)
        switch p.first ?? "" {
        case "chat": return .chat(p.count > 1 ? p[1] : chiefID)
        case "team": return .team
        case "needs-you": return .needsYou
        case "weekly": return .weekly
        case "sources": return .sources(p.count > 1 ? p[1] : nil)
        case "new-teammate": return .newTeammate
        case "role": return .role(p.count > 1 ? p[1] : "wealth")
        case "watch": return .watch(p.count > 1 ? p[1] : "wealth")
        case "decisions": return .decisions
        case "settings": return .settings
        default: return .chat(chiefID)
        }
    }
}

/// A row of `prevail domains --json`.
struct EngineDomain: Decodable, Hashable {
    var name: String
    var path: String
    var label: String?
    var summary: String?
}

/// `prevail chief show --json`.
struct ChiefShow: Decodable { var name: String? }

/// A teammate: a domain with a look, or the chief of staff.
struct Teammate: Identifiable, Hashable {
    var id: String
    var name: String
    var look: Look
    var last: String
    var time: String
    var needsYou: Bool

    /// Default looks per domain; a domain's agent.md frontmatter may set its own (color, shape, icon).
    /// Green and grey (the owner, 2026-11-07): the accent belongs to the one who runs the team, so no
    /// domain agent may hold it. These were eight saturated hues, and `wealth` was office green
    /// itself, which put a second tile in the rail wearing the lead's mark. Shape and glyph are what
    /// tell the agents apart.
    static let defaults: [String: Look] = [
        "general": Look(shape: .squircle, color: 0x008000, glyph: "figure"),
        "estate": Look(shape: .leaf, color: 0x2C2C2E, glyph: "house"),
        "tax": Look(shape: .squircle, color: 0x3A3A3C, glyph: "doc.text"),
        "wealth": Look(shape: .circle, color: 0x48484C, glyph: "chart.bar"),
        "career": Look(shape: .circle, color: 0x56565B, glyph: "chart.line.uptrend.xyaxis"),
        "health": Look(shape: .leaf, color: 0x6E6E73, glyph: "heart"),
        "business": Look(shape: .squircle, color: 0x2C2C2E, glyph: "briefcase"),
        "family": Look(shape: .drop, color: 0x3A3A3C, glyph: "person.2"),
        "inbox": Look(shape: .squircle, color: 0x48484C, glyph: "line.3.horizontal"),
    ]
    /// agent.md `icon:` keys to SF Symbols.
    static let icons: [String: String] = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0.value.glyph) })
        .merging(["ben": "figure", "chief": "figure", "research": "magnifyingglass"]) { a, _ in a }

    static func look(for slug: String) -> Look {
        // A domain with no default of its own takes a grey, never the accent: `Look.palette` leads
        // with office green and that one is the lead's alone.
        let greys = Array(Look.palette.dropFirst())
        let pick = greys[abs(slug.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % greys.count]
        var look = defaults[slug] ?? Look(shape: .squircle, color: pick, glyph: "circle.grid.2x2")
        let fm = Frontmatter.read(Vault.domain(slug).appending(path: "agent.md"))
        if let c = fm["color"], let v = UInt32(c.trimmingCharacters(in: CharacterSet(charactersIn: "#\" ")), radix: 16) { look.color = Look.settled(v) }
        if let sh = fm["shape"] { look.shape = Look.Shape(css: sh) ?? look.shape }
        if let i = fm["icon"] { look.glyph = icons[i] ?? (i.contains(".") ? i : look.glyph) }
        return look
    }

    /// The chief of staff first, then teammates with something waiting, then the rest by name.
    static func build(domains: [EngineDomain], chiefName: String, waiting: [WaitingItem]) -> [Teammate] {
        let waitingBy = Dictionary(grouping: waiting, by: { $0.domain ?? AppModel.chiefID })
        var team: [Teammate] = domains.map { d in
            let isChief = d.name == AppModel.chiefID
            let w = waitingBy[d.name]?.first
            let (last, time) = TeamActivity.latest(for: d.name)
            return Teammate(id: d.name, name: isChief ? chiefName : Sources.label(d.label?.nonEmpty.flatMap { $0 == d.name ? nil : $0 } ?? d.name),
                            look: look(for: d.name), last: last.nonEmpty ?? w?.summary ?? "", time: time, needsYou: w != nil)
        }
        if !team.contains(where: { $0.id == AppModel.chiefID }) {
            team.append(Teammate(id: AppModel.chiefID, name: chiefName, look: look(for: AppModel.chiefID), last: "", time: "", needsYou: false))
        }
        // Like a messages app: the chief of staff first, then whoever spoke last.
        return team.sorted { a, b in
            if a.id == AppModel.chiefID { return true }
            if b.id == AppModel.chiefID { return false }
            let ka = TeamActivity.recency(a.time), kb = TeamActivity.recency(b.time)
            return ka != kb ? ka > kb : a.name < b.name
        }
    }
}

/// The latest thing a teammate said or did, for its row in the rail: the last assistant line of its
/// newest thread, else the first line of its state. Times are relative ("9:46 PM", "Yesterday").
enum TeamActivity {
    /// A row's preview: the latest real thing the agent said, cleaned (no markdown marks, no
    /// housekeeping like "_Consolidated 2026-07-04. Prior state...", no paths or ids), else the first
    /// human line of its state, else its purpose. the owner: no underscores or file paths in the list.
    static func latest(for slug: String) -> (String, String) {
        let dir = Vault.domain(slug)
        // memory/state.md may carry "Last message: <text> (<time>)", written by the teammate.
        if let state = Vault.read(dir.appending(path: "memory/state.md")),
           let line = state.split(separator: "\n").first(where: { $0.hasPrefix("Last message:") }) {
            var text = line.dropFirst("Last message:".count).trimmingCharacters(in: .whitespaces)
            var time = ""
            if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
                time = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                text = text[..<open].trimmingCharacters(in: .whitespaces)
            }
            if let clean = Preview.clean(text) { return (clean, time) }
        }
        if let newest = Threads.newest(slug), let text = Vault.read(newest), let line = lastAssistantLine(text, jsonl: true) {
            return (line, stamp(modified(newest)))
        }
        let state = dir.appending(path: "memory/state.md")
        if let text = Vault.read(state), let line = Preview.first(in: Markdown.body(text)) {
            return (line, stamp(modified(state)))
        }
        let purpose = IntentStore(root: Vault.root).contract(slug).purpose
        return (Preview.clean(purpose) ?? "", "")
    }

    static func lastAssistantLine(_ text: String, jsonl: Bool) -> String? {
        if jsonl {
            for raw in text.split(separator: "\n").reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      (obj["role"] as? String) == "assistant", let c = obj["content"] as? String,
                      let s = Preview.first(in: Turn.saves(in: c).text) else { continue }
                return s
            }
            return nil
        }
        return text.split(separator: "\n").reversed().map(String.init).first { Preview.clean($0) != nil }.flatMap { Preview.clean($0) }
    }

    static func firstSentence(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        if let r = one.range(of: ". ") { return String(one[..<r.lowerBound]) + "." }
        return one
    }

    /// Sort key for a display time: today's clock times first (later is larger), then Yesterday, then weekdays.
    static func recency(_ t: String) -> Double {
        if t.isEmpty { return -10_000 }
        if t == "Yesterday" { return -1_000 }
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        if let i = days.firstIndex(of: t) {
            let today = Calendar.current.component(.weekday, from: AppClock.now) - 1
            return -1_000 - Double((today - i + 7) % 7) * 100
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
        if let d = f.date(from: t) { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) }
        return -5_000
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func stamp(_ date: Date, now: Date = AppClock.now) -> String {
        if date == .distantPast { return "" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if now.timeIntervalSince(date) < 6 * 86400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

typealias Waiting = Feeds.Waiting
typealias WaitingItem = Feeds.Waiting.Item
extension Feeds.Waiting.Item: Identifiable {}

extension Look.Shape {
    /// The CSS radius the demo vault uses ("50%", "14px", "10px 22px 22px 22px", "22px 22px 22px 8px") or a name.
    init?(css: String) {
        let v = css.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let s = Look.Shape(rawValue: v) { self = s; return }
        switch v {
        case "50%": self = .circle
        case let x where x.split(separator: " ").count == 4:
            let p = x.split(separator: " ")
            self = p[0] < p[1] ? .leaf : .drop
        case let x where x.hasSuffix("px"): self = (Double(x.dropLast(2)) ?? 14) <= 6 ? .square : .squircle
        default: return nil
        }
    }
}

/// Reads a markdown file's YAML-ish frontmatter as flat key: value strings (lists stay as written).
enum Frontmatter {
    static func read(_ url: URL) -> [String: String] {
        guard let text = Vault.read(url), text.hasPrefix("---") else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("---") { break }
            guard let c = line.firstIndex(of: ":") else { continue }
            out[String(line[..<c]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}


/// A preview line a person would write: markdown marks gone, housekeeping skipped.
enum Preview {
    /// Notes the system writes for itself, never shown as a preview.
    static let housekeeping = ["consolidated", "prior state", "new domain", "migrated", "auto-generated", "generated by",
                               "last updated", "updated:", "schema", "frontmatter", "injected into", "do not edit", "todo:", "placeholder",
                               "claude max", "medium effort", "high effort", "autostate", "manifest", "hand-maintained", "remote-control"]

    /// One cleaned line, or nil if there's nothing human in it.
    static func clean(_ raw: String) -> String? {
        var s = undash(raw).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("---"), !s.hasPrefix("```"), !s.hasPrefix("|") else { return nil }
        // Terminal scrapes from a harness (box drawing, spinners) are not messages.
        if s.unicodeScalars.contains(where: { (0x2500...0x259F).contains($0.value) || $0.value == 0x2733 }) { return nil }
        // Claude Code's terminal marks: "❯ ..." echoes a prompt; "⏺ ..." is its text, or a tool call.
        if s.hasPrefix("❯") || s.hasPrefix("⎿") { return nil }
        if s.hasPrefix("⏺") || s.hasPrefix("●") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if s.range(of: #"^[A-Z][\w ]*\("#, options: .regularExpression) != nil { return nil }
        }
        if let r = s.range(of: #"^\d+\s+(?=[#|>])"#, options: .regularExpression) { s.removeSubrange(r) } // a file view's line number
        if s.hasSuffix(":") { return nil } // a lead-in ("Work the way these specialists would:"), not the message
        while let f = s.first, "#>-*+".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if let r = s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression) // [text](link)
        s = s.replacingOccurrences(of: #"\[\[([^\]|]+)(\|[^\]]*)?\]\]"#, with: "$1", options: .regularExpression) // [[wiki]]
        for mark in ["**", "__", "`", "~~"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = s.replacingOccurrences(of: #"(^|\s)[_*]([^_*]+)[_*](?=\s|[.,;:!?]|$)"#, with: "$1$2", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " _*"))
        let lower = s.lowercased()
        guard s.count >= 8, s.contains(" "), !housekeeping.contains(where: { lower.contains($0) }) else { return nil }
        // Tool tallies ("Ran 5 shell commands") and dated log lines ("2026-08-03 - ...") are bookkeeping.
        if s.range(of: #"^(Ran|Listed|Read|Edited|Searched|Wrote|Opened|Fetched)\s+\d+\s"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return nil }
        // Paths, files and ids read as noise.
        if s.range(of: #"(^|\s)(~|\.{0,2})/[\w.-]+/|\b[\w-]+\.(md|jsonl?|txt|yaml|yml|csv)\b|\b[0-9a-f]{12,}\b"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"^[\w]+( [\w]+){0,2}:\s"#, options: .regularExpression) != nil { return nil } // "Task name: ...", a field, not a message
        return firstSentence(s)
    }

    /// Em dashes (and spaced en dashes) read as commas: no dashes in what Studio shows.
    static func undash(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\x{2014}\s*|\s+\x{2013}\s+"#, with: ", ", options: .regularExpression)
    }

    /// The first human line of a text.
    static func first(in text: String) -> String? {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") { if let c = clean(String(line)) { return c } } // headings name, they don't say
        return nil
    }

    static func firstSentence(_ s: String) -> String {
        if let r = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression), s.distance(from: s.startIndex, to: r.lowerBound) >= 12 {
            return String(s[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
