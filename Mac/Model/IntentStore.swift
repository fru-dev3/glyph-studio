import Foundation

/// Reads intent from the vault's own files and writes it back in their own formats (VAULT.md):
///
/// - outcomes: a domain's source/goals.md (GoalsDoc), falling back to a root goals.md on an old layout
/// - purpose, Never, Must ask, Trade-offs, metrics: the domain's ideal-state.md (`## Purpose`,
///   `## What to avoid`, `## Must ask`, `## Trade-offs` with `- X over Y` lines, `## Metrics you track`)
/// - May and tier: agent.md frontmatter, read-only (agents.md is the engine's agent mesh contract)
/// - life purpose and values: build/compass.md, read-only (the engine's `compass` verbs own it)
///
/// Each write is one atomic replace of one file, and leaves every line it did not change as it was.
/// ideal-state.md first keeps its prior text in ideal-state.versions/<ISO>.md, as the engine's
/// writeVersioned does. Nothing here writes a machine-managed path (VAULT.md "NEVER touch").
struct IntentStore: Sendable {
    var root: URL

    init(root: URL = Vault.root) { self.root = root }

    func domainDir(_ slug: String) -> URL { root.appending(path: "data/domains/\(slug)") }

    // MARK: reading

    func contract(_ slug: String) -> DomainContract {
        let ideal = Markdown(read(domainDir(slug).appending(path: "ideal-state.md")))
        let agent = AgentFile(read(domainDir(slug).appending(path: "agent.md")))
        return DomainContract(
            slug: slug, title: title(slug), purpose: ideal.body(of: "Purpose"),
            tradeOffs: ideal.bullets(of: "Trade-offs").map(TradeOff.init(line:)),
            boundaries: Boundaries(never: ideal.items(of: "What to avoid"), may: agent.list("may"),
                                   mustAsk: ideal.bullets(of: "Must ask"), tier: agent.scalar("tier")),
            metrics: ideal.bullets(of: "Metrics you track"),
            outcomes: goals(slug).outcomes)
    }

