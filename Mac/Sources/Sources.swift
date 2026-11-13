import Foundation
import GlyphVault

/// What agents read: the vault itself, and each Glyph app's files inside it. Every app writes plain
/// files to the vault (Glyph Well, Time, Jot, CRM, Omega); Studio only reads them, here, and hands the
/// agent numbered excerpts it can cite ([1], [2]). Nothing in this file writes to the vault.
enum SourceID: String, CaseIterable, Codable, Hashable, Identifiable {
    case vault, well, time, jot, entities, omega
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vault: "Vault"
        case .well: "Glyph Well"
        case .time: "Glyph Time"
        case .jot: "Glyph Jot"
        case .entities: "Glyph CRM"
        case .omega: "Glyph Omega"
        }
    }
    /// The short name on a chip.
    var chip: String {
        switch self {
        case .vault: "Vault"
        case .well: "Well"
        case .time: "Time"
        case .jot: "Jot"
        case .entities: "People and things"
        case .omega: "Goals"
        }
    }
    var symbol: String {
        switch self {
        case .vault: "externaldrive"
        case .well: "heart.text.square"
        case .time: "timer"
        case .jot: "text.quote"
        case .entities: "person.2"
        case .omega: "scope"
        }
    }
    var blurb: String {
        switch self {
        case .vault: "Your domains: their state, memory and open tasks. Glyph Bot needs it."
        case .well: "Symptoms, mood, sleep, food, labs and wearable days."
        case .time: "Hours by project from every device."
        case .jot: "Your notes and thoughts, as you said them."
        case .entities: "People, places, products and things, with your notes on each."
        case .omega: "Your mission, vision, values and the goals of each domain."
        }
    }
    /// Where the source lives in the vault.
    var folder: String {
        switch self {
        case .vault: "data/domains"
        case .well: "data/apps/well/entries"
        case .time: "data/apps/time/sessions"
        case .jot: "data/domains/notes/source/jot"
        case .entities: "data/entities"
        case .omega: "build/compass.md"
        }
    }
    /// Words that pull this source into a question on its own.
    var cues: [String] {
        switch self {
        case .vault: []
        case .well: ["sleep", "slept", "symptom", "pain", "headache", "mood", "energy", "food", "ate", "eat", "flare", "health",
                     "well", "lab", "labs", "med", "meds", "medication", "stress", "hrv", "steps", "trigger", "tired", "fatigue"]
        case .time: ["hours", "hour", "time", "spent", "worked", "working", "week", "today", "focus", "project", "projects", "timer"]
        case .jot: ["note", "notes", "jot", "jotted", "idea", "ideas", "said", "thought", "thoughts", "wrote", "memo", "dictated"]
        case .entities: []
        case .omega: ["goal", "goals", "mission", "vision", "values", "value", "ambition", "priority", "priorities", "focus", "why", "purpose"]
        }
    }
    /// The domain agents that read this source by default.
    var homeDomains: Set<String> {
        switch self {
        case .vault: []
        case .well: ["health", "wellness", "well"]
        case .time: ["time", "productivity", "career", "dev"]
        case .jot: ["notes", "general"]
        case .entities: ["crm", "family"]
        case .omega: ["general", "omega", "goals"]
        }
    }
}

/// One numbered thing an agent read for a turn.
struct SourceExcerpt: Identifiable, Hashable, Codable {
    var n: Int
    var source: SourceID
    var title: String
    /// Relative to the vault root.
    var path: String
    var text: String
    var id: Int { n }
}

/// How a source stands right now.
struct SourceStatus: Equatable {
    enum State: String { case connected, empty, missing }
    var id: SourceID
    var state: State
    var detail: String
    var count: Int
    var last: Date?
    var folder: URL
}

enum Sources {
    // MARK: which sources agents may read (Studio's own setting, not the vault's)

    static var settingsFile: URL { StudioPaths.support.appending(path: "sources.json") }

    /// Every source is on until turned off. The vault cannot be turned off.
    static func enabled() -> Set<SourceID> {
        guard let data = try? Data(contentsOf: settingsFile),
              let off = try? JSONDecoder().decode([String: Bool].self, from: data) else { return Set(SourceID.allCases) }
        return Set(SourceID.allCases.filter { $0 == .vault || off[$0.rawValue] != false })
    }

