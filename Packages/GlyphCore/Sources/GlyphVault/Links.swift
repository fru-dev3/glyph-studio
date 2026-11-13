import Foundation

// Links on a conversation (people, accounts, topic tags) and the suggestions waiting
// for a yes. Mirrors Memosa's vault_links.rs.

/// Names an on-device model heard in a transcript. Only names the transcript really
/// says are ever suggested.
public struct Heard: Equatable, Sendable {
    public var people: [String]
    public var companies: [String]
    public var topics: [String]

    public init(people: [String] = [], companies: [String] = [], topics: [String] = []) {
        self.people = people
        self.companies = companies
        self.topics = topics
    }
}

extension Vault {
    /// Sets a conversation's people, accounts and tags: names resolve through aliases
    /// and lose repeats, tags are tidied (`#Q4 Renewal` is `q4-renewal`). A name without
    /// a note gets a stub note. Suggestions now linked are dropped. Returns the new meta.
    @discardableResult
    public func setLinks(_ id: String, people: [String], accounts: [String], tags: [String]) throws -> Conversation {
        let index = EntityIndex(entities())
        var meta = try conversation(id)
        meta.people = index.tidy(.person, people)
        meta.accounts = index.tidy(.account, accounts)
        meta.tags = tidyTags(tags)
        try ensureNotes(index, .person, meta.people)
        try ensureNotes(index, .account, meta.accounts)
        let has = { (list: [String], x: String) in list.contains { $0.caseInsensitiveCompare(x) == .orderedSame } }
        meta.suggested.people.removeAll { has(meta.people, $0) }
        meta.suggested.accounts.removeAll { has(meta.accounts, $0) }
        meta.suggested.tags.removeAll { has(meta.tags, $0) }
        try write(meta)
        return meta
    }

