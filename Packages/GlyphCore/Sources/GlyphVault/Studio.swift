import Foundation

// The vault's objects (Glyph CRM's People, Places, Orgs and Things, plus Glyph Bot's
// projects and domains), read from the files, so a capture is filed under the same ids the CRM
// uses. No database: `data/entities/<kind>/<slug>/entity.md` is the truth.
// The layout is in docs/vault-format.md, "Studio links".

/// A Studio object a capture can link to.
public struct StudioObject: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case domain, person, org, project, place, thing

        /// The id's prefix: `person/ken-lee`, `org/acme`, `mission/launch`, `domain/career`.
        public var prefix: String {
            switch self {
            case .person: "person"
            case .org: "org"
            case .project: "mission"
            case .domain: "domain"
            case .place: "place"
            case .thing: "thing"
            }
        }

        /// The folder under `data/entities/` (nil: not an entity page).
        public var folder: String? {
            switch self {
            case .person: "people"
            case .place: "places"
            case .org: "orgs"
            case .thing: "things"
            case .project, .domain: nil
            }
        }

        /// Glyph CRM's four kinds, the ones a capture can make.
        public static let entities: [Kind] = [.person, .place, .org, .thing]

        /// Studio's names, plural and one.
        public var label: String {
            switch self {
            case .person: "People"
            case .org: "Orgs"
            case .project: "Projects"
            case .domain: "Domains"
            case .place: "Places"
            case .thing: "Things"
            }
        }

        public var singular: String {
            switch self {
            case .person: "Person"
            case .org: "Org"
            case .project: "Project"
            case .domain: "Domain"
            case .place: "Place"
            case .thing: "Thing"
            }
        }

        public init?(id: String) {
            guard let p = id.split(separator: "/", maxSplits: 1).first,
                  let k = Kind.allCases.first(where: { $0.prefix == p }) else { return nil }
            self = k
        }
    }

    public var id: String
    public var name: String
    public var aliases: [String] = []
    public var kind: Kind

    public init(id: String, name: String, aliases: [String] = [], kind: Kind) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
    }

    /// Whether `id` names a Studio object (as opposed to a name or a tag).
    public static func isID(_ id: String) -> Bool { Kind(id: id) != nil && id.contains("/") }
}

/// Every object in a Studio vault, found by id, name or alias.
public struct StudioDirectory: Sendable, Equatable {
    public private(set) var objects: [StudioObject]
    private var byID: [String: Int] = [:]

    public init(objects: [StudioObject] = []) {
        self.objects = objects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for (i, o) in self.objects.enumerated() where byID[o.id] == nil { byID[o.id] = i }
    }

