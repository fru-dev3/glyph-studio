import CryptoKit
import Foundation

/// A domain's source/goals.md, edited line by line so every line nobody changed is written back
/// byte for byte (VAULT.md "A domain"; engine goals.ts and projects.ts parseGoalLine):
///
///     - [ ] Run the river loop twice a week ~id:g-3f2a ~status:active ~due:2026-12-31 ~progress:40
///       why: I think better after a run.
///       reason: enjoy
///       outcome: Clear-headed mornings
///       obstacle: I stay up late
///       plan: If it is 7am Tuesday, then I run before email
///       floor: once a week
///       stretch: three times a week
///       never: knees
///       measure: runs per week ~from:garmin
///       stop: a knee injury
///       review: 2027-01-15
///       focus: in
///       helps: g-sleep
///       pulls: g-overtime
///
/// The goal line carries `~id ~status ~due ~progress ~objective` tokens; `[x]` is done. `why:`
/// stays the first line under the goal, because the engine's parseGoals reads only the line right
/// after a goal as its why. The other keys are the compass's WOOP keys (outcome:, obstacle:, plan:,
/// compass.ts) plus Studio's outcome fields. Unknown indented lines are safe: parseGoals reads only
/// goal lines and that one why: line, and every engine writer of goals.md (appendGoals,
/// compass-chain linkGoal) keeps the other lines as they are; VAULT.md: "Other lines are kept."
struct GoalsDoc: Equatable, Sendable {
    enum Key: String, CaseIterable, Sendable {
        case why, reason, outcome, obstacle, plan, floor, stretch, never, measure, stop, review, focus, helps, pulls
    }

    private enum Piece: Equatable, Sendable {
        case line(String)
        /// lines[0] is the goal line, then its indented lines.
        case goal(id: String, lines: [String])
    }

    let domain: String
    private var pieces: [Piece]
    private let eol: String

