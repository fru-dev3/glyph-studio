import Foundation

/// A person or an account (a company, a client): a note at `People/<Name>.md` or
/// `Accounts/<Name>.md`. The front matter holds `aliases` and, for a person, the
/// `account` they work at; the rest is free notes. A call with a person is also a
/// call with their account: worked out when reading, never written into the call.
public struct Entity: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case person, account
        public var folder: String { self == .person ? "People" : "Accounts" }
    }

    public var kind: Kind
    public var name: String
    public var aliases: [String] = []
    public var account: String?
    public var body = ""

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = Entity.cleanName(name)
    }

    /// The top-level folders that hold notes, not conversations.
    public static func isNoteFolder(_ name: String) -> Bool { name == "People" || name == "Accounts" }

    /// Safe as a file name: no path separators, no leading dot.
    public static func cleanName(_ name: String) -> String {
        let mapped = String(name.map { "/\\:".contains($0) ? "-" : $0 })
        let trimmed = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "." })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a note. A file without front matter is all body.
    public init(kind: Kind, name: String, text: String) {
        self.init(kind: kind, name: name)
        var rest = Substring(text)
        if text.hasPrefix("---\n"), let end = text.dropFirst(4).range(of: "\n---") {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                switch kv[0].trimmingCharacters(in: .whitespaces) {
                case "aliases":
                    aliases = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map(Entity.unquote).filter { !$0.isEmpty }
                case "account" where kind == .person:
                    let a = Entity.unquote(Substring(value))
                    account = a.isEmpty ? nil : a
                default:
                    break
                }
            }
            rest = text[end.upperBound...]
            if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        }
        body = String(rest.drop(while: { $0 == "\n" }))
    }

    static func unquote<S: StringProtocol>(_ s: S) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespaces)
    }

    public var rendered: String {
        var front = "---\nkind: \(kind.rawValue)\n"
        if let a = account, !a.isEmpty { front += "account: \(a)\n" }
        if !aliases.isEmpty { front += "aliases: [\(aliases.joined(separator: ", "))]\n" }
        return front + "---\n\n" + body.drop(while: { $0 == "\n" })
    }
}

extension Entity {
    /// Whether `short` is a shorter way of saying the person `full`: each of its words
    /// starts the matching word of `full` ("Ken" or "Ken L." for "Ken Lee"), and it is
    /// not the same name.
    public static func isShortForm(_ short: String, of full: String) -> Bool {
        let words = { (s: String) in s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }
        let a = words(short), b = words(full)
        guard !a.isEmpty, a.count <= b.count, a != b else { return false }
        return zip(a, b).allSatisfy { $1.hasPrefix($0) }
    }

    /// The one person in `people` that `name` is a short form of, or `name` itself when
    /// it names none of them or more than one.
    public static func fullName(_ name: String, among people: [String]) -> String {
        let hits = people.filter { isShortForm(name, of: $0) }
        return hits.count == 1 ? hits[0] : name
    }
}

/// Resolves names and aliases to the note they belong to.
public struct EntityIndex: Sendable {
    private var names: [String: String] = [:] // "kind|lowercased name or alias" -> note name
    private var personAccount: [String: String] = [:] // lowercased person -> account note name

    public init(_ entities: [Entity]) {
        for e in entities {
            for n in e.aliases + [e.name] { names[EntityIndex.key(e.kind, n)] = e.name }
        }
        for e in entities where e.kind == .person {
            if let a = e.account { personAccount[e.name.lowercased()] = canonical(.account, a) }
        }
    }

    static func key(_ kind: Entity.Kind, _ name: String) -> String {
        kind.rawValue + "|" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The note's name for a name or alias; the trimmed name itself if unknown.
    public func canonical(_ kind: Entity.Kind, _ name: String) -> String {
        names[EntityIndex.key(kind, name)] ?? name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isKnown(_ kind: Entity.Kind, _ name: String) -> Bool { names[EntityIndex.key(kind, name)] != nil }

    public func account(of person: String) -> String? { personAccount[canonical(.person, person).lowercased()] }

    /// Whether a conversation links to a person or account. An account also matches
    /// every call with one of its people.
    public func links(_ c: Conversation, _ kind: Entity.Kind, _ name: String) -> Bool {
        let want = canonical(kind, name).lowercased()
        switch kind {
        case .person:
            return c.people.contains { canonical(.person, $0).lowercased() == want }
        case .account:
            return c.accounts.contains { canonical(.account, $0).lowercased() == want }
                || c.people.contains { account(of: $0)?.lowercased() == want }
        }
    }
}

extension EntityIndex {
    /// Canonical, de-duplicated names (any case), first spelling wins.
    public func tidy(_ kind: Entity.Kind, _ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            let c = canonical(kind, Entity.cleanName(n))
            if !c.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { out.append(c) }
        }
        return out
    }
}

/// Topic tags: lower case, no `#`, words joined by `-`, no repeats.
public func tidyTags(_ tags: [String]) -> [String] {
    var out: [String] = []
    for t in tags {
        let bare = t.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" })
        let tag = bare.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
    }
    return out
}

/// Whether `needle` appears in `hay` as whole words. Both are already lower case;
/// a needle shorter than two characters never matches.
func mentions(_ hay: String, _ needle: String) -> Bool {
    guard needle.count >= 2 else { return false }
    let isWord = { (c: Character?) in c.map { $0.isLetter || $0.isNumber } ?? false }
    var from = hay.startIndex
    while let r = hay.range(of: needle, range: from..<hay.endIndex) {
        let before = r.lowerBound > hay.startIndex ? hay[hay.index(before: r.lowerBound)] : nil
        let after = r.upperBound < hay.endIndex ? hay[r.upperBound] : nil
        if !isWord(before) && !isWord(after) { return true }
        from = hay.index(after: r.lowerBound)
    }
    return false
}
