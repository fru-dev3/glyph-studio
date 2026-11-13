import Foundation

/// JSON written the way Memosa's serde_json writes it (`to_string_pretty`): two-space
/// indent, `"key": value`, keys in field order, `12.0` for whole seconds, `/` and
/// non-ASCII left as they are, no newline at the end. Foundation's JSONEncoder differs
/// on every one of those, and a file both apps write must not churn in git diffs.
public enum JSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSON])
    case object([(String, JSON)])

    public var pretty: String {
        var out = ""
        write(&out, indent: "")
        return out
    }

    private func write(_ out: inout String, indent: String) {
        switch self {
        case .string(let s): out += JSON.quote(s)
        case .int(let i): out += String(i)
        case .double(let d): out += JSON.number(d)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += indent + "  "
                item.write(&out, indent: indent + "  ")
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += indent + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, (key, value)) in pairs.enumerated() {
                out += indent + "  " + JSON.quote(key) + ": "
                value.write(&out, indent: indent + "  ")
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += indent + "}"
        }
    }

    /// Rust prints a whole f64 as `12.0` and otherwise the shortest round-trip form, as Swift does.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e16 { return String(Int64(d)) + ".0" }
        return String(d)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

extension Conversation {
    /// `meta.json` as written to disk.
    var json: JSON {
        var pairs: [(String, JSON)] = [
            ("schema", .int(schema)), ("id", .string(id)), ("title", .string(title)), ("created", .string(created)),
            ("duration_sec", .int(durationSec)),
            ("people", .array(people.map(JSON.string))), ("accounts", .array(accounts.map(JSON.string))),
            ("tags", .array(tags.map(JSON.string))),
        ]
        // Studio links only when there are some, so older files keep every byte.
        if !links.isEmpty { pairs.append(("links", .array(links.map(JSON.string)))) }
        if !suggested.isEmpty {
            pairs.append(("suggested", .object((suggested.links.isEmpty ? [] : [("links", .array(suggested.links.map(JSON.string)))]) + [
                ("people", .array(suggested.people.map(JSON.string))),
                ("accounts", .array(suggested.accounts.map(JSON.string))),
                ("tags", .array(suggested.tags.map(JSON.string))),
                ("dismissed", .array(suggested.dismissed.map(JSON.string))),
            ])))
        }
        pairs.append(("source", .string(source)))
        if let device { pairs.append(("device", .string(device))) }
        if let calendarEventId { pairs.append(("calendar_event_id", .string(calendarEventId))) }
        pairs.append(("audio", .string(audio)))
        if let updated { pairs.append(("updated", .string(updated))) }
        if !jots.isEmpty {
            pairs.append(("jots", .array(jots.map { j in
                var p: [(String, JSON)] = [("start", .double(j.start)), ("end", .double(j.end)), ("kind", .string(j.kind))]
                if let note = j.note { p.append(("note", .string(note))) }
                return .object(p)
            })))
        }
        return .object(pairs)
    }
}

extension Transcript {
    /// `transcript.json` as written to disk. Speakers sort by id, like Rust's BTreeMap.
    var json: JSON {
        .object([
            ("schema", .int(schema)), ("language", .string(language)), ("model", .string(model)),
            ("speakers", .object(speakers.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })),
            ("segments", .array(segments.map { s in
                .object([("start", .double(s.start)), ("end", .double(s.end)), ("speaker", .string(s.speaker)), ("text", .string(s.text))])
            })),
        ])
    }
}

// MARK: Reading JSON back with its keys in the order they were written
//
// Foundation's JSONSerialization hands back an unordered dictionary, so a file read and written
// again comes out with its keys shuffled. Glyph Connect edits six keys inside a 132-file registry
// nobody else owns, so a write has to leave every other byte where it was. This parser keeps the
// order; `pretty` puts it back exactly (checked against every manifest on disk by connect-check).

public extension JSON {
    /// Parses JSON text, keeping each object's keys in the order they appear. Nil when it is not JSON.
    static func parse(_ text: String) -> JSON? {
        var s = Scanner(text: Array(text.unicodeScalars))
        s.space()
        guard let v = s.value() else { return nil }
        s.space()
        return s.done ? v : nil
    }