    /// Domains with a folder under data/domains (no `_` folders, no archived manifests).
    func domainSlugs() -> [String] {
        let dir = root.appending(path: "data/domains")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.filter { name in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.appending(path: name).path, isDirectory: &isDir), isDir.boolValue else { return false }
            return (manifest(name)?["archived"] as? Bool) != true
        }.sorted()
    }

    func life() -> Life {
        let md = Markdown(read(root.appending(path: "build/compass.md")))
        let purposeLines = md.lines(of: "Purpose")
        let proposed = purposeLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("~") && $0.contains("~status:proposed") }
        let purpose = purposeLines.filter { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("~") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [Life.Value] = []
        for line in md.lines(of: "Values") {
            if line.hasPrefix("- ") {
                let words = line.dropFirst(2).split(separator: " ")
                var tokens: [String: String] = [:], title: [Substring] = [], flags = Set<String>()
                for w in words {
                    if w.hasPrefix("~") {
                        let kv = w.dropFirst().split(separator: ":", maxSplits: 1)
                        if kv.count == 2 { tokens[String(kv[0])] = String(kv[1]) } else { flags.insert(String(w.dropFirst())) }
                    } else { title.append(w) }
                }
                let t = title.joined(separator: " ")
                values.append(Life.Value(id: tokens["id"] ?? t, title: t, rank: tokens["rank"].flatMap { Int($0) },
                                         proposed: tokens["status"] == "proposed"))
            } else if !values.isEmpty, let f = GoalsDoc.field(line) {
                if f.key == "words" { values[values.count - 1].words = f.value }
                if f.key == "enough" { values[values.count - 1].enough = f.value }
            }
        }
        return Life(purpose: purpose, purposeProposed: proposed, values: values.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) })
    }

    /// The goals file a domain reads: source/goals.md, else an old root goals.md, else (new) source/goals.md.
    func goalsFile(_ slug: String) -> URL {
        let dir = domainDir(slug)
        let v4 = dir.appending(path: "source/goals.md"), old = dir.appending(path: "goals.md")
        return !FileManager.default.fileExists(atPath: v4.path) && FileManager.default.fileExists(atPath: old.path) ? old : v4
    }

    func goals(_ slug: String) -> GoalsDoc { GoalsDoc(text: read(goalsFile(slug)), domain: slug) }

    // MARK: writing

    /// Saves one outcome (only the lines that changed) or adds it when its id is not on file.
    func save(_ outcome: Outcome, in slug: String) throws {
        var doc = goals(slug)
        if doc.outcome(outcome.id) == nil {
            let id = doc.add(outcome.title)
            var o = outcome
            o.id = id
            o.title = doc.outcome(id)?.title ?? outcome.title
            try doc.save(o)
        } else { try doc.save(outcome) }
        try write(doc.text, to: goalsFile(slug))
    }

    func setTradeOffs(_ items: [TradeOff], in slug: String) throws {
        try editIdeal(slug) { $0.setBullets(of: "Trade-offs", items.map(\.line)) }
    }

    func setMustAsk(_ items: [String], in slug: String) throws {
        try editIdeal(slug) { $0.setBullets(of: "Must ask", items) }
    }

    private func editIdeal(_ slug: String, _ change: (inout Markdown) -> Void) throws {
        let url = domainDir(slug).appending(path: "ideal-state.md")
        let before = read(url)
        var md = Markdown(before)
        change(&md)
        guard md.text != before else { return }
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let dir = domainDir(slug).appending(path: "ideal-state.versions")
            var keep = dir.appending(path: "\(stamp).md")
            var n = 1
            while FileManager.default.fileExists(atPath: keep.path) { keep = dir.appending(path: "\(stamp)-\(n).md"); n += 1 }
            try write(before, to: keep)
        }
        try write(md.text, to: url)
    }

    struct Refused: LocalizedError { var errorDescription: String? }

    /// The owner's real vault (or a folder inside it), which Studio never writes by hand.
    static func isOwnersVault(_ root: URL, real: URL? = StudioPaths.realVault) -> Bool {
        guard let r = real?.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        let v = root.standardizedFileURL.resolvingSymlinksInPath().path
        return v == r || v.hasPrefix(r + "/")
    }

    /// One atomic replace (temp file, then rename). Refuses an encrypted vault (the engine owns
    /// those reads and writes), a path outside the vault and every machine-managed path.
    func write(_ text: String, to url: URL) throws {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(base) else { throw Refused(errorDescription: "Glyph Bot writes only inside the vault.") }
        // Your own vault is never written by hand: there every write goes through Glyph Engine (a receipt each).
        if Self.isOwnersVault(root) {
            throw Refused(errorDescription: "In your vault, Glyph Bot saves through Glyph Engine only. Ask the agent to save it.")
        }
        guard !FileManager.default.fileExists(atPath: root.appending(path: ".prevail-encrypted").path) else {
            throw Refused(errorDescription: "This vault is encrypted; edit it through Glyph Engine.")
        }
        guard !Self.machineManaged(String(path.dropFirst(base.count))) else {
            throw Refused(errorDescription: "\(url.lastPathComponent) is managed by Glyph Engine.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// VAULT.md "NEVER touch": build/_meta/, any .system/, memory/threads/, _loops_runtime.json,
    /// _surface.json, app _scope/ dirs.
    static func machineManaged(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        if relative.hasPrefix("build/_meta/") || parts.contains(".system") || parts.contains("_scope") { return true }
        if let i = parts.firstIndex(of: "memory"), parts.indices.contains(i + 1), parts[i + 1] == "threads" { return true }
        return ["_loops_runtime.json", "_surface.json"].contains(parts.last ?? "")
    }

    // MARK: helpers

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func manifest(_ slug: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: domainDir(slug).appending(path: "manifest.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func title(_ slug: String) -> String {
        let id = manifest(slug)?["identity"] as? [String: Any]
        return (id?["label"] as? String)?.nonEmpty ?? slug.capitalized
    }
}

/// Markdown split into `## ` sections; edits replace only the lines of one section's list.
struct Markdown: Equatable, Sendable {
    private(set) var all: [String]

    init(_ text: String) { all = text.components(separatedBy: "\n") }
    var text: String { all.joined(separator: "\n") }

    /// The lines under `## <name>` (case-insensitive) up to the next heading.
    private func range(of name: String) -> Range<Int>? {
        guard let h = all.firstIndex(where: { Self.heading($0)?.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let end = all[(h + 1)...].firstIndex { $0.hasPrefix("#") && Self.level($0) <= 2 } ?? all.count
        return (h + 1)..<end
    }

    func lines(of name: String) -> [String] { range(of: name).map { Array(all[$0]) } ?? [] }

    func body(of name: String) -> String { lines(of: name).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }

    func bullets(of name: String) -> [String] { lines(of: name).compactMap(Self.bullet) }

    /// Bullets when the section has them, else its paragraphs.
    func items(of name: String) -> [String] {
        let b = bullets(of: name)
        if !b.isEmpty { return b }
        return body(of: name).components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Replaces the section's bullet lines with `items`, where its first bullet was; a bullet whose
    /// text is unchanged keeps its line as it was. A missing section is added at the end.
    mutating func setBullets(of name: String, _ items: [String]) {
        let items = items.map(GoalsDoc.clean).filter { !$0.isEmpty }
        guard let r = range(of: name) else {
            guard !items.isEmpty else { return }
            if all.last == "" { all.removeLast() }
            while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
            all += (all.isEmpty ? [] : [""]) + ["## \(name)", ""] + items.map { "- \($0)" } + [""]
            return
        }
        let old = r.filter { Self.bullet(all[$0]) != nil }
        let oldLines = old.map { all[$0] }
        let fresh = items.enumerated().map { n, item in
            n < oldLines.count && Self.bullet(oldLines[n]) == item ? oldLines[n] : "- \(item)"
        }
        guard fresh != oldLines else { return }
        if let at = old.first {
            for i in old.reversed() { all.remove(at: i) }
            all.insert(contentsOf: fresh, at: at)
            return
        }
        // No list yet: after the section's text, a blank line apart, before the blanks that end it.
        let blank = { (l: String) in l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var at = r.upperBound
        while at > r.lowerBound, blank(all[at - 1]) { at -= 1 }
        let tail = all.indices.contains(at) && !blank(all[at]) ? [""] : []
        all.insert(contentsOf: [""] + fresh + tail, at: at)
    }

    static func heading(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        return line.dropFirst(3).trimmingCharacters(in: .whitespaces)
    }

    private static func level(_ line: String) -> Int { line.prefix { $0 == "#" }.count }

    static func bullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
        return GoalsDoc.clean(String(t.dropFirst(2))).nonEmpty
    }
}

/// agent.md frontmatter, the small YAML the engine writes (`key: value`, `key: [a, b]`, or a key
/// followed by `  - item` lines). Read-only.
struct AgentFile {
    private var front: [String] = []

    init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
        front = Array(lines[1..<end])
    }

    func scalar(_ key: String) -> String? {
        front.first { $0.hasPrefix("\(key):") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }?.nonEmpty
    }

    func list(_ key: String) -> [String] {
        guard let i = front.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return [] }
        let unquote = { (s: String) in s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        if let inline = scalar(key), inline.hasPrefix("[") {
            return inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
        }
        return front[(i + 1)...].prefix { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
            .compactMap { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("- ") ? unquote(String(t.dropFirst(2))).nonEmpty : nil
            }
    }
}
