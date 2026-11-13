import Foundation

/// The vault: a folder the person owns. Any directory with a `meta.json` is a
/// conversation, any other directory a folder (top-level ones are domains).
/// `People/`, `Accounts/` and dot folders are not part of the tree. Disk always wins:
/// nothing here caches.
public struct Vault: Sendable {
    public let root: URL
    /// The time stamped into `updated`. Tests pin it.
    let now: @Sendable () -> Date

    public init(root: URL) { self.init(root: root, now: { Date() }) }

    init(root: URL, now: @escaping @Sendable () -> Date) {
        self.root = root
        self.now = now
    }

    public struct Node: Equatable, Sendable {
        public enum Kind: String, Sendable { case domain, folder, conversation }
        public var kind: Kind
        public var name: String
        public var path: String
        public var children: [Node] = []
        /// Conversations at any depth below (0 for a conversation).
        public var count: Int {
            kind == .conversation ? 0 : children.reduce(0) { $0 + ($1.kind == .conversation ? 1 : $1.count) }
        }
    }

    public struct Directory: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            public var entity: Entity
            /// Conversations linked to it (an account counts its people's calls too).
            public var count: Int
        }
        public var entities: [Row]
        public var tags: [(name: String, count: Int)]

        public static func == (a: Directory, b: Directory) -> Bool {
            a.entities == b.entities && a.tags.map { "\($0.name)=\($0.count)" } == b.tags.map { "\($0.name)=\($0.count)" }
        }
    }

    /// The file URL of a vault path, like a conversation id. `.` and `..` parts are
    /// dropped, so a path never leads outside the vault.
    public func url(_ rel: String) -> URL {
        Vault.clean(rel).split(separator: "/").reduce(root) { $0.appending(path: String($1)) }
    }

    // MARK: tree

    public func tree() -> [Node] { children(of: root, rel: "", top: true) }

    private func children(of dir: URL, rel: String, top: Bool) -> [Node] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var nodes: [Node] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = item.lastPathComponent
            if name.hasPrefix(".") || (top && Entity.isNoteFolder(name)) { continue }
            let path = rel.isEmpty ? name : rel + "/" + name
            if fm.fileExists(atPath: item.appending(path: "meta.json").path) {
                nodes.append(Node(kind: .conversation, name: name, path: path))
            } else {
                nodes.append(Node(kind: top ? .domain : .folder, name: name, path: path, children: children(of: item, rel: path, top: false)))
            }
        }
        return nodes.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: read

    public func conversation(_ id: String) throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: url(id).appending(path: "meta.json")))
    }

    /// Every conversation, newest first.
    public func conversations() -> [Conversation] {
        conversationPaths().compactMap { try? conversation($0) }.sorted { $0.created > $1.created }
    }

    public func transcript(_ id: String) -> Transcript {
        let file = url(id).appending(path: "transcript.json")
        return (try? JSONDecoder().decode(Transcript.self, from: Data(contentsOf: file))) ?? Transcript()
    }

    public func notes(_ id: String) -> Notes {
        guard let md = try? String(contentsOf: url(id).appending(path: "notes.md"), encoding: .utf8) else { return Notes() }
        return Notes(markdown: md)
    }

    /// Every person and account note, sorted by name.
    public func entities() -> [Entity] {
        Entity.Kind.allCases.flatMap { kind -> [Entity] in
            let dir = root.appending(path: kind.folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { f in
                let name = f.deletingPathExtension().lastPathComponent
                guard f.pathExtension == "md", !name.hasPrefix("."), let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
                return Entity(kind: kind, name: name, text: text)
            }
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// People, accounts and tags with how many calls each has.
    public func directory() -> Directory {
        let all = entities()
        let index = EntityIndex(all)
        let convs = conversations()
        let rows = all.map { e in Directory.Row(entity: e, count: convs.filter { index.links($0, e.kind, e.name) }.count) }
        var counts: [String: Int] = [:]
        for c in convs { for t in c.tags { counts[t, default: 0] += 1 } }
        let tags = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return Directory(entities: rows, tags: tags)
    }

    /// Conversations directly inside `folder` ("" is the vault root), newest first.
    public func conversations(in folder: String) -> [Conversation] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url(folder), includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path) }
            .compactMap { try? conversation(Vault.join(folder, $0.lastPathComponent)) }
            .sorted { $0.created > $1.created }
    }

    /// Conversations linked to a person or account (an account also gets its people's
    /// calls), or carrying a tag (any case). Newest first.
    public func conversations(linkedTo link: Link) -> [Conversation] {
        let all = conversations()
        switch link {
        case .person(let name), .account(let name):
            let index = EntityIndex(entities())
            let kind: Entity.Kind = if case .person = link { .person } else { .account }
            return all.filter { index.links($0, kind, name) }
        case .tag(let tag):
            return all.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        case .object(let id):
            return all.filter { $0.links.contains(id) }
        }
    }

    /// Every action item in every `notes.md`, newest conversation first, in note order.
    public func tasks() -> [VaultTask] {
        conversations().flatMap { c in notes(c.id).actions.map { VaultTask(conversation: c.id, title: c.title, item: $0) } }
    }

    /// Every person and account name and alias: the words to teach speech recognition.
    public func knownNames() -> [String] {
        var seen = Set<String>()
        return entities().flatMap { [$0.name] + $0.aliases }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Conversations whose notes or transcript contain the phrase (any case).
    public func search(_ phrase: String) -> [String] {
        let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return conversationPaths().filter { id in
            Notes.stripFrontMatter(notes(id).markdown).lowercased().contains(needle)
                || transcript(id).plainText.lowercased().contains(needle)
        }.sorted()
    }

    /// The path of every conversation folder.
    public func conversationPaths() -> [String] {
        func walk(_ n: Node) -> [String] { n.kind == .conversation ? [n.path] : n.children.flatMap(walk) }
        return tree().flatMap(walk)
    }
}
