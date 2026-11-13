import Foundation

/// A new teammate as the sheet fills it in, and how it becomes a domain in the vault: the same
/// files and formats the demo vault and the engine read (VAULT.md): manifest.json, ideal-state.md
/// (`## Purpose`, `## Trade-offs`, `## Must ask`), agent.md frontmatter (may, asks, tier and the
/// look: color, shape, icon), memory/state.md, memory/tasks.md, memory/memory.md, source/goals.md.
/// The engine has no create verb (its scaffoldDomain runs only from accepted suggestions), so
/// Studio writes them, each through IntentStore's write guard.
struct TeammateDraft: Equatable {
    var name = ""
    var shape: Look.Shape = .squircle
    var color: UInt32 = Look.palette[0]
    var purpose = ""
    var tradeOffs = ""
    var mayAlone = ""
    var mustAsk = ""

    /// The folder name: lowercase words joined by dashes, as the engine slugs a domain.
    var slug: String { Self.slug(name) }

    static func slug(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    /// The glyph: a known teammate's when the name is one (Estate gets the house), else a plain one.
    var glyph: String { Teammate.icons[slug] ?? "circle.grid.2x2" }
    var look: Look { Look(shape: shape, color: color, glyph: glyph) }

    /// Why Create can't go ahead, in a sentence; nil when it can.
    func problem(existing: [String], names: [String], chiefName: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || slug.isEmpty { return "Give your teammate a name." }
        let taken = existing.contains(slug) || slug == AppModel.chiefID
            || (names + [chiefName]).contains { $0.caseInsensitiveCompare(n) == .orderedSame }
        if taken { return "You already have a teammate called \(n). Pick another name." }
        return nil
    }

    // MARK: the files

    /// "Done right over done fast · Family privacy over convenience" (or one per line, or `;`).
    static func items(_ s: String, commas: Bool = false) -> [String] {
        var parts = s.components(separatedBy: CharacterSet(charactersIn: "\n;·" + (commas ? "," : "")))
        if !commas, parts.count == 1 { parts = s.components(separatedBy: ",") }
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*\t\"[]")) }.filter { !$0.isEmpty }
    }

    /// A list for agent.md's inline YAML: lowercased first letter, as the demo vault writes it.
    private static func yamlList(_ items: [String]) -> String {
        "[" + items.map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: ", ") + "]"
    }

    static let cssShape: [Look.Shape: String] = [
        .circle: "50%", .squircle: "14px", .leaf: "10px 22px 22px 22px", .drop: "22px 22px 22px 8px", .square: "4px",
    ]

    /// The tier the engine reads: a teammate that may book, buy, pay, send or schedule acts and asks; else it drafts.
    var tier: String {
        let acts = ["book", "buy", "pay", "send", "schedule", "order"]
        return Self.items(mayAlone, commas: true).contains { item in acts.contains { item.lowercased().hasPrefix($0) } } ? "act-ask" : "draft"
    }

    func files() -> [(String, String)] {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let purposeText = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let trades = Self.items(tradeOffs), may = Self.items(mayAlone, commas: true), ask = Self.items(mustAsk, commas: true)
        let icon = Teammate.icons[slug] != nil ? slug : glyph
        let summary = purposeText.split(separator: ".").first.map { String($0.prefix(80)) } ?? label
        let manifest: [String: Any] = [
            "identity": ["name": slug, "label": label, "emoji": icon, "summary": summary],
            "config": ["autoState": false, "pinned": false],
            "routing": ["keywords": [String](), "channels": [String](), "default": false],
            "heartbeat": ["enabled": false, "routines": [String]()],
            "privacy": ["localOnly": false],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let section = { (title: String, items: [String]) in items.isEmpty ? "" : "\n## \(title)\n" + items.map { "- \($0)\n" }.joined() }
        let ideal = "# \(label) ideal state\n\n## Purpose\n\(purposeText)\n" + section("Trade-offs", trades) + section("Must ask", ask)
        let agent = """
        ---
        owns: [\(label.lowercased())]
        hears: [general]
        may: \(Self.yamlList(may))
        asks: \(Self.yamlList(ask))
        hands_off_to: [general]
        tier: \(tier)
        color: "#\(String(format: "%06x", color))"
        shape: "\(Self.cssShape[shape] ?? "14px")"
        icon: \(icon)
        ---
        # \(label)

        \(purposeText.isEmpty ? "" : purposeText + " ")Writes only its own folder; for another domain it adds a task there.

        """
        return [
            ("manifest.json", json + "\n"),
            ("ideal-state.md", ideal),
            ("agent.md", agent),
            ("memory/state.md", "# \(label), current state\n\nStatus: New\n"),
            ("memory/tasks.md", "# Tasks\n"),
            ("memory/memory.md", "# \(label) memory\n\n## Durable facts\n" + (purposeText.isEmpty ? "" : "- \(purposeText)\n")),
            ("source/goals.md", "# Goals\n"),
        ]
    }

    /// Writes the domain. Refuses a folder that is already there, so nothing is ever overwritten.
    func create(in store: IntentStore = IntentStore()) throws {
        let dir = store.domainDir(slug)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw IntentStore.Refused(errorDescription: "You already have a teammate called \(name). Pick another name.")
        }
        for (path, text) in files() { try store.write(text, to: dir.appending(path: path)) }
    }

    /// What Ben is asked when you'd rather be interviewed than fill the sheet in. Worded so the
    /// engine doesn't take it for its Compass interview ("interview me" starts that one).
    var interviewMessage: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = "Help me write the role for a new teammate\(n.isEmpty ? "" : ", \(n)"). Ask me one question at a time: its purpose in my words, the trade-offs it should make, what it may do alone, and what it must ask me first."
        let have = [("Purpose", purpose), ("Trade-offs", tradeOffs), ("May do alone", mayAlone), ("Must ask", mustAsk)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
        if !have.isEmpty { s += " So far: " + have.map { "\($0.0): \($0.1.trimmingCharacters(in: .whitespaces))" }.joined(separator: ". ") + "." }
        return s
    }
}

/// A message for a teammate's chat to send when it opens (the interview). ChatScreen is another
/// builder's; until AppModel carries this, it lives here (see the report's shared changes).
@MainActor
enum ChatHandoff {
    static var pending: [String: String] = [:]
}
