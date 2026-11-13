import Foundation

// The engine shapes the More screens read (checked against the installed engine on a demo vault copy),
// and the small vault parsers they need. Optional wherever the engine may leave a field out.

// MARK: entities

struct EntityList: Decodable {
    var counts: [String: Int]?
    var entities: [Entity]

    struct Entity: Decodable, Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        var domain: String?
        var mention_count: Int?
        var last_ts: Double?
    }

    /// "8 people · 4 products · 3 places · 2 things": counts by kind, the empty ones left out (people always shown).
    var summary: String {
        let order: [(String, String, String)] = [("person", "person", "people"), ("product", "product", "products"),
                                                 ("place", "place", "places"), ("thing", "thing", "things")]
        var by = Dictionary(grouping: entities, by: \.kind).mapValues(\.count)
        by["product", default: 0] += by["org"] ?? 0 // VAULT.md: Products are org pages (and apps)
        return order.compactMap { kind, one, many in
            let n = by[kind] ?? 0
            return n == 0 && kind != "person" ? nil : "\(n) \(n == 1 ? one : many)"
        }.joined(separator: " · ")
    }
}

struct EntityShow: Decodable {
    var id: String
    var name: String?
    var kind: String?
    var domain: String?
    var digest: String?
    var notes: String?
    var mentions: [Mention]?
    var page_path: String?

    struct Mention: Decodable, Hashable {
        var text: String?
        var snippet: String?
        var domain: String?
        var ts: Double?
        var line: String { (text ?? snippet ?? "").replacingOccurrences(of: "\n", with: " ") }
    }
}

struct EntityLinks: Decodable {
    var links: [Link]
    struct Link: Decodable, Hashable, Identifiable {
        var id: String
        var name: String?
        var kind: String?
        var role: String?
        var via: String?
    }
}

/// A person's page (data/entities/people/<slug>/entity.md) holds `role:` in its frontmatter.
enum EntityPage {
    static let folders = ["person": "people", "place": "places", "thing": "things", "event": "events", "org": "orgs", "product": "products"]

    static func url(_ id: String) -> URL? {
        let p = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard p.count == 2, let folder = folders[p[0]] else { return nil }
        return Vault.root.appending(path: "data/entities/\(folder)/\(p[1])/entity.md")
    }

    static func fields(_ id: String) -> [String: String] { url(id).map(Frontmatter.read) ?? [:] }

    /// `[a, b]` or `a` as a list.
    static func list(_ v: String?) -> [String] {
        guard let v else { return [] }
        return v.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
    }
}

// MARK: events

struct EventList: Decodable {
    var events: [Event]
    struct Event: Decodable, Hashable, Identifiable {
        var id: String
        var name: String
        var date: String
        var source: String?
        var has_page: Bool?
        var time: String?
        var project: Ref?
        var place: Ref?
        var done: Bool?
        var calendar: String?
    }
    struct Ref: Decodable, Hashable { var id: String; var name: String? }
}

// MARK: decisions

struct DecisionRecord: Decodable, Hashable, Identifiable {
    var slug: String
    var domain: String
    var question: String
    var status: String
    var due: String?
    var gut: String?
    var recommendation: String?
    var confidence: String?
    var decided: String?
    var chose: String?
    var retroDue: String?
    var sections: [String: String]?
    var recommendationReady: Bool?
    var id: String { "\(domain)/\(slug)" }

    /// The `## Options` bullets.
    var options: [String] {
        (sections?["Options"] ?? "").split(separator: "\n").compactMap { Markdown.bullet(String($0)) }
    }

    var isOpen: Bool { status != "decided" }
}

struct CouncilAnswer: Decodable { var ok: Bool?; var by: String?; var record: DecisionRecord }

// MARK: projects

struct Project: Decodable, Hashable, Identifiable {
    var slug: String
    var name: String
    var status: String
    var target: String?
    var outcome: String?
    var domains: [Role]?
    var milestones: [Milestone]?
    var progress: Progress?
    var id: String { slug }

    struct Role: Decodable, Hashable { var slug: String; var role: String? }
    struct Milestone: Decodable, Hashable, Identifiable { var id: String; var title: String; var done: Bool; var due: String? }
    struct Progress: Decodable, Hashable { var milestones: Share? }
    struct Share: Decodable, Hashable { var done: Int?; var total: Int?; var share: Double? }

    var owner: String? { domains?.first { $0.role == "owner" }?.slug ?? domains?.first?.slug }

    /// Weighted share from the engine, else done over total; 0...1.
    var fraction: Double {
        if let s = progress?.milestones?.share { return max(0, min(1, s > 1 ? s / 100 : s)) }
        let ms = milestones ?? []
        return ms.isEmpty ? 0 : Double(ms.filter(\.done).count) / Double(ms.count)
    }
}

// MARK: recommendations (only what the weekly note uses)

