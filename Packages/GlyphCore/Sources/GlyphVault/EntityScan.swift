import Foundation

/// Finding the entities the vault already knows inside a piece of text, so an app can draw them as
/// links and file what was said onto their pages.
///
/// Fru, 2026-11-14: "If you see an entity like Walmart, and then Walmart is already part of an
/// entity under companies, then highlight it, and then it will save the note into my entity under
/// companies for Walmart. If you see something like John Ryan, and John Ryan is already an entity
/// under people, and I interacted with John Ryan, highlight that, create a page for them, and then
/// capture all their knowledge there."
///
/// One definition for the whole family, because the alternative is each app deciding for itself
/// what counts as a mention, and then Glyph Jot and Glyph CRM disagreeing about whether a note
/// mentioned Walmart. It reads a list and returns ranges: no files, no network, no opinion about
/// what to do with a hit, so a chat answer, a note and a dictation all scan the same way.
public struct EntityScan: Sendable {
    /// One entity as the scanner needs it: what it is called, what else it is called, and the id
    /// of the page a hit belongs to.
    public struct Known: Equatable, Sendable {
        public let id: String       // "person/john-ryan", as CRMPage writes it
        public let kind: CRMKind
        public let name: String     // the canonical name, for display
        public let aliases: [String]
        public init(id: String, kind: CRMKind, name: String, aliases: [String] = []) {
            self.id = id; self.kind = kind; self.name = name; self.aliases = aliases
        }
    }

    /// One mention: where it is, and what it is.
    public struct Hit: Equatable, Sendable {
        public let range: Range<String.Index>
        public let id: String
        public let kind: CRMKind
        public let name: String
        /// What actually appeared in the text, which may be an alias or a different case.
        public let said: String
        public init(range: Range<String.Index>, id: String, kind: CRMKind, name: String, said: String) {
            self.range = range; self.id = id; self.kind = kind; self.name = name; self.said = said
        }
    }

    /// A name this never matches on its own, because the hit would be noise on every other line.
    /// A page actually called one of these is still reachable by its longer forms and by `#tag`.
    static let tooCommon: Set<String> = [
        "a", "an", "and", "the", "it", "is", "as", "at", "be", "by", "do", "go", "he", "i", "if",
        "in", "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we", "you", "your",
        "today", "tomorrow", "yesterday", "now", "here", "there", "this", "that", "one", "two",
        "work", "home", "time", "day", "week", "month", "year", "note", "notes", "thing", "things",
    ]

    /// The shortest a name may be before it is matched by itself. Two, not three: "JR", "KC" and
    /// "GM" are shorthand someone chose on purpose, and refusing them made an alias useless for
    /// the thing aliases are for. What the floor is really guarding against is short words that
    /// are also ordinary English, and `tooCommon` is what does that. A single character is only
    /// ever a hit when it was written as a `#tag`.
    static let shortestName = 2

    /// The most words a name may run to. A longer page title is still matched; only the scan
    /// window is capped, so a five-word name is found by its first four words plus the rest, which
    /// is not worth the cost of widening every lookup.
    static let longestName = 5

    private let byName: [String: Known]
    /// Everything the register holds, in the order it was read. An app asks this for the tags, the
    /// people or the places that exist, instead of keeping a list of its own (Fru, 2026-11-14:
    /// "This should not just be independent lists of hashtags... I should read from the source of
    /// truth to only show the hashtags that are available").
    public let all: [Known]

    /// Builds the lookup once. Reuse it across a screenful of text rather than rebuilding per line:
    /// a vault with 800 entities builds about 1,800 keys.
    public init(_ known: [Known]) {
        self.all = known
        var map: [String: Known] = [:]
        for k in known {
            for n in [k.name] + k.aliases {
                let key = EntityScan.fold(n)
                guard !key.isEmpty else { continue }
                // The canonical name wins over another page's alias, and otherwise the first in
                // wins, so a scan is the same every time it runs over the same list.
                if map[key] == nil || EntityScan.fold(k.name) == key { map[key] = k }
            }
        }
        byName = map
    }

