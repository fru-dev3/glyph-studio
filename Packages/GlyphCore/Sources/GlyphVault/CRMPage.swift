import Foundation

// Glyph CRM's entity page (moved from CRMKit 2026-10-30 so app agents write the same bytes; CRMKit aliases these
// as Page, Kind and Link). The page format is a contract with Glyph Bot's engine: run CRM/scripts/engine-roundtrip.sh
// after any change here.

/// The four kinds of entity. Storage is Glyph Bot's: `data/entities/<dir>/<slug>/entity.md`,
/// id `<prefix>/<slug>`. Orgs were spelled `product` in the Swift until 2026-11-09 (Fru: "use orgs
/// instead of products. standardize once adn for all"). The folder and the prefix were `orgs` and
/// `org/` all along, so the name now matches what is on disk and not one page moves.
public enum CRMKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case person, place, org, thing, event
    public var id: String { rawValue }
    /// The four Entities; Events sit under Activities with Projects, as in Glyph Bot.
    public static let entities: [CRMKind] = [.person, .place, .org, .thing]

    public var prefix: String { rawValue }
    public var dir: String {
        switch self {
        case .person: "people"
        case .place: "places"
        case .org: "orgs"
        case .thing: "things"
        case .event: "events"
        }
    }
    public var label: String {
        switch self {
        case .person: "People"
        case .place: "Places"
        case .org: "Orgs"
        case .thing: "Things"
        case .event: "Events"
        }
    }
    public var singular: String {
        switch self {
        case .person: "Person"
        case .place: "Place"
        case .org: "Org"
        case .thing: "Thing"
        case .event: "Event"
        }
    }
    public var symbol: String {
        switch self {
        case .person: "person.2"
        case .place: "mappin.and.ellipse"
        case .org: "building.2"
        case .thing: "applewatch"
        case .event: "calendar"
        }
    }
    /// Rows written before the rename say "product". Decoding goes through the raw value, not
    /// through `init?(prefix:)`, so it has to be read here or every proposal and merge already on
    /// disk stops decoding the day this ships.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let k = CRMKind(rawValue: raw == "product" ? "org" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "no CRM kind called \(raw)"))
        }
        self = k
    }

    /// "product" is still read, so a page, a plan or a caller written before the rename lands.
    public init?(prefix: String) {
        let p = prefix == "product" || prefix == "products" ? "org" : prefix
        guard let k = CRMKind.allCases.first(where: { $0.prefix == p || $0.dir == p }) else { return nil }
        self = k
    }
}

/// A typed link from one entity to another: "owned by" Ken Lee, "located in" Westmark.
/// Kept on the page it starts from; the other side is worked out when reading.
public struct CRMLink: Hashable, Codable, Sendable {
    public var to: String  // an entity id, or "me" (the owner of the vault)
    public var `as`: String
    public init(to: String, as label: String) {
        self.to = to
        self.as = label
    }
}

/// One entity page, read and written exactly the way Glyph Bot's engine does
/// (`renderPage` in its entities.ts), so either can write it and neither loses the other's
/// work. Unknown front matter keys are kept verbatim and in order. Glyph CRM adds two, both
/// single-line JSON (the engine keeps unknown keys only while they stay on one line):
///
///     attributes: {"Plate": "LT 482 CE", "Color": "Blue"}
///     links: [{"to": "person/ken-lee", "as": "owned by"}, {"to": "place/westmark", "as": "located in"}]
public struct CRMPage: Equatable, Sendable {
    public var name: String
    public var kind: String  // person | place | org | thing | event, as written
    public var aliases: [String] = []
    public var saved = false
    public var created = ""
    public var updated = ""
    public var mentionCount = 0
    public var domain: String?
    public var website: String?
    public var picture: String?
    public var extra: [(key: String, value: String)] = []
    public var preamble = ""
    public var discussed = ""
    public var notes = ""
    public var conversations = ""

    public static let hDiscussed = "What you've discussed", hNotes = "Your notes", hConvos = "Conversations"
    public static let emptyDiscussed = "_Nothing summarized yet._", emptyConvos = "_No conversations yet._"