    /// Reads a Studio vault (the folder holding `data/`). Missing parts read as empty.
    public init(root: URL) {
        let data = root.appending(path: "data")
        var out: [StudioObject] = []
        for kind in StudioObject.Kind.entities {
            for (slug, page) in StudioDirectory.pages(data.appending(path: "entities/" + (kind.folder ?? ""))) {
                let f = StudioDirectory.frontMatter(page)
                // The permanent id Glyph CRM writes (`id: person/john-smith`), kept through renames;
                // else the folder's.
                let fixed = f["id"].map(StudioDirectory.unquote).flatMap { StudioObject.Kind(id: $0) == kind && $0.contains("/") ? $0 : nil }
                out.append(StudioObject(id: fixed ?? "\(kind.prefix)/\(slug)", name: f["name"].map(StudioDirectory.unquote) ?? StudioDirectory.title(slug),
                                        aliases: StudioDirectory.list(f["aliases"]), kind: kind))
            }
        }
        // Orgs are one list over org pages and app records: an app whose id, title or
        // company is an org's slug shows on that org; any other app is an org of its own.
        let apps = data.appending(path: "apps")
        for dir in StudioDirectory.folders(apps) {
            let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: apps.appending(path: dir).appending(path: "manifest.json")))) as? [String: Any] ?? [:]
            let title = [m["title"], m["name"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? dir
            let keys = [m["company"] as? String, dir, title].compactMap { $0 }.map { "org/" + StudioDirectory.slug($0) }
            if let i = out.firstIndex(where: { $0.kind == .org && keys.contains($0.id) }) {
                if title.caseInsensitiveCompare(out[i].name) != .orderedSame, !out[i].aliases.contains(title) { out[i].aliases.append(title) }
                continue
            }
            let id = "org/" + StudioDirectory.slug(title)
            if id != "org/", !out.contains(where: { $0.id == id }) { out.append(StudioObject(id: id, name: title, kind: .org)) }
        }
        let missions = data.appending(path: "missions")
        for slug in StudioDirectory.folders(missions) {
            let page = (try? String(contentsOf: missions.appending(path: slug).appending(path: "mission.md"), encoding: .utf8)) ?? ""
            let name = StudioDirectory.frontMatter(page)["name"].map(StudioDirectory.unquote) ?? StudioDirectory.title(slug)
            out.append(StudioObject(id: "mission/\(slug)", name: name, kind: .project))
        }
        let domains = data.appending(path: "domains")
        for slug in StudioDirectory.folders(domains) {
            let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: domains.appending(path: slug).appending(path: "manifest.json")))) as? [String: Any]
            let label = ((m?["identity"] as? [String: Any])?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(StudioObject(id: "domain/\(slug)", name: label ?? StudioDirectory.title(slug), kind: .domain))
        }
        self.init(objects: out)
    }

    public func object(_ id: String) -> StudioObject? { byID[id].map { objects[$0] } }

    /// The object's name, or a readable form of the id when Studio no longer has it.
    public func name(_ id: String) -> String {
        object(id)?.name ?? StudioDirectory.title(String(id.split(separator: "/", maxSplits: 1).last ?? Substring(id)))
    }

    public func objects(_ kind: StudioObject.Kind) -> [StudioObject] { objects.filter { $0.kind == kind } }

    /// The object of that kind called `name` (its name, an alias or its slug, any case).
    public func match(_ name: String, _ kind: StudioObject.Kind) -> StudioObject? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let candidates = objects(kind)
        return candidates.first { ([$0.name] + $0.aliases).contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
            ?? object("\(kind.prefix)/\(StudioDirectory.slug(n))")
    }

    /// People whose name or alias `text` says as whole words.
    public func peopleMentioned(in text: String) -> [StudioObject] { mentioned(in: text, kinds: [.person]) }

    /// Objects of these kinds whose name or alias (three letters or more) `text` says as whole words.
    public func mentioned(in text: String, kinds: [StudioObject.Kind]) -> [StudioObject] {
        let hay = text.lowercased()
        return objects.filter { o in kinds.contains(o.kind) && ([o.name] + o.aliases).contains { $0.count >= 3 && mentions(hay, $0.lowercased()) } }
    }

    /// Every other object of the same kind that answers to one of this one's names: two Johns.
    public func namesakes(_ o: StudioObject) -> [StudioObject] {
        let names = Set(([o.name] + o.aliases).map { $0.lowercased() })
        return objects(o.kind).filter { $0.id != o.id && ([$0.name] + $0.aliases).contains { names.contains($0.lowercased()) } }
    }

    // MARK: reading

    /// Studio's slug: lower case, anything else `-`, no `-` at the ends.
    public static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    static func title(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Folder names that are objects (no `_` or `.` in front).
    static func folders(_ dir: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
    }

    /// `<slug>/entity.md`, or an older vault's flat `<slug>.md`.
    static func pages(_ dir: URL) -> [(String, String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for slug in folders(dir) {
            if let text = try? String(contentsOf: dir.appending(path: slug).appending(path: "entity.md"), encoding: .utf8) { out.append((slug, text)) }
        }
        let flat = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".") }
        for f in flat {
            let slug = f.deletingPathExtension().lastPathComponent
            if !out.contains(where: { $0.0 == slug }), let text = try? String(contentsOf: f, encoding: .utf8) { out.append((slug, text)) }
        }
        return out
    }

    /// `key: value` lines between the first two `---` lines.
    static func frontMatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n"), let end = text.dropFirst(4).range(of: "\n---") else { return [:] }
        var out: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, !line.hasPrefix(" ") else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// `[a, "b"]` as a list.
    static func list(_ value: String?) -> [String] {
        (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").map(unquote).filter { !$0.isEmpty }
    }

    static func unquote<S: StringProtocol>(_ s: S) -> String { Entity.unquote(s) }
}

