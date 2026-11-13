import Foundation

// Filing a note to any place in the vault without moving it: the place's `linked-notes.md` gets one line
// that points at the note, and the note's front matter gets the place's path under `links:`. Both are
// taken back by `unfile`. Places are folders, by vault-relative path: a domain, a company's or a job's
// application folder, a CRM page's folder, a project (mission), and any extra place the vault lists in
// `data/apps/jot/places.json` ([{"path", "label", "kind"}]). The hub does the same.

/// A place a note can be filed to.
public struct FilePlace: Codable, Hashable, Sendable, Identifiable {
    public var path: String     // vault-relative folder: "data/entities/orgs/acme"
    public var label: String    // "Acme"
    public var kind: String     // domain, application, person, org, place, thing, project, or the vault's own
    public var reason: String?  // why Glyph suggests it ("an interview with Acme")
    public var id: String { path }
    public init(path: String, label: String, kind: String, reason: String? = nil) {
        self.path = path; self.label = label; self.kind = kind; self.reason = reason
    }
}

public enum CrossLink {
    public static let file = "linked-notes.md"

    /// Every place in the vault a note can be filed to, sorted by label within kind.
    public static func places(in vault: URL) -> [FilePlace] {
        let fm = FileManager.default
        func dirs(_ rel: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: vault.appending(path: rel).path)) ?? []).filter { n in
                var d: ObjCBool = false
                return !n.hasPrefix(".") && !n.hasPrefix("_") && !n.hasPrefix("archived-")
                    && fm.fileExists(atPath: vault.appending(path: rel).appending(path: n).path, isDirectory: &d) && d.boolValue
            }.sorted()
        }
        func name(_ page: String, _ slug: String) -> String {
            let text = (try? String(contentsOf: vault.appending(path: page), encoding: .utf8)) ?? ""
            if text.hasPrefix("---"), let line = text.split(separator: "\n").prefix(30).first(where: { $0.hasPrefix("name:") }) {
                let n = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !n.isEmpty { return n }
            }
            return title(slug)
        }
        var out: [FilePlace] = []
        for d in dirs("data/domains") {
            out.append(FilePlace(path: "data/domains/\(d)", label: title(d), kind: "domain"))
            for a in dirs("data/domains/\(d)/memory/current/applications") {
                out.append(FilePlace(path: "data/domains/\(d)/memory/current/applications/\(a)", label: title(a), kind: "application"))
            }
        }
        for (folder, kind) in [("people", "person"), ("orgs", "org"), ("places", "place"), ("things", "thing")] {
            for s in dirs("data/entities/\(folder)") where fm.fileExists(atPath: vault.appending(path: "data/entities/\(folder)/\(s)/entity.md").path) {
                out.append(FilePlace(path: "data/entities/\(folder)/\(s)", label: name("data/entities/\(folder)/\(s)/entity.md", s), kind: kind))
            }
        }
        for m in dirs("data/missions") {
            out.append(FilePlace(path: "data/missions/\(m)", label: name("data/missions/\(m)/mission.md", m), kind: "project"))
        }
        if let data = try? Data(contentsOf: vault.appending(path: "data/apps/jot/places.json")),
           let extra = try? JSONDecoder().decode([FilePlace].self, from: data) {
            for p in extra where safe(p.path) && !out.contains(where: { $0.path == p.path }) { out.append(p) }
        }
        return out
    }

    /// "2026-10-09-acme-field-engineer" -> "Acme field engineer"; "ken-lee" -> "Ken lee" (pages carry real names).
    public static func title(_ slug: String) -> String {
        var s = Substring(slug)
        if s.prefix(11).wholeMatch(of: /\d{4}-\d{2}-\d{2}-/) != nil { s = s.dropFirst(11) }
        let t = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// The place a name means ("Acme", "acme application", "whispers"), best match first: a label or folder
    /// that equals it, then one that contains it. Applications win ties over CRM pages over domains.
    public static func match(_ said: String, in places: [FilePlace]) -> FilePlace? {
        // The words that name it, without "my", "the", "application", "page"...
        let skip: Set<String> = ["my", "the", "a", "an", "to", "under", "in", "for", "application", "app", "page", "folder", "job"]
        let words = said.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !skip.contains($0) }
        let q = words.joined(separator: " ")
        guard !q.isEmpty else { return nil }
        if let exact = places.first(where: { $0.path == said }) { return exact }
        // "my Acme application": its application folder when there is one.
        let places = said.lowercased().contains("application") ? places.filter { $0.kind == "application" }.nilIfEmpty ?? places : places
        let rank = ["application": 0, "org": 1, "person": 2, "project": 3, "domain": 5]
        func key(_ p: FilePlace) -> [String] { [p.label.lowercased(), title((p.path as NSString).lastPathComponent).lowercased()] }
        let exact = places.filter { key($0).contains(q) }
        let hits = exact.isEmpty ? places.filter { p in key(p).contains { k in words.allSatisfy { k.contains($0) } } } : exact
        return hits.min { (rank[$0.kind] ?? 4) < (rank[$1.kind] ?? 4) }
    }

    /// Files the note (vault-relative `note`, titled `title`) to `place`. False when it is filed there already.
    @discardableResult
    public static func file(note: String, title: String, to place: String, in vault: URL, date: Date = .now) throws -> Bool {
        guard safe(note), safe(place) else { throw CocoaError(.fileWriteNoPermission) }
        let noteURL = vault.appending(path: note)
        let raw = try String(contentsOf: noteURL, encoding: .utf8)
        let linksNow = links(raw)
        let list = vault.appending(path: place).appending(path: file)
        var page = (try? String(contentsOf: list, encoding: .utf8)) ?? "# Linked notes\n\nNotes filed here from Glyph Jot. The notes stay where they are.\n\n"
        let target = "(<\(relative(note, from: place))>)"
        let listed = page.contains(target)
        if listed && linksNow.contains(place) { return false }
        if !listed {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            let shown = title.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "\n", with: " ")
            if !page.hasSuffix("\n") { page += "\n" }
            page += "- \(f.string(from: date)) [\(shown)]\(target)\n"
            try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
            try page.write(to: list, atomically: true, encoding: .utf8)
        }
        if !linksNow.contains(place) { try setLinks(raw, linksNow + [place]).write(to: noteURL, atomically: true, encoding: .utf8) }
        return true
    }

    /// Takes a filing back: the line out of the place's list, the path out of the note's `links:`.
    public static func unfile(note: String, from place: String, in vault: URL) throws {
        guard safe(note), safe(place) else { throw CocoaError(.fileWriteNoPermission) }
        let list = vault.appending(path: place).appending(path: file)
        if let page = try? String(contentsOf: list, encoding: .utf8) {
            let target = "(<\(relative(note, from: place))>)"
            let kept = page.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(target) }.joined(separator: "\n")
            if kept != page { try kept.write(to: list, atomically: true, encoding: .utf8) }
        }
        let noteURL = vault.appending(path: note)
        if let raw = try? String(contentsOf: noteURL, encoding: .utf8), links(raw).contains(place) {
            try setLinks(raw, links(raw).filter { $0 != place }).write(to: noteURL, atomically: true, encoding: .utf8)
        }
    }

    /// The vault paths in a note's `links:` line (older notes kept CRM ids there; those are not paths).
    public static func links(_ raw: String) -> [String] {
        guard raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex),
              let line = raw[..<end.lowerBound].split(separator: "\n").first(where: { $0.hasPrefix("links:") }) else { return [] }
        return line.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " []")).split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { $0.hasPrefix("data/") }
    }

    /// `raw` with its `links:` line holding these paths (CRM ids an older line had are kept), or without one when none.
    public static func setLinks(_ raw: String, _ paths: [String]) -> String {
        var head: [String] = [], body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) {
            head = raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            body = String(raw[end.upperBound...])
        } else { body = "\n\n" + raw }
        let i = head.firstIndex { $0.hasPrefix("links:") }
        let old = i.map { head[$0].dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " []")).split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty && !$0.hasPrefix("data/") } } ?? []
        let all = old + paths.reduce(into: [String]()) { o, p in if !o.contains(p) { o.append(p) } }
        let line = "links: [\(all.joined(separator: ", "))]"
        switch (i, all.isEmpty) {
        case (let i?, true): head.remove(at: i)
        case (let i?, false): head[i] = line
        case (nil, false): head.append(line)
        case (nil, true): break
        }
        return "---\n" + head.joined(separator: "\n") + "\n---" + body
    }

    /// `note` as a link from inside `place`: "../../../notes/source/jot/x.md".
    static func relative(_ note: String, from place: String) -> String {
        let a = place.split(separator: "/"), b = note.split(separator: "/")
        var n = 0
        while n < min(a.count, b.count - 1), a[n] == b[n] { n += 1 }
        return (Array(repeating: "..", count: a.count - n) + b[n...].map(String.init)).joined(separator: "/")
    }

    /// Inside the vault's data folder, no climbing out.
    public static func safe(_ rel: String) -> Bool {
        rel.hasPrefix("data/") && !rel.split(separator: "/").contains("..") && !rel.contains("\0")
    }
}

extension Array {
    fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}