    public init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }

    public static func == (a: CRMPage, b: CRMPage) -> Bool { a.render() == b.render() }

    // MARK: reading

    public init(text md: String, slug: String, kind fallback: String) {
        self.init(name: slug, kind: fallback)
        var body = Substring(md)
        if md.hasPrefix("---\n"), let end = md.dropFirst(4).range(of: "\n---") {
            let lines = md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var rest = md[end.upperBound...]
            if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] } else { rest = "" }
            body = rest
            var i = 0
            while i < lines.count {
                defer { i += 1 }
                guard let (key, raw) = CRMPage.keyValue(lines[i]) else { continue }
                let val = CRMPage.unquote(raw.trimmingCharacters(in: .whitespaces))
                if key == "aliases" && raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    var items: [String] = []
                    while i + 1 < lines.count, let item = CRMPage.dashItem(lines[i + 1]) { items.append(item); i += 1 }
                    aliases = items.filter { !$0.isEmpty }
                    continue
                }
                switch key {
                case "name": name = val.isEmpty ? name : val
                case "kind": kind = val
                case "aliases": aliases = CRMPage.list(raw)
                case "saved": saved = val == "true"
                case "created": created = val
                case "updated": updated = val
                case "mention_count": mentionCount = Int(val) ?? 0
                case "domain": domain = val.isEmpty ? nil : val
                case "website": website = val.isEmpty ? nil : val
                case "picture": picture = val.isEmpty ? nil : val
                default: extra.append((key, raw))
                }
            }
        }
        // Split on the three known headings only; a "## " of the person's own stays in notes.
        let text = String(body)
        let known = [CRMPage.hDiscussed, CRMPage.hNotes, CRMPage.hConvos]
        var cuts: [(h: String, start: String.Index, end: String.Index)] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if line.hasPrefix("## ") {
                let h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if known.contains(h) { cuts.append((h, lineStart, lineEnd)) }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        preamble = (cuts.first.map { String(text[..<$0.start]) } ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        for (n, cut) in cuts.enumerated() {
            let stop = n + 1 < cuts.count ? cuts[n + 1].start : text.endIndex
            let section = CRMPage.trimSection(String(text[cut.end..<stop]))
            switch cut.h {
            case CRMPage.hDiscussed: discussed = section == CRMPage.emptyDiscussed ? "" : section
            case CRMPage.hNotes: notes = section
            default: conversations = section == CRMPage.emptyConvos ? "" : section
            }
        }
    }

    public static func keyValue(_ line: String) -> (String, String)? {
        guard let first = line.first, first.isLetter || first == "_", let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), key.allSatisfy(\.isASCII) else { return nil }
        let raw = line[line.index(after: colon)...].drop(while: { $0 == " " || $0 == "\t" })
        return (key, String(raw))
    }

    public static func dashItem(_ line: String) -> String? {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        guard t.hasPrefix("- ") || t.hasPrefix("-\t") else { return nil }
        return unquote(t.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// Leading newlines and trailing whitespace off, as the engine does.
    public static func trimSection(_ s: String) -> String {
        var t = Substring(s)
        while t.first == "\n" { t = t.dropFirst() }
        while let l = t.last, l.isWhitespace { t = t.dropLast() }
        return String(t)
    }

    public static func unquote(_ s: String) -> String {
        var t = s
        if let f = t.first, f == "\"" || f == "'" { t.removeFirst() }
        if let l = t.last, l == "\"" || l == "'" { t.removeLast() }
        return t
    }

    /// `[a, "b"]` (JSON or YAML flow) or a bare value, as a list.
    public static func list(_ v: String) -> [String] {
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return [] }
        if s.hasPrefix("[") {
            if let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                return a.map { "\($0)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let inner = s.dropFirst().prefix(while: { $0 != "]" })
            return inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        }
        return [unquote(s)]
    }

    // MARK: writing

    /// The engine's `yamlStr`: plain when safe, else a JSON string.
    public static func yamlStr(_ s: String) -> String {
        let plain = s.range(of: #"^[\w .,'()&+-]*$"#, options: .regularExpression) != nil
        let risky = s.range(of: #"^[\s-]|:\s|\s$"#, options: .regularExpression) != nil
            || s.range(of: #"^(true|false|null|\d)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return plain && !risky && !s.isEmpty ? s : json(s)
    }

    /// One JSON string, on one line, slashes kept readable.
    public static func json(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    public func render() -> String {
        var fm = ["---", "name: \(CRMPage.yamlStr(name))", "kind: \(kind)", "aliases: [\(aliases.map(CRMPage.yamlStr).joined(separator: ", "))]",
                  "saved: \(saved)", "created: \(created)", "updated: \(updated)", "mention_count: \(mentionCount)"]
        if let domain { fm.append("domain: \(domain)") }
        if let website { fm.append("website: \(CRMPage.yamlStr(website))") }
        if let picture { fm.append("picture: \(CRMPage.yamlStr(picture))") }
        fm += extra.map { "\($0.key): \($0.value)" }
        fm += ["---", ""]
        var out = fm
        if !preamble.isEmpty { out += [preamble, ""] }
        if !discussed.isEmpty { out += ["## \(CRMPage.hDiscussed)", "", discussed, ""] }
        out += ["## \(CRMPage.hNotes)", "", notes]
        if !notes.isEmpty { out.append("") }
        out += ["## \(CRMPage.hConvos)", "", conversations.isEmpty ? CRMPage.emptyConvos : conversations, ""]
        return out.joined(separator: "\n")
    }

    // MARK: Glyph CRM's keys

    public func extraValue(_ key: String) -> String? { extra.first { $0.key == key }?.value }

    public mutating func setExtra(_ key: String, _ value: String?) {
        if let value {
            if let i = extra.firstIndex(where: { $0.key == key }) { extra[i].value = value } else { extra.append((key, value)) }
        } else {
            extra.removeAll { $0.key == key }
        }
    }

    /// The page's permanent id, `id: person/ken-lee`: what notes write (`entities: [person/ken-lee]`)
    /// and links point at. Set once, when the page is made (or by scripts/assign-ids.py), and never
    /// changed, so a rename or a moved folder never breaks a reference.
    public var permanentID: String? {
        get { extraValue("id").map { CRMPage.unquote($0) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { setExtra("id", newValue.map(CRMPage.oneLine)) }
    }

    /// Attributes in the order they were written.
    public var attributes: [(key: String, value: String)] {
        get {
            guard let raw = extraValue("attributes"), let data = raw.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            let pairs = map.map { (key: $0.key, value: ($0.value as? String) ?? "\($0.value)") }
            func at(_ k: String) -> Int { raw.range(of: CRMPage.json(k) + ":").map { raw.distance(from: raw.startIndex, to: $0.lowerBound) } ?? Int.max }
            return pairs.sorted { at($0.key) < at($1.key) }
        }
        set {
            let kept = newValue.map { (key: CRMPage.oneLine($0.key), value: CRMPage.oneLine($0.value)) }.filter { !$0.key.isEmpty }
            setExtra("attributes", kept.isEmpty ? nil : "{" + kept.map { "\(CRMPage.json($0.key)): \(CRMPage.json($0.value))" }.joined(separator: ", ") + "}")
        }
    }

    public var links: [CRMLink] {
        get {
            guard let raw = extraValue("links"), let data = raw.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return list.compactMap { d in
                guard let to = d["to"] as? String, !to.isEmpty else { return nil }
                return CRMLink(to: to, as: (d["as"] as? String) ?? "related to")
            }
        }
        set {
            var seen = Set<CRMLink>()
            let kept = newValue.filter { !$0.to.isEmpty && seen.insert($0).inserted }
            setExtra("links", kept.isEmpty ? nil : "[" + kept.map { "{\"to\": \(CRMPage.json(CRMPage.oneLine($0.to))), \"as\": \(CRMPage.json(CRMPage.oneLine($0.as)))}" }.joined(separator: ", ") + "]")
        }
    }

    public static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Notes as dated paragraphs, the engine's `note --append`: "2026-10-28: text".
    public mutating func appendNote(_ text: String, on day: String) {
        let para = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !para.isEmpty else { return }
        notes = (notes.isEmpty ? "" : notes + "\n\n") + "\(day): \(para)"
    }

    /// A new page the person made: saved, dated now.
    public static func new(name: String, kind: CRMKind, now: Date = Date()) -> CRMPage {
        var p = CRMPage(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind.prefix)
        p.saved = true
        p.created = CRMPage.iso(now)
        p.updated = p.created
        return p
    }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Glyph Bot's slug: lower case ASCII letters and digits, anything else one `-`.
    public static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

/// Whether a page's text keeps Glyph CRM's keys on one line (the hub refuses one that does not).
public func keysAreSingleLine(_ md: String) -> Bool {
    guard md.hasPrefix("---\n"), let end = md.dropFirst(4).range(of: "\n---") else { return true }
    let lines = md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() where line == "links:" || line == "attributes:" || line.hasPrefix("links: ") || line.hasPrefix("attributes: ") {
        let value = line.split(separator: ":", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
        if value.isEmpty { return false }
        if i + 1 < lines.count, let next = lines[i + 1].first, next == " " || next == "\t" { return false }
    }
    return true
}
