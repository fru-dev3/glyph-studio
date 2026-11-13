import Foundation

/// Changing one value in a JSON file without touching a byte of the rest of it.
///
/// Reprinting the file cannot do that. The vault's app registry alone is written in three dialects:
/// 125 manifests use two-space members one per line, six write short arrays inline
/// (`"domains": ["records", "tax"]`), and one uses Foundation's `"key" : value` with a space before
/// the colon and its keys sorted. Any single printer churns the other two, and Glyph Connect edits
/// six keys inside 132 files that other tools own.
///
/// So this does not print. It finds the bytes of the one value and splices over them, keeping the
/// file's own indent, its own spacing around the colon and its own line endings. A file Connect has
/// never written keeps every byte it had; a file it has written differs only in the values it was
/// asked to change.
public enum JSONEdit {
    /// One member of an object: its key, and where its value's bytes are.
    public struct Member {
        public var key: String
        public var keyStart: String.Index
        public var valueRange: Range<String.Index>
        /// The whole member including its key, for taking it out again.
        public var wholeRange: Range<String.Index>
    }

    /// An object's shape in the text: its members, where to put a new one, and how this file writes.
    public struct Shape {
        public var members: [Member]
        public var open: String.Index          // just after "{"
        public var close: String.Index         // the "}"
        public var indent: String              // what this object's members are indented by
        public var colon: String               // ": " or " : ", whichever this file uses
        public var multiline: Bool
        public func member(_ key: String) -> Member? { members.first { $0.key == key } }
    }

    /// The top-level object's shape, or nil when the text is not an object.
    public static func shape(_ text: String) -> Shape? {
        var s = Walker(text: text)
        s.space()
        return s.object()
    }

    /// `text` with `key` set to `literal` (already JSON: `false`, `"a"`, `["x"]`). A key that is
    /// there is replaced in place; one that is not is added after the last member, in this file's
    /// own style. `literal` nil takes the key out.
    public static func set(_ text: String, key: String, to literal: String?, in shape: Shape? = nil) -> String {
        guard let sh = shape ?? Self.shape(text) else { return text }
        if let m = sh.member(key) {
            guard let literal else { return removing(text, m, sh) }
            var out = text
            out.replaceSubrange(m.valueRange, with: literal)
            return out
        }
        guard let literal else { return text }
        return adding(text, key: key, literal: literal, sh)
    }

    /// The same, inside the object in `tools` whose `"name"` is `tool`. Nothing else in the array
    /// moves, and the tool's other keys keep their order.
    public static func setInTool(_ text: String, tool: String, key: String, to literal: String?) -> String {
        guard let top = shape(text), let tools = top.member("tools") else { return text }
        var w = Walker(text: text)
        w.i = tools.valueRange.lowerBound
        guard let items = w.arrayObjects() else { return text }
        guard let hit = items.first(where: { o in
            guard let n = o.member("name") else { return false }
            return String(text[n.valueRange]) == "\"" + tool + "\""
        }) else { return text }
        return set(text, key: key, to: literal, in: hit)
    }