// MARK: filing a capture

extension Vault {
    /// Sets a conversation's Studio links and tags: no repeats, tags tidied, guesses now
    /// linked dropped. Returns the new meta.
    @discardableResult
    public func setStudioLinks(_ id: String, links: [String], tags: [String]) throws -> Conversation {
        var meta = try conversation(id)
        meta.links = links.reduce(into: []) { out, l in if !out.contains(l) { out.append(l) } }
        meta.tags = tidyTags(tags)
        meta.suggested.links.removeAll { meta.links.contains($0) }
        meta.suggested.tags.removeAll { meta.tags.contains($0) }
        try write(meta)
        return meta
    }

    /// A yes or a no to one guess. A yes to a new name (`.person`) links `resolved`, the
    /// Studio id made for it; without one the name is only taken off the list.
    @discardableResult
    public func answer(_ id: String, _ link: Link, accept: Bool, resolved: String? = nil) throws -> Conversation {
        var meta = try conversation(id)
        let name = link.name
        let same = { (x: String) in x.caseInsensitiveCompare(name) == .orderedSame }
        switch link {
        case .object: meta.suggested.links.removeAll(where: same)
        case .person: meta.suggested.people.removeAll(where: same)
        case .account: meta.suggested.accounts.removeAll(where: same)
        case .tag: meta.suggested.tags.removeAll(where: same)
        }
        if !accept {
            meta.suggested.dismissed.append(name)
        } else if case .tag = link {
            meta.tags = tidyTags(meta.tags + [name])
        } else if let target = resolved ?? (link.isObject ? name : nil), !meta.links.contains(target) {
            meta.links.append(target)
        }
        try write(meta)
        return meta
    }

    /// Works out the guesses for a conversation against Studio and saves them: Studio people
    /// the call names, orgs the model heard that Studio has and the call says, people
    /// the model heard that Studio has no page for, up to three topics. Nothing linked or
    /// dismissed comes back.
    @discardableResult
    public func suggest(_ id: String, heard: Heard, studio: StudioDirectory) throws -> Conversation {
        var meta = try conversation(id)
        meta.suggested = Vault.suggestions(meta, text: transcript(id).plainText, heard: heard, studio: studio)
        try write(meta)
        return meta
    }