    /// Says yes (links it) or no (remembers it in `dismissed`, so it never comes back)
    /// to one suggestion. Returns the new meta.
    @discardableResult
    public func answerSuggestion(_ id: String, _ link: Link, accept: Bool) throws -> Conversation {
        var meta = try conversation(id)
        let name = link.name
        let drop = { (list: inout [String]) in list.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame } }
        switch link {
        case .person: drop(&meta.suggested.people)
        case .account: drop(&meta.suggested.accounts)
        case .tag: drop(&meta.suggested.tags)
        case .object: drop(&meta.suggested.links)
        }
        guard accept else {
            meta.suggested.dismissed.append(name)
            try write(meta)
            return meta
        }
        var (people, accounts, tags) = (meta.people, meta.accounts, meta.tags)
        switch link {
        case .person: people.append(name)
        case .account: accounts.append(name)
        case .tag: tags.append(name)
        case .object: meta.links.append(name)
        }
        try write(meta)
        return try setLinks(id, people: people, accounts: accounts, tags: tags)
    }

    /// Creates or edits a person or account note. With `oldName`, the note is renamed
    /// and the name is rewritten in every conversation's meta.json and, for an account,
    /// in every person who works there. A person's new account gets a stub note.
    public func saveEntity(_ entity: Entity, renamingFrom oldName: String? = nil) throws {
        var e = entity
        e.name = Entity.cleanName(e.name)
        e.aliases = e.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        e.account = e.kind == .person ? e.account?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if e.account?.isEmpty == true { e.account = nil }
        guard !e.name.isEmpty else { throw VaultError.nameNeeded }

        let dest = noteURL(e.kind, e.name)
        if let old = oldName.map(Entity.cleanName), old != e.name {
            let from = noteURL(e.kind, old)
            let fm = FileManager.default
            // On a case-insensitive disk a case-only rename finds itself at dest.
            let sameFile = old.caseInsensitiveCompare(e.name) == .orderedSame
            if fm.fileExists(atPath: dest.path), !sameFile { throw VaultError("\(e.name) already exists.") }
            if fm.fileExists(atPath: from.path) {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: dest)
            }
        }
        try Vault.atomicWrite(dest, e.rendered)
        if let account = e.account { try ensureNotes(EntityIndex(entities()), .account, [account]) }

        guard let old = oldName, old.caseInsensitiveCompare(e.name) != .orderedSame else { return }
        let swap = { (list: [String]) in list.map { $0.caseInsensitiveCompare(old) == .orderedSame ? e.name : $0 } }
        for var meta in conversations() {
            let before = (meta.people, meta.accounts)
            if e.kind == .person { meta.people = swap(meta.people) } else { meta.accounts = swap(meta.accounts) }
            if before != (meta.people, meta.accounts) { try write(meta) }
        }
        if e.kind == .account {
            for var person in entities() where person.kind == .person && person.account?.caseInsensitiveCompare(old) == .orderedSame {
                person.account = e.name
                try Vault.atomicWrite(noteURL(.person, person.name), person.rendered)
            }
        }
    }

    /// Works out the suggestions for a conversation and saves them on it: notes whose
    /// name or alias the call says, names the model heard that the call really says, a
    /// person's account, up to three topics. Nothing linked or dismissed comes back.
    @discardableResult
    public func suggest(_ id: String, heard: Heard = Heard()) throws -> Conversation {
        let all = entities()
        var meta = try conversation(id)
        meta.suggested = Vault.suggestions(meta, text: transcript(id).plainText, entities: all, index: EntityIndex(all), heard: heard)
        try write(meta)
        return meta
    }

    static func suggestions(_ meta: Conversation, text: String, entities: [Entity], index: EntityIndex, heard: Heard) -> Suggested {
        let hay = (meta.title + "\n" + text).lowercased()
        var s = Suggested()
        s.dismissed = meta.suggested.dismissed
        let same = { (a: String, b: String) in a.caseInsensitiveCompare(b) == .orderedSame }
        func taken(_ linked: [String], _ x: String) -> Bool { (linked + s.dismissed).contains { same($0, x) } }
        func add(_ kind: Entity.Kind, _ name: String) {
            guard !name.isEmpty, !taken(kind == .person ? meta.people : meta.accounts, name) else { return }
            if kind == .person {
                if !s.people.contains(where: { same($0, name) }) { s.people.append(name) }
            } else if !s.accounts.contains(where: { same($0, name) }) {
                s.accounts.append(name)
            }
        }

        for e in entities where ([e.name] + e.aliases).contains(where: { mentions(hay, $0.lowercased()) }) {
            add(e.kind, e.name)
        }
        for p in heard.people where mentions(hay, p.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            add(.person, index.canonical(.person, Entity.cleanName(p)))
        }
        for c in heard.companies where mentions(hay, c.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            add(.account, index.canonical(.account, Entity.cleanName(c)))
        }
        // A suggested or linked person brings their account along.
        for p in meta.people + s.people {
            if let account = index.account(of: p) { add(.account, account) }
        }
        // "Ken" is not a second person next to a linked or suggested "Ken Lee".
        let named = meta.people + s.people
        s.people.removeAll { p in named.contains { Entity.isShortForm(p, of: $0) } }
        for t in tidyTags(heard.topics).prefix(3) where !taken(meta.tags, t) && !s.tags.contains(t) {
            s.tags.append(t)
        }
        return s
    }

    // MARK: helpers

    func noteURL(_ kind: Entity.Kind, _ name: String) -> URL {
        root.appending(path: kind.folder).appending(path: Entity.cleanName(name) + ".md")
    }

    /// A stub note for each name that has none yet.
    func ensureNotes(_ index: EntityIndex, _ kind: Entity.Kind, _ names: [String]) throws {
        for n in names where !index.isKnown(kind, n) {
            let stub = Entity(kind: kind, name: n)
            guard !stub.name.isEmpty else { continue }
            try Vault.atomicWrite(noteURL(kind, stub.name), stub.rendered)
        }
    }
}