    /// Lower case, punctuation out, single spaces: "J.P. Morgan" and "jp morgan" are one key, and
    /// so are "#deep-work", "deep work" and "Deep Work".
    static func fold(_ s: String) -> String {
        let letters = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Every entity named in the text, in the order they appear, never overlapping.
    ///
    /// Longest first: "Ken Lee" is Ken Lee, not Ken and then a stray Lee. A run of words is taken
    /// whole, so "Walmart" inside "Walmartians" is not a hit.
    public func hits(in text: String) -> [Hit] {
        let words = EntityScan.words(in: text)
        var out: [Hit] = []
        var i = 0
        while i < words.count {
            var took = false
            // From the longest window down, so the fullest name wins the words it covers.
            for n in stride(from: min(EntityScan.longestName, words.count - i), through: 1, by: -1) {
                let span = words[i..<(i + n)]
                let key = span.map(\.folded).joined(separator: " ")
                guard !key.isEmpty, let found = byName[key] else { continue }
                // A single short or very common word is only a hit when it was written as a tag.
                if n == 1, !span[i].wasHash {
                    if key.count < EntityScan.shortestName || EntityScan.tooCommon.contains(key) { continue }
                }
                let range = span.first!.range.lowerBound..<span.last!.range.upperBound
                out.append(Hit(range: range, id: found.id, kind: found.kind, name: found.name,
                               said: String(text[range])))
                i += n
                took = true
                break
            }
            if !took { i += 1 }
        }
        return out
    }

    /// The first mention of each entity, which is what a reader wants underlined.
    ///
    /// Measured over a real notebook before this existed: 796 entities over 63 notes gave 202
    /// hits, and the top three were "Jot" 60 times, "iPhone 15 Pro" 52 and "Life" 12 -- entities
    /// whose names are also words he writes constantly. Marking all 60 is noise; marking the
    /// first is a link to the page. Use this for anything a person reads, and `hits` only when
    /// the count itself is the point.
    public func firstMentions(in text: String) -> [Hit] {
        var seen = Set<String>()
        return hits(in: text).filter { seen.insert($0.id).inserted }
    }

    /// A word of the text: where it is, how it folds, and whether it was written as a `#tag`.
    struct Word {
        let range: Range<String.Index>
        let folded: String
        let wasHash: Bool
    }

    /// The text split into words, keeping each one's place. A `#` is part of the word it opens, so
    /// "#deep-work" is one word that folds to "deep work" and remembers it was a tag; everything
    /// else that is not a letter or a number separates.
    static func words(in text: String) -> [Word] {
        var out: [Word] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber || text[i] == "#" else {
                i = text.index(after: i); continue
            }
            let start = i
            let hash = text[i] == "#"
            if hash { i = text.index(after: i) }
            // A hashtag runs through its dashes and underscores: "#deep-work" is one word.
            while i < text.endIndex, text[i].isLetter || text[i].isNumber || (hash && (text[i] == "-" || text[i] == "_")) {
                i = text.index(after: i)
            }
            guard i > start else { i = text.index(after: start); continue }
            let folded = fold(String(text[start..<i]))
            if folded.isEmpty { continue }
            out.append(Word(range: start..<i, folded: folded, wasHash: hash))
        }
        return out
    }
}

public extension EntityScan {
    /// The names the register holds of one kind, in the order read: the tags that exist, the
    /// people, the places. An app offers these rather than its own list.
    func names(of kind: CRMKind) -> [String] { all.filter { $0.kind == kind }.map(\.name) }

    /// What the vault knows, read once a session and kept here so a screen can mark a name without
    /// asking anyone. `Hub.understand` fills it on the first turn, which every app's chat goes
    /// through, so no app has to remember to read the register.
    ///
    /// Nil means "not read yet", and a screen marks nothing rather than guessing: a half-read
    /// register would underline some of the names and silently miss the rest, which reads as the
    /// app not knowing about them.
    @MainActor static var shared: EntityScan?
}

public extension EntityScan.Known {
    /// Reads a page the way the vault stores it, so the scanner and Glyph CRM always agree about
    /// what a page is called.
    init?(page: CRMPage) {
        guard let kind = CRMKind(prefix: page.kind), !page.name.isEmpty else { return nil }
        self.init(id: page.permanentID ?? "\(kind.dir)/\(CRMPage.slug(page.name))", kind: kind,
                  name: page.name, aliases: page.aliases)
    }
}