    /// The value at a key, for an object.
    subscript(_ key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    var asString: String? { if case .string(let s) = self { return s }; return nil }
    var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var asArray: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var asPairs: [(String, JSON)]? { if case .object(let o) = self { return o }; return nil }
    var strings: [String] { asArray?.compactMap(\.asString) ?? [] }

    /// A key set on an object: replaced in place when it is there, appended when it is not, so the
    /// rest of the file keeps its order. Not an object: unchanged.
    func setting(_ key: String, _ value: JSON) -> JSON {
        guard case .object(let pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            var p = pairs; p[i] = (key, value); return .object(p)
        }
        return .object(pairs + [(key, value)])
    }

    /// A key taken off an object (for a setting that goes back to its default).
    func removing(_ key: String) -> JSON {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.filter { $0.0 != key })
    }

    /// `tools` mapped: the one named `name` gets `change` applied, the rest stay as they are.
    func changingTool(_ name: String, _ change: (JSON) -> JSON) -> JSON {
        guard let tools = self["tools"]?.asArray else { return self }
        return setting("tools", .array(tools.map { $0["name"]?.asString == name ? change($0) : $0 }))
    }
}

/// A scalar scanner over unicode scalars. Small on purpose: manifests are a few hundred KB at most.
private struct Scanner {
    let text: [Unicode.Scalar]
    var i = 0
    init(text: [Unicode.Scalar]) { self.text = text }
    var done: Bool { i >= text.count }
    var here: Unicode.Scalar? { i < text.count ? text[i] : nil }

    mutating func space() { while let c = here, c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1 } }

    mutating func take(_ c: Unicode.Scalar) -> Bool {
        if here == c { i += 1; return true }
        return false
    }

    mutating func word(_ s: String) -> Bool {
        let w = Array(s.unicodeScalars)
        guard i + w.count <= text.count, Array(text[i..<(i + w.count)]) == w else { return false }
        i += w.count
        return true
    }

    mutating func value() -> JSON? {
        switch here {
        case "{": return object()
        case "[": return array()
        case "\"": return string().map(JSON.string)
        case "t": return word("true") ? .bool(true) : nil
        case "f": return word("false") ? .bool(false) : nil
        case "n": return word("null") ? .null : nil
        default: return number()
        }
    }

    mutating func object() -> JSON? {
        guard take("{") else { return nil }
        var pairs: [(String, JSON)] = []
        space()
        if take("}") { return .object(pairs) }
        while true {
            space()
            guard let k = string() else { return nil }
            space()
            guard take(":") else { return nil }
            space()
            guard let v = value() else { return nil }
            pairs.append((k, v))
            space()
            if take(",") { continue }
            return take("}") ? .object(pairs) : nil
        }
    }

    mutating func array() -> JSON? {
        guard take("[") else { return nil }
        var items: [JSON] = []
        space()
        if take("]") { return .array(items) }
        while true {
            space()
            guard let v = value() else { return nil }
            items.append(v)
            space()
            if take(",") { continue }
            return take("]") ? .array(items) : nil
        }
    }

    mutating func string() -> String? {
        guard take("\"") else { return nil }
        var out = String.UnicodeScalarView()
        while let c = here {
            i += 1
            if c == "\"" { return String(out) }
            guard c == "\\" else { out.append(c); continue }
            guard let e = here else { return nil }
            i += 1
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "u":
                guard i + 4 <= text.count, let n = UInt32(String(String.UnicodeScalarView(text[i..<(i + 4)])), radix: 16) else { return nil }
                i += 4
                // A surrogate pair comes as two \u escapes; join them back into the one scalar.
                if n >= 0xD800, n <= 0xDBFF, i + 6 <= text.count, text[i] == "\\", text[i + 1] == "u",
                   let low = UInt32(String(String.UnicodeScalarView(text[(i + 2)..<(i + 6)])), radix: 16), low >= 0xDC00, low <= 0xDFFF {
                    i += 6
                    out.append(Unicode.Scalar(0x10000 + (n - 0xD800) * 0x400 + (low - 0xDC00))!)
                } else if let u = Unicode.Scalar(n) {
                    out.append(u)
                } else { return nil }
            default: return nil
            }
        }
        return nil
    }

    /// A number, kept as an int when it was written without a dot or an exponent (so `12` stays `12`
    /// and `12.0` stays `12.0`: the registry holds millisecond timestamps that must not grow a `.0`).
    mutating func number() -> JSON? {
        let start = i
        if take("-") {}
        while let c = here, c.properties.numericType != nil || c == "." || c == "e" || c == "E" || c == "+" || c == "-" { i += 1 }
        guard i > start else { return nil }
        let s = String(String.UnicodeScalarView(text[start..<i]))
        if !s.contains("."), !s.lowercased().contains("e"), let n = Int(s) { return .int(n) }
        return Double(s).map(JSON.double)
    }
}
