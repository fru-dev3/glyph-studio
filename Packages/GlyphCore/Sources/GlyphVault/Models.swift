import Foundation
#if os(macOS)
import SystemConfiguration
#endif

/// `meta.json`: one conversation. Its id is its path in the vault, like
/// `Work/Acme/2026-10-20-weekly-sync`.
public struct Conversation: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var id: String
    public var title: String
    /// ISO 8601, UTC.
    public var created: String
    public var durationSec: Int = 0
    public var people: [String] = []
    public var accounts: [String] = []
    public var tags: [String] = []
    /// Glyph Bot objects this capture is filed under, by id: `person/<slug>`, `org/<slug>`
    /// (an Org), `mission/<slug>` (a Project) or `domain/<slug>`. Left out of meta.json when
    /// empty. `people` and `accounts` are the names older vaults used; they move here.
    public var links: [String] = []
    /// Guesses waiting for a yes; they count for nothing until confirmed.
    public var suggested = Suggested()
    public var source = "recording"
    /// The machine it was captured on ("Studio Laptop", "Office Desktop"): where a capture came
    /// from is part of its context. Missing in files written before 2026-10-25.
    public var device: String?
    public var calendarEventId: String?
    public var audio = "audio.m4a"
    public var updated: String?
    /// Stretches where you jotted during the recording (held the talk key): private, kept out
    /// of the transcript and the summary. Left out of meta.json when empty.
    public var jots: [Jot] = []

    enum CodingKeys: String, CodingKey {
        case schema, id, title, created, people, accounts, tags, links, suggested, source, device, audio, updated, jots
        case durationSec = "duration_sec"
        case calendarEventId = "calendar_event_id"
    }

    public init(id: String, title: String, created: String) {
        self.id = id
        self.title = title
        self.created = created
    }

    // Every field but id, title and created may be missing in a hand-written file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        created = try c.decode(String.self, forKey: .created)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec) ?? 0
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        accounts = try c.decodeIfPresent([String].self, forKey: .accounts) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        suggested = try c.decodeIfPresent(Suggested.self, forKey: .suggested) ?? Suggested()
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "recording"
        device = try c.decodeIfPresent(String.self, forKey: .device)
        calendarEventId = try c.decodeIfPresent(String.self, forKey: .calendarEventId)
        audio = try c.decodeIfPresent(String.self, forKey: .audio) ?? "audio.m4a"
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        jots = try c.decodeIfPresent([Jot].self, forKey: .jots) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(created, forKey: .created)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(people, forKey: .people)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(tags, forKey: .tags)
        if !links.isEmpty { try c.encode(links, forKey: .links) }
        if !suggested.isEmpty { try c.encode(suggested, forKey: .suggested) }
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encodeIfPresent(calendarEventId, forKey: .calendarEventId)
        try c.encode(audio, forKey: .audio)
        try c.encodeIfPresent(updated, forKey: .updated)
        if !jots.isEmpty { try c.encode(jots, forKey: .jots) }
    }
}

/// A private stretch of a recording: you held the talk key, so what you said went into
/// another app ("dictate") or a note ("thought"), not into the conversation. Seconds on the
/// recording's clock (pauses left out). `note` is the saved note's file name, for a thought.
public struct Jot: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var kind: String
    public var note: String?

    public init(start: Double, end: Double, kind: String, note: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.note = note
    }
}

public struct Suggested: Codable, Equatable, Sendable {
    /// Glyph Bot objects the call names, by id.
    public var links: [String] = []
    /// Names said in the call with no Studio page yet (a yes makes one).
    public var people: [String] = []
    public var accounts: [String] = []
    public var tags: [String] = []
    /// Every "no", so a guess never comes back.
    public var dismissed: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        accounts = try c.decodeIfPresent([String].self, forKey: .accounts) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        dismissed = try c.decodeIfPresent([String].self, forKey: .dismissed) ?? []
    }

    public var isEmpty: Bool { links.isEmpty && people.isEmpty && accounts.isEmpty && tags.isEmpty && dismissed.isEmpty }
}

/// `transcript.json`.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speaker: String
        public var text: String

        public init(start: Double, end: Double, speaker: String = "", text: String) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.text = text
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
            text = try c.decode(String.self, forKey: .text)
        }
    }

    public var schema = 1
    public var language = ""
    public var model = ""
    public var speakers: [String: String] = [:]
    public var segments: [Segment] = []

    public init() {}

    public init(language: String, model: String, speakers: [String: String] = [:], segments: [Segment]) {
        self.language = language
        self.model = model
        self.speakers = speakers
        self.segments = segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        speakers = try c.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }

    /// The transcript without what was said while jotting. A segment goes when a jot covers a
    /// second of it or half of it (each jot widened by `pad` for the key press): private
    /// first, so a sentence half-jotted is dropped whole.
    public func excluding(_ jots: [Jot], pad: Double = 0.4) -> Transcript {
        guard !jots.isEmpty else { return self }
        var out = self
        out.segments = segments.filter { s in
            let length = max(s.end - s.start, 0.01)
            return !jots.contains { j in
                let overlap = min(s.end, j.end + pad) - max(s.start, j.start - pad)
                return overlap > 0 && (overlap >= 1 || overlap / length >= 0.5)
            }
        }
        return out
    }

    /// `transcript.txt`: `[mm:ss] Speaker: text`, one line per segment.
    public var plainText: String {
        segments.map { s in
            let t = Int(s.start)
            let clock = String(format: "[%02d:%02d]", t / 60, t % 60)
            let who = s.speaker.isEmpty ? "" : name(of: s.speaker)
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return who.isEmpty ? "\(clock) \(text)\n" : "\(clock) \(who): \(text)\n"
        }.joined()
    }
}