struct RuleRecs: Decodable {
    var recommendations: [Item]
    struct Item: Decodable, Identifiable {
        var id: String
        var category: String?
        var title: String
        var detail: String?
        var instruction: String?
        var metric: Metric?
        var action: Action?
        struct Metric: Decodable { var value: Double? }
        struct Action: Decodable { var kind: String?; var rule: String?; var finding: String?; var item: String? }

        var rule: String { action?.rule ?? instruction ?? title.replacingOccurrences(of: "Make it a rule: ", with: "") }
        var times: Int? { metric?.value.map { Int($0) } }
    }
}

// MARK: chief of staff

struct ChiefLimits: Decodable {
    var name: String?
    var limits: Limits?
    struct Limits: Decodable { var usd: Double?; var minutes: Double? }
}

// MARK: the weekly note

/// The chief of staff's weekly review, general/memory/reviews/<name>.md:
/// a title, the note's paragraph, `## Noticed` bullets, and `## Proposed trade-offs for <Domain>`
/// bullets carrying `~status:proposed|accepted|dismissed`.
struct WeeklyReview: Equatable {
    var url: URL
    var date: Date?
    var note: String
    var noticed: [String]
    var proposals: [Proposal]

    struct Proposal: Equatable, Identifiable {
        var domain: String     // as the heading names it ("Wealth")
        var text: String       // "Low fees over a familiar advisor"
        var status: String     // proposed | accepted | dismissed
        var id: String { "\(domain)|\(text)" }
    }

    /// The newest review: names sort by date (week-2026-10-25.md), so the last one.
    static func newest(in dir: URL = Vault.domain(AppModel.chiefID).appending(path: "memory/reviews")) -> WeeklyReview? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let last = files.last, let text = Vault.read(last) else { return nil }
        return parse(text, url: last)
    }

    static func parse(_ text: String, url: URL) -> WeeklyReview {
        var note: [String] = [], noticed: [String] = [], proposals: [Proposal] = []
        var section: String? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { continue }
            if let h = Markdown.heading(line) { section = h; continue }
            guard let section else { if !line.isEmpty { note.append(line) }; continue }
            guard let b = bulletText(line) else { continue }
            if section.lowercased() == "noticed" { noticed.append(b.text) }
            if let r = section.range(of: "trade-offs for ", options: .caseInsensitive) {
                proposals.append(Proposal(domain: String(section[r.upperBound...]).trimmingCharacters(in: .whitespaces), text: b.text, status: b.status ?? "proposed"))
            }
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let date = stem.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression).flatMap { MoreDate.parse(String(stem[$0])) }
        return WeeklyReview(url: url, date: date, note: note.joined(separator: " "), noticed: noticed, proposals: proposals)
    }

    /// "- Low fees over a familiar advisor ~status:proposed" -> text and status.
    static func bulletText(_ line: String) -> (text: String, status: String?)? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        var words: [Substring] = [], status: String?
        for w in line.dropFirst(2).split(separator: " ") {
            if w.hasPrefix("~status:") { status = String(w.dropFirst("~status:".count)) } else if !w.hasPrefix("~") { words.append(w) }
        }
        let t = words.joined(separator: " ")
        return t.isEmpty ? nil : (t, status)
    }

    /// The review's text with one proposal's status set; every other line as it was.
    static func marking(_ text: String, _ p: Proposal, as status: String) -> String {
        var inSection = false
        return text.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let h = Markdown.heading(line) { inSection = h.range(of: "trade-offs for \(p.domain)", options: .caseInsensitive) != nil; return raw }
            guard inSection, let b = bulletText(line), b.text == p.text else { return raw }
            return "- \(p.text) ~status:\(status)"
        }.joined(separator: "\n")
    }

    /// "Wealth" -> "wealth": the domain whose title or slug the heading names.
    static func slug(for name: String, in store: IntentStore = IntentStore()) -> String {
        let slugs = store.domainSlugs()
        if let s = slugs.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return s }
        if let s = slugs.first(where: { store.contract($0).title.caseInsensitiveCompare(name) == .orderedSame }) { return s }
        return name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Yes: the trade-off joins the domain's `## Trade-offs` (once), and the review remembers the answer.
    /// No: only the review remembers it.
    static func answer(_ p: Proposal, yes: Bool, review: URL, store: IntentStore = IntentStore()) throws {
        if yes {
            let slug = slug(for: p.domain, in: store)
            var items = store.contract(slug).tradeOffs
            let new = TradeOff(line: p.text)
            if !items.contains(where: { $0.line.caseInsensitiveCompare(new.line) == .orderedSame }) {
                items.append(new)
                try store.setTradeOffs(items, in: slug)
            }
        }
        let text = Vault.read(review) ?? ""
        try store.write(marking(text, p, as: yes ? "accepted" : "dismissed"), to: review)
    }
}

/// "Two", "Three": counts as the chief of staff says them.
enum Spoken {
    static func count(_ n: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return words[safe: n] ?? "\(n)"
    }
}