    static func set(_ id: SourceID, on: Bool) {
        guard id != .vault else { return }
        var map = (try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: settingsFile))) ?? [:]
        map[id.rawValue] = on
        try? FileManager.default.createDirectory(at: StudioPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(map).write(to: settingsFile, options: .atomic)
    }

    // MARK: status

    static func status(_ id: SourceID, root: URL = Vault.root, now: Date = .now) -> SourceStatus {
        let folder = root.appending(path: id.folder)
        let fm = FileManager.default
        func newest(_ urls: [URL]) -> Date? { urls.compactMap { modified($0) }.max() }
        switch id {
        case .vault:
            let domains = domainSlugs(root)
            guard fm.fileExists(atPath: root.appending(path: "data").path) else {
                return SourceStatus(id: id, state: .missing, detail: "No vault at this path", count: 0, last: nil, folder: root)
            }
            return SourceStatus(id: id, state: domains.isEmpty ? .empty : .connected,
                                detail: domains.isEmpty ? "No domains yet" : "\(domains.count) \(domains.count == 1 ? "domain" : "domains")", count: domains.count,
                                last: newest(domains.map { root.appending(path: "data/domains/\($0)") }), folder: root)
        case .well:
            let rows = WellReader.entries(folder)
            guard fm.fileExists(atPath: folder.path) else { return missing(id, folder, "Glyph Well hasn't written here yet") }
            let last = rows.map(\.at).max()
            return SourceStatus(id: id, state: rows.isEmpty ? .empty : .connected,
                                detail: rows.isEmpty ? "No entries yet" : "\(rows.count) entries" + (last.map { ", latest \(when($0, now: now))" } ?? ""),
                                count: rows.count, last: last, folder: folder)
        case .time:
            guard fm.fileExists(atPath: folder.path) else { return missing(id, folder, "Glyph Time hasn't written here yet") }
            let sessions = TimeLog.sessions(TimeLog.read(folder, months: TimeLog.recentMonths(now)))
            let week = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            let hours = TimeLog.totals(sessions, from: week, to: now.addingTimeInterval(1), now: now).reduce(0) { $0 + $1.seconds }
            let last = sessions.map { $0.end ?? now }.max()
            return SourceStatus(id: id, state: sessions.isEmpty ? .empty : .connected,
                                detail: sessions.isEmpty ? "No sessions this month" : "\(TimeLog.span(hours)) in the last 7 days" + (last.map { ", latest \(when($0, now: now))" } ?? ""),
                                count: sessions.count, last: last, folder: folder)
        case .jot:
            guard fm.fileExists(atPath: folder.path) else { return missing(id, folder, "Glyph Jot hasn't written here yet") }
            let notes = jotNotes(folder)
            // A note's name is when it was said ("2026-10-27 09-00-00.md"); the file date is when it synced.
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let last = notes.compactMap { f.date(from: $0.deletingPathExtension().lastPathComponent) }.max() ?? newest(notes)
            return SourceStatus(id: id, state: notes.isEmpty ? .empty : .connected,
                                detail: notes.isEmpty ? "No notes yet" : "\(notes.count) notes" + (last.map { ", latest \(when($0, now: now))" } ?? ""),
                                count: notes.count, last: last, folder: folder)
        case .entities:
            guard fm.fileExists(atPath: folder.path) else { return missing(id, folder, "No people or things yet") }
            let all = EntityReader.all(root)
            let byKind = Dictionary(grouping: all, by: \.kind)
            let words = EntityReader.kinds.compactMap { k -> String? in
                guard let n = byKind[k.dir]?.count, n > 0 else { return nil }
                return "\(n) \(n == 1 ? k.one : k.many)"
            }
            return SourceStatus(id: id, state: all.isEmpty ? .empty : .connected,
                                detail: all.isEmpty ? "No people or things yet" : words.joined(separator: ", "),
                                count: all.count, last: newest(all.map(\.file)), folder: folder)
        case .omega:
            // The compass (build/compass.md) and each domain's goals (source/goals.md), as Glyph Omega keeps them.
            let goals = omegaGoals(root)
            guard fm.fileExists(atPath: folder.path) || !goals.isEmpty else { return missing(id, folder, "Glyph Omega hasn't written here yet") }
            let parts = (fm.fileExists(atPath: folder.path) ? ["compass"] : []) + (goals.isEmpty ? [] : ["goals in \(goals.count) \(goals.count == 1 ? "domain" : "domains")"])
            return SourceStatus(id: id, state: .connected, detail: parts.joined(separator: ", "), count: goals.count,
                                last: newest(goals + [folder]), folder: folder)
        }
    }

    static func omegaGoals(_ root: URL) -> [URL] {
        domainSlugs(root).map { root.appending(path: "data/domains/\($0)/source/goals.md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func missing(_ id: SourceID, _ folder: URL, _ detail: String) -> SourceStatus {
        SourceStatus(id: id, state: .missing, detail: detail, count: 0, last: nil, folder: folder)
    }

    // MARK: choosing sources for a turn

    /// The app sources a question pulls in by itself: its words, the agent's home, names it mentions.
    static func relevant(_ message: String, agent: String, root: URL = Vault.root) -> Set<SourceID> {
        let words = Set(tokens(message))
        var out: Set<SourceID> = []
        for s in SourceID.allCases where s != .vault {
            if s.homeDomains.contains(agent) || !words.isDisjoint(with: s.cues) { out.insert(s) }
        }
        if !EntityReader.mentioned(in: message, root: root).isEmpty { out.insert(.entities) }
        return out
    }

    /// The numbered excerpts for one turn, from the vault (the agent's own domain) and each chosen app.
    static func excerpts(for message: String, agent: String, using chosen: Set<SourceID>, root: URL = Vault.root, now: Date = .now) -> [SourceExcerpt] {
        var out: [SourceExcerpt] = []
        func add(_ s: SourceID, _ title: String, _ url: URL, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            out.append(SourceExcerpt(n: out.count + 1, source: s, title: title, path: Vault.relative(url, root: root), text: String(t.prefix(1800))))
        }
        let allowed = enabled().intersection(chosen.union([.vault]))
        if allowed.contains(.vault) { for (title, url, text) in vaultExcerpts(agent: agent, root: root) { add(.vault, title, url, text) } }
        if allowed.contains(.well) {
            let folder = root.appending(path: SourceID.well.folder)
            add(.well, "Glyph Well, the last 14 days", folder, WellReader.digest(folder, now: now))
        }
        if allowed.contains(.time) {
            let folder = root.appending(path: SourceID.time.folder)
            let sessions = TimeLog.sessions(TimeLog.read(folder, months: TimeLog.recentMonths(now)))
            if !sessions.isEmpty { add(.time, "Glyph Time, hours by project", folder, TimeLog.summary(sessions, now: now)) }
        }
        if allowed.contains(.jot) {
            for url in jotPicks(message, folder: root.appending(path: SourceID.jot.folder)) {
                add(.jot, "Note, \(url.deletingPathExtension().lastPathComponent)", url, Markdown.body(Vault.read(url) ?? ""))
            }
        }
        if allowed.contains(.entities) {
            for e in EntityReader.mentioned(in: message, root: root).prefix(4) {
                add(.entities, e.name, e.file, EntityReader.excerpt(e))
            }
        }
        if allowed.contains(.omega) {
            let compass = root.appending(path: SourceID.omega.folder)
            if let t = Vault.read(compass) { add(.omega, "Glyph Omega, your compass", compass, Markdown.body(t)) }
            let goals = root.appending(path: "data/domains/\(agent)/source/goals.md")
            if agent != AppModel.chiefID, let t = Vault.read(goals) { add(.omega, "Glyph Omega, \(label(agent)) goals", goals, Markdown.body(t)) }
        }
        return out
    }

    /// The agent's own domain: its state, its memory and its open tasks. The chief of staff (general)
    /// reads who you are instead.
    static func vaultExcerpts(agent: String, root: URL) -> [(String, URL, String)] {
        if agent == AppModel.chiefID {
            let user = root.appending(path: "build/user.md")
            return Vault.read(user).map { [("Who you are", user, Markdown.body($0))] } ?? []
        }
        let dir = root.appending(path: "data/domains/\(agent)")
        var out: [(String, URL, String)] = []
        for name in ["memory/state.md", "_state.md"] {
            let u = dir.appending(path: name)
            if let t = Vault.read(u) { out.append(("\(label(agent)) state", u, Markdown.body(t))); break }
        }
        let v4 = dir.appending(path: "memory/tasks.md")
        let tasks = FileManager.default.fileExists(atPath: v4.path) ? v4 : dir.appending(path: "_tasks.md")
        if let t = Vault.read(tasks) {
            let open = t.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }.prefix(12)
            if !open.isEmpty { out.append(("\(label(agent)) open tasks", tasks, open.joined(separator: "\n"))) }
        }
        return out
    }

    // MARK: helpers

    static func domainSlugs(_ root: URL) -> [String] {
        let dir = root.appending(path: "data/domains")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && $0 != "build" }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: dir.appending(path: $0).path, isDirectory: &d) && d.boolValue }
            .sorted()
    }

    static func jotNotes(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
    }

    /// The notes that share the most words with the question; the newest when none do.
    static func jotPicks(_ message: String, folder: URL, limit: Int = 4) -> [URL] {
        let notes = jotNotes(folder).sorted { $0.lastPathComponent > $1.lastPathComponent }
        let want = Set(tokens(message)).subtracting(SourceID.jot.cues).filter { $0.count >= 4 }
        let scored = notes.prefix(400).map { u -> (URL, Int) in
            (u, want.isEmpty ? 0 : Set(tokens(Vault.read(u) ?? "")).intersection(want).count)
        }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        return Array((hits.isEmpty ? Array(notes) : hits).prefix(limit))
    }

    static let stop: Set<String> = ["the", "and", "for", "with", "what", "how", "did", "does", "was", "were", "this", "that", "my", "me",
                                     "you", "your", "about", "from", "have", "has", "had", "are", "is", "it", "of", "to", "in", "on", "a", "an", "i"]
    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
    }

    /// "real-estate" reads "Real Estate"; short acronyms stay capitals ("crm" reads "CRM"), never a slug.
    static func label(_ slug: String) -> String {
        let acronyms: Set<String> = ["crm", "ai", "llc", "hsa", "ira", "pto", "irs", "hr", "ui", "ux", "seo", "os"]
        return slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { acronyms.contains($0.lowercased()) ? $0.uppercased() : $0.capitalized }.joined(separator: " ")
    }

    static func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    /// "today 8:10 AM", "yesterday", "Oct 20".
    static func when(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today \(d.formatted(date: .omitted, time: .shortened))" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Glyph Well's lines (`data/apps/well/entries/<YYYY-MM>.<host>.jsonl`), read without Well's code so
/// Studio never depends on another app's build: the last line per id wins, deletes take one back.
enum WellReader {
    struct Entry: Equatable { var id: String; var at: Date; var kind: String; var name: String; var level: Int?; var detail: String }
    struct Day: Equatable { var date: String; var source: String; var text: String }

    static func lines(_ folder: URL) -> [[String: Any]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        return names.flatMap { n in
            (Vault.read(folder.appending(path: n)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func entries(_ folder: URL) -> [Entry] {
        var last: [String: [String: Any]] = [:]
        var order: [String] = []
        for l in lines(folder) {
            guard let ev = l["event"] as? String, ev == "log" || ev == "delete", let id = l["id"] as? String else { continue }
            if last[id] == nil { order.append(id) }
            last[id] = l
        }
        return order.compactMap { id -> Entry? in
            guard let l = last[id], l["event"] as? String == "log", let kind = l["kind"] as? String,
                  let at = date(l["at"]) ?? date(l["ts"]) else { return nil }
            var bits: [String] = []
            if let v = l["value"] as? Double { bits.append("\(v.formatted())\((l["unit"] as? String).map { " \($0)" } ?? "")") }
            if let hi = l["high"] as? Double, let v = l["value"] as? Double, v > hi { bits.append("high") }
            if let lo = l["low"] as? Double, let v = l["value"] as? Double, v < lo { bits.append("low") }
            if let a = l["area"] as? String { bits.append(a) }
            if let n = l["note"] as? String { bits.append(n) }
            return Entry(id: id, at: at, kind: kind, name: (l["name"] as? String) ?? kind, level: l["level"] as? Int, detail: bits.joined(separator: ", "))
        }.sorted { $0.at > $1.at }
    }

    static func days(_ folder: URL) -> [Day] {
        var last: [String: Day] = [:]
        for l in lines(folder) where l["event"] as? String == "day" {
            guard let d = l["date"] as? String, let src = l["source"] as? String else { continue }
            let parts: [(String, String)] = [("sleep", "h sleep"), ("hrv", " ms HRV"), ("rhr", " bpm resting"), ("steps", " steps"), ("stress", " stress"), ("workout", " min workout")]
            let text = parts.compactMap { k, u in (l[k] as? Double).map { "\($0.formatted(.number.precision(.fractionLength(0...1))))\(u)" } }.joined(separator: ", ")
            last[src + d] = Day(date: d, source: src, text: text)
        }
        return last.values.sorted { $0.date > $1.date }
    }

    /// Plain lines an agent reads: entries newest first, then the wearable days.
    static func digest(_ folder: URL, now: Date = .now, days back: Int = 14) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = entries(folder).filter { $0.at >= since }.prefix(60).map { e in
            "- \(f.string(from: e.at)) \(e.kind): \(e.name)\(e.level.map { " \($0)/10" } ?? "")\(e.detail.isEmpty ? "" : " (\(e.detail))")"
        }
        let dayCut = f.string(from: since).prefix(10)
        let ds = days(folder).filter { $0.date >= dayCut && !$0.text.isEmpty }.prefix(14).map { "- \($0.date) \($0.source): \($0.text)" }
        guard !rows.isEmpty || !ds.isEmpty else { return "" }
        return (rows.isEmpty ? "" : "Entries:\n" + rows.joined(separator: "\n")) + (ds.isEmpty ? "" : "\n\nWearable days:\n" + ds.joined(separator: "\n"))
    }
}

/// People, places, products and things (`data/entities/<kind>/<slug>/entity.md`, VAULT.md), the
/// pages Glyph CRM keeps. Read only.
enum EntityReader {
    struct Page: Equatable { var kind: String; var slug: String; var name: String; var aliases: [String]; var file: URL }
    static let kinds: [(dir: String, one: String, many: String)] = [("people", "person", "people"), ("places", "place", "places"), ("orgs", "product", "products"), ("things", "thing", "things")]

    // ponytail: one cached list for 20 s per vault, so typing doesn't re-read every page; a watcher if it ever lags.
    nonisolated(unsafe) private static var cache: (root: URL, at: Date, pages: [Page])?
    private static let lock = NSLock()

    static func all(_ root: URL) -> [Page] {
        if let c = lock.withLock({ cache }), c.root == root, Date.now.timeIntervalSince(c.at) < 20 { return c.pages }
        let pages = read(root)
        lock.withLock { cache = (root, .now, pages) }
        return pages
    }

    private static func read(_ root: URL) -> [Page] {
        let base = root.appending(path: "data/entities")
        let fm = FileManager.default
        return kinds.flatMap { k -> [Page] in
            let dir = base.appending(path: k.dir)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }.compactMap { item -> Page? in
                let folderPage = dir.appending(path: "\(item)/entity.md")
                let file = fm.fileExists(atPath: folderPage.path) ? folderPage : (item.hasSuffix(".md") ? dir.appending(path: item) : nil)
                guard let file else { return nil }
                let fmx = Frontmatter.read(file)
                let slug = item.hasSuffix(".md") ? String(item.dropLast(3)) : item
                let name = fmx["name"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).nonEmpty ?? slug.replacingOccurrences(of: "-", with: " ").capitalized
                let aliases = (fmx["aliases"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.filter { !$0.isEmpty }
                return Page(kind: k.dir, slug: slug, name: name, aliases: aliases, file: file)
            }
        }
    }

    /// Pages whose name or alias appears in the text as whole words (three letters or more).
    static func mentioned(in text: String, root: URL) -> [Page] {
        let hay = " " + text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.map(String.init).joined() + " "
        return all(root).filter { p in
            ([p.name] + p.aliases).contains { n in
                let w = n.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.map(String.init).joined()
                    .split(separator: " ").joined(separator: " ")
                return w.count >= 3 && hay.contains(" \(w) ")
            }
        }
    }

    /// The page's fields and the owner's own notes first, then what was discussed.
    static func excerpt(_ p: Page) -> String {
        let text = Vault.read(p.file) ?? ""
        let md = Markdown(text)
        let fields = Frontmatter.read(p.file).filter { !["created", "updated", "saved", "mention_count", "picture"].contains($0.key) }
            .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let notes = md.section("Your notes") ?? ""
        let discussed = md.section("What you've discussed") ?? ""
        return [fields, notes.isEmpty ? "" : "Your notes:\n\(notes)", discussed.isEmpty ? "" : "Discussed:\n\(discussed)"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

extension Markdown {
    /// Text without its frontmatter.
    static func body(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.hasPrefix("---") }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// The text under a `## name` heading, up to the next heading.
    func section(_ name: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let h = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(name.lowercased()) }) else { return nil }
        let rest = lines[(h + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
        return lines[(h + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}
