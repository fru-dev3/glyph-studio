import Foundation

// The intent model (glyph-studio-native-intent.md, decision d-mvooq56i): life purpose and values,
// then domains (purpose, trade-offs, boundaries), then outcomes, the one unit agents work against.
// Everything here is read from, and written back to, the vault's own files (IntentStore).

/// The life level, from build/compass.md (`## Purpose`, `## Values`). Read-only here: the engine's
/// `compass` verbs own that file (versions, ledger, confirmation).
struct Life: Equatable, Sendable {
    var purpose: String
    /// `~status:proposed` under the purpose: drafted, not yet confirmed by the user.
    var purposeProposed: Bool
    var values: [Value]

    struct Value: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var rank: Int?
        var words: String?
        var enough: String?
        var proposed: Bool
    }
}

/// "This over that": what lets an agent make the user's call.
struct TradeOff: Equatable, Sendable {
    var this: String
    var over: String

    /// `- X over Y`; a line without " over " keeps its whole text in `this`.
    init(line: String) {
        if let r = line.range(of: " over ", options: .caseInsensitive) {
            this = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            over = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else { this = line.trimmingCharacters(in: .whitespaces); over = "" }
    }
    init(_ this: String, over: String) { self.this = this; self.over = over }
    var line: String { over.isEmpty ? this : "\(this) over \(over)" }
}

struct Boundaries: Equatable, Sendable {
    /// ideal-state.md "What to avoid".
    var never: [String] = []
    /// agent.md frontmatter `may:` (read-only).
    var may: [String] = []
    /// ideal-state.md `## Must ask`.
    var mustAsk: [String] = []
    /// agent.md `tier:` (read | write-vault | draft | act-ask | act).
    var tier: String?
}

struct DomainContract: Equatable, Sendable, Identifiable {
    var slug: String
    var title: String
    /// ideal-state.md `## Purpose`.
    var purpose: String
    var tradeOffs: [TradeOff]
    var boundaries: Boundaries
    /// ideal-state.md "Metrics you track" bullets: domain-level measures.
    var metrics: [String]
    var outcomes: [Outcome]
    var id: String { slug }

    var links: [OutcomeLink] { outcomes.flatMap(\.links) }
}

/// Why the user holds an outcome (self-concordance): enjoy and value carry, should and have-to don't.
enum ReasonTag: String, CaseIterable, Sendable {
    case enjoy, value, should, haveTo = "have-to"

    init?(loose: String) {
        let s = loose.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        self.init(rawValue: s == "haveto" ? "have-to" : s)
    }
}

enum Focus: String, Sendable {
    case inFocus = "in", parked

    init?(loose: String) {
        switch loose.lowercased() {
        case "in", "yes", "true", "focus", "in focus", "focused": self = .inFocus
        case "parked", "park", "no", "false", "out": self = .parked
        default: return nil
        }
    }
}

/// One goal line of a domain's source/goals.md and its indented fields (GoalsDoc has the grammar).
struct Outcome: Equatable, Sendable, Identifiable {
    var id: String
    /// The approach-phrased statement: what to move toward.
    var title: String
    var done: Bool = false
    var status: String = "active" // active | done | archived (anything else is kept)
    var due: String?
    var progress: Int?
    var objective: String?
    var why: String?
    var reason: ReasonTag?
    /// WOOP `outcome:`: the outcome the user pictures.
    var pictured: String?
    var floor: String?
    var stretch: String?
    var neverSacrifice: [String] = []
    var obstacle: String?
    /// WOOP `plan:`, an if-then plan.
    var plan: String?
    var measures: [String] = []
    var stopWhen: String?
    var review: String?
    var focus: Focus?
    var helps: [String] = []
    var pulls: [String] = []

    var inFocus: Bool { focus == .inFocus }
    var links: [OutcomeLink] {
        helps.map { OutcomeLink(from: id, to: $0, kind: .helps) } + pulls.map { OutcomeLink(from: id, to: $0, kind: .pulls) }
    }
}

/// Facilitation and conflict are two separate pairwise links (Riediger and Freund).
struct OutcomeLink: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable { case helps, pulls }
    var from: String
    var to: String
    var kind: Kind
}

/// Below the line, in the book's three lines.
struct Report: Equatable, Sendable {
    var done: [String] = []
    var decided: [String] = []
    var needed: [String] = []
}

/// Something that needs the user.
struct Call: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case approval, gap, conflict }
    var kind: Kind
    var id: String
    var domain: String?
    var text: String

    /// `waiting` items: what agents stopped on.
    static func approvals(_ w: Feeds.Waiting) -> [Call] {
        w.items.map { Call(kind: .approval, id: "approval:\($0.id)", domain: $0.domain, text: $0.summary ?? $0.kind ?? $0.id) }
    }

    /// Alignment pillars under `below`, lowest first: where life and intent part.
    static func gaps(_ a: Feeds.Alignment, below: Int = 50) -> [Call] {
        a.pillars.filter { $0.score < below }.sorted { $0.score < $1.score }
            .map { Call(kind: .gap, id: "gap:\($0.pillar)", domain: $0.pillar, text: $0.rationale ?? "\($0.pillar) is at \($0.score)") }
    }

    /// `pulls:` links; one across domains goes to the user, one within a domain the agent may settle.
    static func conflicts(_ contracts: [DomainContract]) -> [Call] {
        let home = Dictionary(contracts.flatMap { c in c.outcomes.map { ($0.id, c.slug) } }, uniquingKeysWith: { a, _ in a })
        let title = Dictionary(contracts.flatMap { $0.outcomes.map { ($0.id, $0.title) } }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return contracts.flatMap(\.links).filter { $0.kind == .pulls }.compactMap { l in
            let key = [l.from, l.to].sorted().joined(separator: "|")
            guard seen.insert(key).inserted, home[l.from] != home[l.to] else { return nil }
            return Call(kind: .conflict, id: "conflict:\(key)", domain: home[l.from],
                        text: "\(title[l.from] ?? l.from) pulls against \(title[l.to] ?? l.to)")
        }
    }
}
