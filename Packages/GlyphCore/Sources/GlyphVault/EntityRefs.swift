import Foundation

/// The `entities:` line in a note's front matter: which entity pages a note is about, by their
/// permanent ids (`entities: ["person/ken-lee", "place/springfield"]`). Glyph Jot writes it,
/// Glyph CRM adds to it when the user accepts a suggestion, and every app reads it the same way. One line,
/// JSON strings in brackets; bare words (`[person/ken-lee]`) are read too. Only this line changes.
public enum EntityRefs {
    /// The ids a note names, in order.
    public static func ids(in note: String) -> [String] {
        guard let (_, line) = find(note) else { return [] }
        return list(String(line.dropFirst("entities:".count)))
    }

    /// The note with `ids` added to its `entities:` line (made at the end of the front matter, or a
    /// front matter made for it); nil when every id is there already.
    public static func adding(_ ids: [String], to note: String) -> String? {
        let old = self.ids(in: note)
        let new = ids.filter { !$0.isEmpty && !old.contains($0) }
        guard !new.isEmpty else { return nil }
        let line = "entities: [" + (old + new).map(quote).joined(separator: ", ") + "]"
        if let (range, _) = find(note) { return note.replacingCharacters(in: range, with: line) }
        if note.hasPrefix("---\n"), let end = note.range(of: "\n---", range: note.index(note.startIndex, offsetBy: 3)..<note.endIndex) {
            return note.replacingCharacters(in: end.lowerBound..<end.lowerBound, with: "\n" + line)
        }
        return "---\n\(line)\n---\n\n" + note
    }

    /// Whether `new` is `old` with only its `entities:` line added or changed: the one edit a
    /// writer may make to another app's note.
    public static func onlyEntitiesChanged(_ old: String, _ new: String) -> Bool {
        func strip(_ s: String) -> String {
            var s = s
            if let (r, _) = find(s) { s.replaceSubrange(r, with: "entities: []") }
            if s.hasPrefix("---\nentities: []\n---\n\n") { s.removeFirst("---\nentities: []\n---\n\n".count) }
            return s.replacingOccurrences(of: "\nentities: []\n---", with: "\n---")
        }
        return strip(old) == strip(new) && Set(ids(in: old)).isSubset(of: Set(ids(in: new)))
    }

    static func find(_ note: String) -> (Range<String.Index>, Substring)? {
        guard note.hasPrefix("---\n"), let end = note.range(of: "\n---", range: note.index(note.startIndex, offsetBy: 3)..<note.endIndex) else { return nil }
        var start = note.index(note.startIndex, offsetBy: 4)
        while start < end.lowerBound {
            let stop = note[start...].firstIndex(of: "\n") ?? note.endIndex
            if note[start..<stop].hasPrefix("entities:") { return (start..<stop, note[start..<stop]) }
            start = note.index(after: stop)
        }
        return nil
    }

    static func list(_ raw: String) -> [String] {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return t.isEmpty ? [] : [t] }
        return t.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