    static func suggestions(_ meta: Conversation, text: String, heard: Heard, studio: StudioDirectory) -> Suggested {
        let hay = (meta.title + "\n" + text).lowercased()
        var s = Suggested()
        s.dismissed = meta.suggested.dismissed
        let said = { (n: String) in mentions(hay, n.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        func add(_ o: StudioObject) {
            if !meta.links.contains(o.id), !s.dismissed.contains(o.id), !s.links.contains(o.id) { s.links.append(o.id) }
        }
        for p in studio.peopleMentioned(in: hay) { add(p) }
        for c in heard.companies where said(c) { if let o = studio.match(c, .org) { add(o) } }
        let named = (meta.links + s.links).compactMap { studio.object($0)?.name }
        for p in heard.people where said(p) {
            let name = Entity.cleanName(p)
            if let o = studio.match(name, .person) { add(o); continue }
            let taken = (s.people + s.dismissed + named).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            // "Ken" is not someone new next to a linked or suggested "Ken Lee".
            if !name.isEmpty, !taken, !(named + s.people).contains(where: { Entity.isShortForm(name, of: $0) }) { s.people.append(name) }
        }
        for t in tidyTags(heard.topics).prefix(3) where !meta.tags.contains(t) && !s.dismissed.contains(t) && !s.tags.contains(t) {
            s.tags.append(t)
        }
        return s
    }
}

extension Link {
    public var isObject: Bool { if case .object = self { true } else { false } }
}

// MARK: moving an older vault onto Studio

/// What `migrateToStudio` did: each older name, the Studio id it now is, and whether Studio
/// made a page for it. Names Studio could not take stay where they were (`unresolved`).
public struct StudioMigration: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var name: String
        public var kind: StudioObject.Kind
        public var id: String
        public var created: Bool
    }
    public var rows: [Row] = []
    public var unresolved: [String] = []
    public var conversations = 0
    /// Older notes moved out of the way, into `.memosa/migrated-to-studio/`.
    public var notesMoved = 0
    public var isEmpty: Bool { rows.isEmpty && unresolved.isEmpty && conversations == 0 && notesMoved == 0 }
}

extension Vault {
    /// Moves the older People and Accounts (notes and the names on each conversation) onto
    /// Studio ids: a name or alias Studio knows becomes its id; one it doesn't is made by
    /// `create(kind, name, notes)` (Studio's own command), which returns the new id or nil.
    /// Every note that found an id moves to `.memosa/migrated-to-studio/` (moved, never
    /// deleted), so a second run finds nothing to do. Tags stay as they are: Studio has none.
    public func migrateToStudio(_ studio: StudioDirectory,
                                create: (StudioObject.Kind, String, String) -> String?) throws -> StudioMigration {
        let notes = entities()
        let index = EntityIndex(notes)
        var report = StudioMigration()
        var ids: [String: String] = [:] // "kind|lowercased note name" -> id
        var failed = Set<String>()        // asked once this run, and Studio could not take it

        func resolve(_ kind: Entity.Kind, _ raw: String) -> String? {
            let name = index.canonical(kind, raw)
            let key = kind.rawValue + "|" + name.lowercased()
            if let id = ids[key] { return id }
            if failed.contains(key) { return nil }
            let skind: StudioObject.Kind = kind == .person ? .person : .org
            let note = notes.first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            var id = ([name] + (note?.aliases ?? [])).lazy.compactMap { studio.match($0, skind)?.id }.first
            var created = false
            if id == nil, let made = create(skind, name, note?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                id = made
                created = true
            }
            guard let id else {
                failed.insert(key)
                if !report.unresolved.contains(name) { report.unresolved.append(name) }
                return nil
            }
            ids[key] = id
            report.rows.append(.init(name: name, kind: skind, id: id, created: created))
            return id
        }

        for var meta in conversations() where !meta.people.isEmpty || !meta.accounts.isEmpty || !meta.suggested.accounts.isEmpty {
            var keep = (people: [String](), accounts: [String]())
            for p in meta.people { if let id = resolve(.person, p) { meta.links.append(id) } else { keep.people.append(p) } }
            for a in meta.accounts { if let id = resolve(.account, a) { meta.links.append(id) } else { keep.accounts.append(a) } }
            meta.links = meta.links.reduce(into: []) { out, l in if !out.contains(l) { out.append(l) } }
            (meta.people, meta.accounts) = keep
            meta.suggested.accounts = [] // older guesses; the next summary guesses against Studio
            try write(meta)
            report.conversations += 1
        }
        let away = root.appending(path: ".memosa/migrated-to-studio")
        for note in notes {
            guard resolve(note.kind, note.name) != nil else { continue }
            let from = noteURL(note.kind, note.name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            var dest = away.appending(path: note.kind.folder).appending(path: from.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dest.deletingLastPathComponent().appending(path: "\(note.name)-\(n).md")
                n += 1
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: dest)
            report.notesMoved += 1
        }
        return report
    }
}