    /// Every object in `tools`, so a bulk change ("no write tool may run unattended") walks them
    /// once. Returned newest-last, and a caller editing several must redo the shapes after each
    /// splice, because the indices move. `AppRegistry.setTools` does that by editing one at a time.
    public static func toolNames(_ text: String) -> [(name: String, kind: String)] {
        guard let top = shape(text), let tools = top.member("tools") else { return [] }
        var w = Walker(text: text)
        w.i = tools.valueRange.lowerBound
        guard let items = w.arrayObjects() else { return [] }
        return items.compactMap { o in
            guard let n = o.member("name") else { return nil }
            let name = String(text[n.valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let kind = o.member("kind").map { String(text[$0.valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? "write"
            return (name, kind)
        }
    }

    /// A new member after the last one, in this file's own style.
    static func adding(_ text: String, key: String, literal: String, _ sh: Shape) -> String {
        var out = text
        let quoted = "\"" + key + "\""
        if let last = sh.members.last {
            let piece = sh.multiline ? ",\n\(sh.indent)\(quoted)\(sh.colon)\(literal)" : ", \(quoted)\(sh.colon)\(literal)"
            out.insert(contentsOf: piece, at: last.wholeRange.upperBound)
        } else {
            // An empty object: "{}" becomes "{ "k": v }" on one line, which is this file's style too.
            out.replaceSubrange(sh.open..<sh.close, with: " \(quoted)\(sh.colon)\(literal) ")
        }
        return out
    }

    /// A member taken out, with its separator, so no stray comma is left.
    static func removing(_ text: String, _ m: Member, _ sh: Shape) -> String {
        var out = text
        guard let n = sh.members.firstIndex(where: { $0.key == m.key }) else { return text }
        if n > 0 {
            // From the end of the one before it, which eats the comma and the newline between them.
            out.removeSubrange(sh.members[n - 1].wholeRange.upperBound..<m.wholeRange.upperBound)
        } else if sh.members.count > 1 {
            // The first of several: up to the start of the next one, which eats its own comma.
            out.removeSubrange(m.wholeRange.lowerBound..<sh.members[1].wholeRange.lowerBound)
        } else {
            out.replaceSubrange(sh.open..<sh.close, with: "")
        }
        return out
    }
}

/// A scanner that keeps where things are rather than what they are. It only has to be right about
/// spans, so it skips over values without building them.
private struct Walker {
    let text: String
    var i: String.Index
    init(text: String) { self.text = text; i = text.startIndex }
    var done: Bool { i >= text.endIndex }
    var here: Character? { i < text.endIndex ? text[i] : nil }

    mutating func space() { while let c = here, c == " " || c == "\n" || c == "\r" || c == "\t" { i = text.index(after: i) } }
    mutating func take(_ c: Character) -> Bool {
        if here == c { i = text.index(after: i); return true }
        return false
    }

    /// The object starting at `i`, with each member's key and value span.
    mutating func object() -> JSONEdit.Shape? {
        guard here == "{" else { return nil }
        let objStart = i
        i = text.index(after: i)
        let open = i
        var members: [JSONEdit.Member] = []
        var indent = "  ", colon = ": "
        space()
        if here == "}" { return JSONEdit.Shape(members: [], open: open, close: i, indent: indent, colon: colon, multiline: false) }
        var first = true
        while true {
            space()
            let keyStart = i
            guard let key = string() else { return nil }
            if first {
                // The file's own style, read off its first member: the indent before the key and
                // whatever sits between the key and the value.
                let line = text[open..<keyStart]
                if let nl = line.lastIndex(of: "\n") { indent = String(line[line.index(after: nl)...]) }
                let afterKey = i
                var probe = self
                probe.space()
                _ = probe.take(":")
                probe.space()
                colon = String(text[afterKey..<probe.i]).replacingOccurrences(of: "\n", with: " ")
                if colon.isEmpty || !colon.contains(":") { colon = ": " }
                first = false
            }
            space()
            guard take(":") else { return nil }
            space()
            let valueStart = i
            guard skipValue() else { return nil }
            members.append(JSONEdit.Member(key: key, keyStart: keyStart, valueRange: valueStart..<i, wholeRange: keyStart..<i))
            space()
            if take(",") { continue }
            guard here == "}" else { return nil }
            let close = i
            i = text.index(after: i)
            return JSONEdit.Shape(members: members, open: open, close: close, indent: indent, colon: colon,
                                  multiline: text[objStart..<close].contains("\n"))
        }
    }

    /// Every object directly inside the array starting at `i`.
    mutating func arrayObjects() -> [JSONEdit.Shape]? {
        guard here == "[" else { return nil }
        i = text.index(after: i)
        var out: [JSONEdit.Shape] = []
        space()
        if take("]") { return out }
        while true {
            space()
            if here == "{" {
                guard let o = object() else { return nil }
                out.append(o)
            } else {
                guard skipValue() else { return nil }
            }
            space()
            if take(",") { continue }
            return take("]") ? out : nil
        }
    }

    /// Moves past one value, whatever it is, leaving `i` just after its last byte.
    mutating func skipValue() -> Bool {
        switch here {
        case "{":
            return object() != nil
        case "[":
            i = text.index(after: i)
            var depth = 1
            while let c = here {
                if c == "\"" { guard string() != nil else { return false }; continue }
                i = text.index(after: i)
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1; if depth == 0 { return true } }
            }
            return false
        case "\"":
            return string() != nil
        default:
            let start = i
            while let c = here, !" \n\r\t,}]".contains(c) { i = text.index(after: i) }
            return i > start
        }
    }

    /// A string, leaving `i` just after the closing quote. Returns its unescaped value, which is
    /// enough to match a key or a tool's name.
    mutating func string() -> String? {
        guard take("\"") else { return nil }
        var out = ""
        while let c = here {
            i = text.index(after: i)
            if c == "\"" { return out }
            if c == "\\" {
                guard let e = here else { return nil }
                i = text.index(after: i)
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u":
                    var n = 0
                    while n < 4, here != nil { i = text.index(after: i); n += 1 }
                    out.append("?")   // a key or a tool name never needs one; the span is what matters
                default: out.append(e)
                }
                continue
            }
            out.append(c)
        }
        return nil
    }
}
