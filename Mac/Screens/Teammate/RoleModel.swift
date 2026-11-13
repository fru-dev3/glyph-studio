import Foundation

/// A teammate's role page: its routines (the domain's playbooks, from `playbook rows --json` and
/// their files in build/playbooks) and its connected tools (the vault's apps that name the domain,
/// plus the blind feeds in memory/state.md `## Feeds` that a service could fill).
enum Role {
    // MARK: routines

    /// A row of `prevail playbook rows --json` (only what the page reads).
    struct PlaybookRow: Decodable, Sendable {
        var id: String
        var name: String
        var goal: String?
        var domain: String?
        var running: Bool?
        var schedule: Schedule?

        struct Schedule: Decodable, Sendable {
            var space: String?
            var cadence: String?
            var on: String?
            var enabled: Bool?
            var autonomy: String?
        }
    }

    struct Routine: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var when: String       // the display line, without the "off" mark
        var enabled: Bool
        var scheduled: Bool    // has a schedule the switch can turn on and off
        var space: String
        var rank: Int

        /// "1st of every month, 8:00 · writes a page", or "... · off" while it is off.
        var line: String { enabled || !scheduled ? when : (when.isEmpty ? "Off" : "\(when) · off") }
    }

    /// The domain's playbooks: its own or scheduled in it. `files` reads build/playbooks/<id>.json.
    static func routines(_ rows: [PlaybookRow], domain: String, file: (String) -> [String: Any]? = Role.playbookFile) -> [Routine] {
        rows.filter { $0.domain == domain || $0.schedule?.space == domain }.map { r in
            let f = file(r.id) ?? [:]
            let enabled = r.schedule?.enabled ?? true
            var when = (f["when"] as? String)?.nonEmpty ?? describe(r.schedule)
            if when.hasSuffix(" · off") { when = String(when.dropLast(6)) } else if when == "Off" { when = "" }
            return Routine(id: r.id, name: r.name, when: when, enabled: enabled, scheduled: r.schedule != nil,
                           space: r.schedule?.space ?? domain, rank: rank(r.schedule, cron: f["cron"] as? String) + (enabled ? 0 : 10))
        }
        .enumerated().sorted { a, b in a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset }.map(\.element)
    }

    /// Time-based first, the most frequent first (a cron that lists months runs quarterly), then on an event.
    static func rank(_ s: PlaybookRow.Schedule?, cron: String?) -> Int {
        guard let s else { return 6 }
        if s.on != nil { return 4 }
        if let cron, cron.split(separator: " ").count == 5, cron.split(separator: " ")[3].contains(",") { return 3 }
        return ["daily": 0, "weekly": 1, "monthly": 2][s.cadence ?? ""] ?? 5
    }

    /// A schedule in words when the playbook carries no display line.
    static func describe(_ s: PlaybookRow.Schedule?) -> String {
        guard let s else { return "When you run it" }
        let base = s.on.map { "Event · on \($0.replacingOccurrences(of: ":", with: " "))" }
            ?? ["daily": "Every day", "weekly": "Every week", "monthly": "Every month"][s.cadence ?? ""] ?? "On a schedule"
        return s.autonomy == "ask" ? "\(base) · asks before any change" : base
    }

    static func playbookFile(_ id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: Vault.build.appending(path: "playbooks/\(id).json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// One line of `run-playbook <id> --stream`.
    struct RunEvent: Decodable, Sendable {
        var phase: String?
        var ok: Bool?
        var note: String?
        var reason: String?
        var index: Int?
        var label: String?
        var steps: Int?
    }

    // MARK: tools

    /// How a blind service gets read without a connector, cheapest first.
    enum Path: String, CaseIterable, Sendable {
        case statement, teach, manual

        var title: String {
            switch self {
            case .statement: "Drop a statement in a folder"
            case .teach: "Teach it once"
            case .manual: "Type the number monthly"
            }
        }
        var cost: String {
            switch self {
            case .statement: "Free. It reads each PDF you drop, nothing else."
            case .teach: "You sign in once while it watches; it asks before every sign-in."
            case .manual: "Ten seconds a month. It asks on the 1st."
            }
        }
        func detail(folder: String) -> String {
            switch self {
            case .statement: "Reads statements you drop in \(folder)"
            case .teach: "Taught once · asks before every sign-in"
            case .manual: "You type the number on the 1st"
            }
        }
    }

    struct Feed: Equatable, Sendable {
        var name: String
        var status: String?
        var path: Path?
    }

    struct Tool: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var detail: String
        var added: Bool
        var feed: String?   // the `## Feeds` line it fills, for a tool you add
        var path: Path?
        var letter: String { String(name.prefix(1)).uppercased() }
    }

    /// `- Fidelity ~status:blind ~path:statement` lines under `## Feeds`.
    static func feeds(state: String) -> [Feed] {
        Markdown(state).bullets(of: "Feeds").map { line in
            let words = line.split(separator: " ")
            let tokens = Dictionary(words.filter { $0.hasPrefix("~") }.compactMap { w -> (String, String)? in
                let kv = w.dropFirst().split(separator: ":", maxSplits: 1)
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
            return Feed(name: words.filter { !$0.hasPrefix("~") }.joined(separator: " "), status: tokens["status"], path: tokens["path"].flatMap(Path.init))
        }
    }

    struct App: Sendable { var id: String; var name: String; var description: String; var domains: [String]; var enabled: Bool }

    /// The domain's tools in the order its feeds list them, then the other apps that name it.
    /// A blind feed becomes a tool to add only when it names a service (an org in the vault);
    /// an account like a 401(k) stays a feed on the domain board.
    static func tools(domain: String, apps: [App], feeds: [Feed], isService: (String) -> Bool, folder: String) -> [Tool] {
        let mine = apps.filter { $0.enabled && $0.domains.contains(domain) }
        var out: [Tool] = [], used = Set<String>()
        func appFor(_ feed: String) -> App? {
            mine.first { feed.lowercased() == $0.name.lowercased() || feed.lowercased().hasPrefix($0.name.lowercased() + " ") }
        }
        for f in feeds {
            if let a = appFor(f.name) {
                if used.insert(a.id).inserted { out.append(Tool(id: a.id, name: a.name, detail: a.description, added: true)) }
            } else if f.status == "blind" || f.path != nil, isService(f.name) {
                out.append(Tool(id: "feed:\(f.name)", name: f.name,
                                detail: f.path?.detail(folder: folder) ?? "No connector · teach it once, or drop a statement",
                                added: false, feed: f.name, path: f.path))
            }
        }
        for a in mine where !used.contains(a.id) { out.append(Tool(id: a.id, name: a.name, detail: a.description, added: true)) }
        return out
    }

    /// state.md with the feed's line carrying `~path:<p>` (replacing an earlier one); other lines untouched.
    static func choose(_ path: Path, for feed: String, in state: String) -> String {
        var md = Markdown(state)
        var items = md.bullets(of: "Feeds")
        if let i = items.firstIndex(where: { feeds(state: "## Feeds\n- \($0)").first?.name == feed }) {
            items[i] = items[i].split(separator: " ").filter { !$0.hasPrefix("~path:") }.joined(separator: " ") + " ~path:\(path.rawValue)"
        } else {
            items.append("\(feed) ~status:blind ~path:\(path.rawValue)")
        }
        md.setBullets(of: "Feeds", items)
        return md.text
    }

    /// The vault's apps (data/apps/<id>/manifest.json).
    static func vaultApps(root: URL = Vault.root) -> [App] {
        let dir = root.appending(path: "data/apps")
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: dir.appending(path: "\(id)/manifest.json")),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return App(id: id, name: (o["name"] as? String)?.nonEmpty ?? id.capitalized, description: (o["description"] as? String) ?? "",
                       domains: (o["domains"] as? [String]) ?? [], enabled: (o["enabled"] as? Bool) ?? true)
        }
    }

    /// An org (or thing) the vault knows by that name: a service a statement or a sign-in comes from.
    static func isService(_ name: String, root: URL = Vault.root) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "data/entities/orgs/\(TeammateDraft.slug(name))").path)
    }
}