    init(text: String, domain: String) {
        self.domain = domain
        let lines = text.components(separatedBy: "\n")
        eol = lines.first?.hasSuffix("\r") == true ? "\r" : ""
        var out: [Piece] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let g = Self.goalLine(line) else { out.append(.line(line)); i += 1; continue }
            var block = [line]
            let at = i
            while i + 1 < lines.count, Self.isContinuation(lines[i + 1]) { i += 1; block.append(lines[i]) }
            out.append(.goal(id: g.tokens["id"] ?? "g-\(domain)-\(at)", lines: block)) // goals.ts fallback id
            i += 1
        }
        pieces = out
    }

    var text: String {
        pieces.flatMap { p -> [String] in
            switch p {
            case .line(let l): [l]
            case .goal(_, let l): l
            }
        }.joined(separator: "\n")
    }

    var outcomes: [Outcome] { pieces.compactMap { if case .goal(let id, let l) = $0 { Self.outcome(id: id, lines: l) } else { nil } } }

    func outcome(_ id: String) -> Outcome? { outcomes.first { $0.id == id } }

    // MARK: edits

    struct Missing: LocalizedError { var id: String; var errorDescription: String? { "No outcome \(id) in goals.md." } }

    /// Writes only what differs between the outcome on file and `o`: unchanged fields keep their lines.
    mutating func save(_ o: Outcome) throws {
        guard let old = outcome(o.id) else { throw Missing(id: o.id) }
        if old.title != o.title { try edit(o.id) { $0[0] = Self.retitle($0[0], o.title) } }
        if old.done != o.done || old.status != o.status {
            try setToken("status", o.status, on: o.id)
            try edit(o.id) { $0[0] = Self.box($0[0], done: o.done) }
        }
        if old.due != o.due { try setToken("due", o.due, on: o.id) }
        if old.progress != o.progress { try setToken("progress", o.progress.map { String(max(0, min(100, $0))) }, on: o.id) }
        if old.objective != o.objective { try setToken("objective", o.objective, on: o.id) }
        let single: [(Key, String?, String?)] = [
            (.why, old.why, o.why), (.reason, old.reason?.rawValue, o.reason?.rawValue), (.outcome, old.pictured, o.pictured),
            (.obstacle, old.obstacle, o.obstacle), (.plan, old.plan, o.plan), (.floor, old.floor, o.floor), (.stretch, old.stretch, o.stretch),
            (.stop, old.stopWhen, o.stopWhen), (.review, old.review, o.review), (.focus, old.focus?.rawValue, o.focus?.rawValue),
        ]
        for (key, a, b) in single where a != b { try set(key, b.map { [$0] } ?? [], on: o.id) }
        if old.neverSacrifice != o.neverSacrifice { try set(.never, o.neverSacrifice, on: o.id) }
        if old.measures != o.measures { try set(.measure, o.measures, on: o.id) }
        if old.helps != o.helps { try set(.helps, o.helps.isEmpty ? [] : [o.helps.joined(separator: ", ")], on: o.id) }
        if old.pulls != o.pulls { try set(.pulls, o.pulls.isEmpty ? [] : [o.pulls.joined(separator: ", ")], on: o.id) }
    }

    /// Sets a field's lines: existing lines of `key` are replaced in place (keeping their indent),
    /// extra ones removed, new ones added after the goal's last line (`why:` right under the goal).
    /// An empty list removes the field.
    mutating func set(_ key: Key, _ values: [String], on id: String) throws {
        let eol = eol
        try edit(id) { lines in
            let values = values.map(Self.clean).filter { !$0.isEmpty }
            let at = lines.indices.dropFirst().filter { Self.field(lines[$0])?.key == key.rawValue }
            for (n, i) in at.enumerated() where n < values.count {
                let indent = String(lines[i].prefix { $0 == " " || $0 == "\t" })
                lines[i] = "\(indent)\(key.rawValue): \(values[n])\(eol)"
            }
            for i in at.dropFirst(values.count).reversed() { lines.remove(at: i) }
            let fresh = values.dropFirst(at.count).map { "  \(key.rawValue): \($0)\(eol)" }
            if !fresh.isEmpty { lines.insert(contentsOf: fresh, at: key == .why ? 1 : (at.last.map { $0 + 1 } ?? lines.count)) }
        }
    }

    /// Sets (or with nil removes) a `~key:value` token on the goal line, in place.
    mutating func setToken(_ key: String, _ value: String?, on id: String) throws {
        try edit(id) { $0[0] = Self.token($0[0], key, value.map { Self.clean($0).replacingOccurrences(of: " ", with: "-") }) }
    }

    /// Adds `- [ ] Title ~id:g-x ~status:active` after the last goal (as appendGoals does) and returns its id.
    @discardableResult
    mutating func add(_ title: String) -> String {
        let title = Self.clean(title.replacingOccurrences(of: "\u{2014}", with: ", "))
        let id = Self.goalID(domain: domain, title: title)
        if outcome(id) != nil { return id }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces = [.line("# \(domain) goals\(eol)"), .line(eol), .line("")] }
        let piece = Piece.goal(id: id, lines: ["- [ ] \(title) ~id:\(id) ~status:active\(eol)"])
        if let last = pieces.lastIndex(where: { if case .goal = $0 { true } else { false } }) {
            pieces.insert(piece, at: last + 1)
        } else if case .line("") = pieces.last, pieces.count > 1 {
            pieces.insert(piece, at: pieces.count - 1) // before the final newline
        } else { pieces.append(piece) }
        return id
    }

    private mutating func edit(_ id: String, _ change: (inout [String]) -> Void) throws {
        guard let i = pieces.firstIndex(where: { if case .goal(id, _) = $0 { true } else { false } }),
              case .goal(_, var lines) = pieces[i] else { throw Missing(id: id) }
        change(&lines)
        pieces[i] = .goal(id: id, lines: lines)
    }

    // MARK: grammar

    /// `^\s*[-*]\s+\[([ xX])\]\s+(.+)$`, with `(^|\s)~([a-z_]+):(\S+)` tokens (projects.ts).
    static func goalLine(_ line: String) -> (done: Bool, title: String, tokens: [String: String])? {
        var s = Substring(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        s = s.drop { $0 == " " || $0 == "\t" }
        guard let bullet = s.first, bullet == "-" || bullet == "*" else { return nil }
        s = s.dropFirst()
        guard s.first?.isWhitespace == true else { return nil }
        s = s.drop { $0.isWhitespace }
        guard s.count >= 3, s.first == "[", let mark = s.dropFirst().first, " xX".contains(mark), s.dropFirst(2).first == "]" else { return nil }
        s = s.dropFirst(3)
        guard s.first?.isWhitespace == true else { return nil }
        let rest = s.drop { $0.isWhitespace }
        guard !rest.isEmpty else { return nil }
        var tokens: [String: String] = [:]
        var words: [Substring] = []
        for w in rest.split(whereSeparator: \.isWhitespace) {
            if w.first == "~", let colon = w.firstIndex(of: ":"), colon > w.index(after: w.startIndex),
               w[w.index(after: w.startIndex)..<colon].allSatisfy({ $0.isLowercase || $0 == "_" }), w.index(after: colon) < w.endIndex {
                tokens[String(w[w.index(after: w.startIndex)..<colon])] = String(w[w.index(after: colon)...])
            } else { words.append(w) }
        }
        return (mark != " ", words.joined(separator: " "), tokens)
    }

    static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first, first == " " || first == "\t" else { return false }
        return line.contains { !$0.isWhitespace } && goalLine(line) == nil
    }

    /// `^\s+([a-z][a-z0-9_ -]*):\s*(.*)$` (compass.ts), key lowercased, quotes taken off the value.
    static func field(_ line: String) -> (key: String, value: String)? {
        guard line.first == " " || line.first == "\t", let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard let k = key.first, k.isLetter, key.allSatisfy({ $0.isLetter || $0.isNumber || " _-".contains($0) }) else { return nil }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return (key.lowercased(), value)
    }

    private static func outcome(id: String, lines: [String]) -> Outcome? {
        guard let g = goalLine(lines[0]) else { return nil }
        var o = Outcome(id: id, title: g.title, done: g.done)
        o.status = g.tokens["status"] ?? (g.done ? "done" : "active")
        o.due = g.tokens["due"]
        o.progress = g.tokens["progress"].flatMap { Int($0) }
        o.objective = g.tokens["objective"]
        let list = { (s: String) in s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        for line in lines.dropFirst() {
            guard let f = field(line), let key = Key(rawValue: f.key) else { continue }
            let v = f.value
            switch key {
            case .why: o.why = o.why ?? v
            case .reason: o.reason = ReasonTag(loose: v)
            case .outcome: o.pictured = v
            case .obstacle: o.obstacle = v
            case .plan: o.plan = v
            case .floor: o.floor = v
            case .stretch: o.stretch = v
            case .never: o.neverSacrifice.append(v)
            case .measure: o.measures.append(v)
            case .stop: o.stopWhen = v
            case .review: o.review = v
            case .focus: o.focus = Focus(loose: v)
            case .helps: o.helps += list(v)
            case .pulls: o.pulls += list(v)
            }
        }
        return o
    }

    private static func token(_ line: String, _ key: String, _ value: String?) -> String {
        let cr = line.hasSuffix("\r") ? "\r" : ""
        var parts = line.dropLast(cr.count).components(separatedBy: " ")
        if let i = parts.firstIndex(where: { $0.hasPrefix("~\(key):") }) {
            if let value { parts[i] = "~\(key):\(value)" } else { parts.remove(at: i) }
            return parts.joined(separator: " ") + cr
        }
        guard let value else { return line }
        return line.dropLast(cr.count).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + " ~\(key):\(value)" + cr
    }

    private static func box(_ line: String, done: Bool) -> String {
        guard let r = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return line }
        let now = line[r] != "[ ]"
        return now == done ? line : line.replacingCharacters(in: r, with: done ? "[x]" : "[ ]")
    }

    /// Replaces the words of a goal line, keeping its bullet, box and tokens.
    private static func retitle(_ line: String, _ title: String) -> String {
        guard let r = line.range(of: #"\[[ xX]\]\s+"#, options: .regularExpression) else { return line }
        let cr = line.hasSuffix("\r") ? "\r" : ""
        let tokens = line[r.upperBound...].dropLast(cr.count).split(separator: " ").filter { $0.hasPrefix("~") && $0.contains(":") }
        return String(line[..<r.upperBound]) + ([clean(title)] + tokens.map(String.init)).joined(separator: " ") + cr
    }

    static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// goals.ts goalIdFor: `g-` + the first 6 hex of sha1("<domain>\n<normalised title>").
    static func goalID(domain: String, title: String) -> String {
        let kept = String(title.lowercased().map { (c: Character) -> Character in c.isASCII && (c.isLetter || c.isNumber) ? c : " " })
        let norm = kept.split(separator: " ").joined(separator: " ")
        let digest = Insecure.SHA1.hash(data: Data("\(domain)\n\(norm)".utf8))
        return "g-" + digest.map { String(format: "%02x", $0) }.joined().prefix(6)
    }
}