/// An action item: a checkbox line in `notes.md`.
public struct ActionItem: Equatable, Sendable {
    public var text: String
    public var done: Bool
    public var owner: String?
    public var due: String?

    public init(text: String, done: Bool = false, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.done = done
        self.owner = owner
        self.due = due
    }

    /// `- [ ] text  <!-- owner: X; due: YYYY-MM-DD -->`, the comment only when there is metadata.
    public var markdownLine: String {
        let meta = [owner.map { "owner: \($0)" }, due.map { "due: \($0)" }].compactMap { $0 }
        let line = "- \(done ? "[x]" : "[ ]") \(text)"
        return meta.isEmpty ? line + "\n" : line + "  <!-- \(meta.joined(separator: "; ")) -->\n"
    }
}

/// What `notes.md` says, read leniently: a `## Summary`, `## Decisions` and
/// `## Action items` (or `## Actions`) section, any front matter ignored.
public struct Notes: Equatable, Sendable {
    public var summary = ""
    public var decisions: [String] = []
    public var actions: [ActionItem] = []
    public var markdown = ""

    public init() {}

    public init(summary: String, decisions: [String] = [], actions: [ActionItem] = []) {
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
    }

    /// `notes.md` with front matter, as Memosa writes it. `date` is `YYYY-MM-DD`.
    /// Decisions appear only when there are some; Summary and Action items always do.
    /// `entities`: the Glyph CRM ids the recording is filed under, the same key a note carries.
    public func rendered(title: String, date: String, people: [String], tags: [String], entities: [String] = []) -> String {
        var out = "---\ntitle: \(title)\ndate: \(date)\npeople: [\(people.joined(separator: ", "))]\ntags: [\(tags.joined(separator: ", "))]\n"
        if !entities.isEmpty { out += "entities: [\(entities.joined(separator: ", "))]\n" }
        out += "---\n\n"
        out += "## Summary\n" + summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        if !decisions.isEmpty {
            out += "## Decisions\n" + decisions.map { "- \($0)\n" }.joined() + "\n"
        }
        return out + "## Action items\n" + actions.map(\.markdownLine).joined()
    }

    /// Flips the first checkbox line containing `text`, leaving every other byte as it was.
    /// Nil when no such line exists.
    static func toggling(_ md: String, text: String, done: Bool) -> String? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = md.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { line in
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            return ["- [ ]", "- [x]", "- [X]"].contains(where: { t.hasPrefix($0) }) && line.contains(needle)
        }), let box = ["[ ]", "[x]", "[X]"].compactMap({ lines[i].range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        lines[i].replaceSubrange(box, with: done ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }

    public init(markdown md: String) {
        markdown = md
        var section = ""
        for line in Notes.stripFrontMatter(md).components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                section = t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            switch section {
            case "summary":
                if !t.isEmpty { summary += (summary.isEmpty ? "" : " ") + t }
            case "decisions":
                if let item = Notes.bullet(t) { decisions.append(item) }
            case "action items", "actions":
                if let task = Notes.task(t) { actions.append(task) }
            default:
                break
            }
        }
    }

    static func stripFrontMatter(_ md: String) -> String {
        guard md.hasPrefix("---\n") else { return md }
        let rest = md.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return md }
        return String(rest[end.upperBound...].drop(while: { $0 == "\n" }))
    }

    static func bullet(_ line: String) -> String? {
        for p in ["- ", "* "] where line.hasPrefix(p) {
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func task(_ line: String) -> ActionItem? {
        let t = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard ["- [ ]", "- [x]", "- [X]"].contains(where: { t.hasPrefix($0) }) else { return nil }
        let rest = t.dropFirst(5)
        var item = ActionItem(text: rest.trimmingCharacters(in: .whitespaces), done: !t.hasPrefix("- [ ]"))
        if let r = rest.range(of: "<!--") {
            item.text = rest[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let inner = rest[r.upperBound...].replacingOccurrences(of: "-->", with: "")
            for pair in inner.split(separator: ";") {
                let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, !kv[1].isEmpty else { continue }
                if kv[0] == "owner" { item.owner = kv[1] }
                if kv[0] == "due" { item.due = kv[1] }
            }
        }
        return item
    }
}

/// What a capture links to: a Glyph Bot object by id (`object`), a topic tag, or a name
/// with no Studio page yet (`person`, a suggestion). `account` is the older vault's name list.
public enum Link: Hashable, Sendable {
    case person(String), account(String), tag(String), object(String)

    public var name: String {
        switch self { case .person(let n), .account(let n), .tag(let n), .object(let n): n }
    }
}

/// An action item and the conversation it belongs to.
public struct VaultTask: Equatable, Sendable {
    /// The conversation's id.
    public var conversation: String
    /// The conversation's title.
    public var title: String
    public var item: ActionItem
}

/// This machine's name as its owner set it (System Settings > General > Sharing), e.g.
/// "Studio Laptop": stamped on every capture so its source is never lost.
public enum ThisDevice {
    public static var name: String {
        #if os(macOS)
        // Not Host.current(): it can wait on the network for seconds.
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}
