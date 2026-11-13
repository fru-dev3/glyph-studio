import Foundation
import CryptoKit

// Glyph Omega's formats (moved from OmegaKit 2026-10-30 so its agent writes the same bytes; OmegaKit aliases
// them as Format, DomainGoal, NextAction, Compass, CompassEntry). The vault's goal formats, read and edited as plain text (VAULT.md is the spec):
//
//   build/compass.md                  the Compass: ## Purpose, ## Values, ## Vision, ## Objectives,
//                                     ## Goals (life-level, shown here as Ambitions), ## Preferences ...
//   data/domains/<d>/source/goals.md  "- [ ] Title ~id:g-x ~status:active|done|archived ~due:D
//                                     ~progress:0-100 ~objective:o-x", then an indented "why:" line
//   data/domains/<d>/memory/tasks.md  "- [ ] Text @due ~goal:g-x": the next actions that serve a goal
//
// Every edit changes only the line it is about; every other byte is written back as it was.

public struct OmegaGoal: Identifiable, Hashable, Sendable {
    public var id: String
    public var domain: String
    public var title: String
    public var status: String      // active | done | archived (anything else is kept as written)
    public var due: String?
    public var progress: Int?
    public var objective: String?
    public var why: String?
    public var done: Bool
    public var said: String? = nil   // ~said:<capture>: the spoken words it came from (data/apps/omega/captures/<capture>.md)
    public var key: String { "\(domain)/\(id)" }
    public var isActive: Bool { !done && status == "active" }
}

public struct OmegaAction: Identifiable, Hashable, Sendable {
    public var id: String { "\(domain)#\(text)" }
    public var domain: String
    public var text: String        // the task's words, tokens removed
    public var line: String        // the whole line as written (how an edit finds it)
    public var done: Bool
    public var due: String?
    public var goal: String?
}

public struct OmegaCompassEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var tokens: [String: String]
    public var words: String?      // the user's own words, quoted under the line
    public var done: Bool
    public var proposed: Bool { tokens["status"] == "proposed" }
    public var archived: Bool { tokens["status"] == "archived" }
    /// A preference's scope (design, writing, brand, agents...) and strength (soft unless said strong).
    public var scope: String { tokens["scope"] ?? "general" }
    public var strong: Bool { tokens["strength"] == "strong" }
}

public struct OmegaCompass: Sendable {
    public var purpose = ""
    public var purposeProposed = false
    public var values: [OmegaCompassEntry] = []
    public var missions: [OmegaCompassEntry] = []     // ## Mission statement: what you do, for whom
    public var visions: [OmegaCompassEntry] = []
    public var objectives: [OmegaCompassEntry] = []
    public var ambitions: [OmegaCompassEntry] = []
    public var preferences: [OmegaCompassEntry] = []  // ## Preferences: softer than goals, read by every agent
    public init() {}
}

public enum OmegaFormat {
    // MARK: Tokens

    static let tokenRE = try! NSRegularExpression(pattern: #"(^|\s)~([a-z][a-z0-9_-]*):(\S+)"#)
    static let boxRE = try! NSRegularExpression(pattern: #"^(\s*[-*]\s+)\[([ xX])\]\s+(.*)$"#)

    /// The words of a line with its `~key:value` tokens taken out, and the tokens.
    public static func split(_ s: String) -> (title: String, tokens: [String: String]) {
        var tokens: [String: String] = [:]
        let ns = s as NSString
        for m in tokenRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            tokens[ns.substring(with: m.range(at: 2))] = ns.substring(with: m.range(at: 3))
        }
        let title = tokenRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
        return (title.split(whereSeparator: \.isWhitespace).joined(separator: " "), tokens)
    }

    /// A checkbox line: its prefix ("- "), whether it is ticked, and the rest.
    static func box(_ line: String) -> (prefix: String, done: Bool, rest: String)? {
        let ns = line as NSString
        guard let m = boxRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)) != " ", ns.substring(with: m.range(at: 3)))
    }

    /// Sets (or, with nil, removes) tokens on one line, keeping the others where they are.
    public static func setTokens(_ line: String, _ set: [String: String?]) -> String {
        var out = line
        for (k, v) in set.sorted(by: { $0.key < $1.key }) {
            let re = try! NSRegularExpression(pattern: #"\s~"# + NSRegularExpression.escapedPattern(for: k) + #":\S+"#)
            let ns = out as NSString
            let r = NSRange(location: 0, length: ns.length)
            if let v, !v.isEmpty {
                if re.firstMatch(in: out, range: r) != nil {
                    out = re.stringByReplacingMatches(in: out, range: r, withTemplate: NSRegularExpression.escapedTemplate(for: " ~\(k):\(v)"))
                } else {
                    out = out.omegaTrimmedTrailingSpaces + " ~\(k):\(v)"
                }
            } else {
                out = re.stringByReplacingMatches(in: out, range: r, withTemplate: "")
            }
        }
        return out
    }

    /// The same short id the engine gives (sha1 of kind or domain and the normalized title).
    public static func shortID(_ prefix: String, _ seed: String, _ title: String) -> String {
        let norm = title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let digest = Insecure.SHA1.hash(data: Data("\(seed)\n\(norm)".utf8))
        return prefix + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(6)
    }

    /// Goal titles are prose: a spaced em or en dash becomes a comma (the engine's rule).
    public static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\x{2014}\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\x{2013}\s+"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    public static func today(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    /// Appends a line at the end of a list, so the file keeps exactly one final newline.
    static func append(_ text: String, _ line: String) -> String {
        var t = text
        while t.hasSuffix("\n\n") { t.removeLast() }
        if !t.isEmpty && !t.hasSuffix("\n") { t += "\n" }
        return t + line + "\n"
    }

    // MARK: Domain goals (source/goals.md)

    public static func goals(_ domain: String, _ text: String) -> [OmegaGoal] {
        let ls = lines(text)
        var out: [OmegaGoal] = []
        for (i, l) in ls.enumerated() {
            guard let b = box(l), !l.hasPrefix(" "), !l.hasPrefix("\t") else { continue }
            let (title, t) = split(b.rest)
            var why: String?
            if i + 1 < ls.count, let r = ls[i + 1].range(of: #"^\s+why:\s*"#, options: .regularExpression) {
                why = String(ls[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            out.append(OmegaGoal(id: t["id"] ?? "g-\(domain)-\(i)", domain: domain, title: title,
                                  status: t["status"] ?? (b.done ? "done" : "active"), due: t["due"],
                                  progress: t["progress"].flatMap { Int($0) }.map { min(100, max(0, $0)) },
                                  objective: t["objective"], why: why?.isEmpty == true ? nil : why, done: b.done, said: t["said"]))
        }
        return out
    }

    /// The index of a goal's line, by its id.
    static func goalLine(_ ls: [String], _ id: String) -> Int? {
        ls.firstIndex { box($0) != nil && $0.contains("~id:\(id)") && ($0.hasSuffix("~id:\(id)") || $0.contains("~id:\(id) ")) }
    }

    /// A new goal at the end of the list. Returns the text and the goal's id.
    public static func addGoal(_ text: String, domain: String, title: String, due: String? = nil, objective: String? = nil, said: String? = nil) -> (String, String) {
        let t = clean(title)
        var id = shortID("g", domain, t)
        var n = 2
        while goalLine(lines(text), id) != nil { id = shortID("g", domain, "\(t) \(n)"); n += 1 }
        var line = "- [ ] \(t) ~id:\(id) ~status:active"
        if let due { line += " ~due:\(due)" }
        if let objective { line += " ~objective:\(objective)" }
        if let said { line += " ~said:\(said)" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("# \(domain) goals\n\n\(line)\n", id) }
        return (append(text, line), id)
    }

    /// Changes one goal: tokens (nil removes), title, why, done.
    public static func editGoal(_ text: String, id: String, tokens: [String: String?] = [:], title: String? = nil,
                                why: String?? = nil, done: Bool? = nil) -> String {
        var ls = lines(text)
        guard let i = goalLine(ls, id), let b = box(ls[i]) else { return text }
        var rest = b.rest
        if let title {
            let toks = split(rest).tokens
            let order = rest.components(separatedBy: " ").filter { $0.hasPrefix("~") }
            rest = ([clean(title)] + (order.isEmpty ? toks.map { "~\($0.key):\($0.value)" } : order)).joined(separator: " ")
        }
        var isDone = b.done
        var set = tokens
        if let done {
            isDone = done
            set["status"] = done ? "done" : "active"   // progress stays as it was: a done goal shows a tick, and undoing loses nothing
        }
        ls[i] = setTokens("\(b.prefix)[\(isDone ? "x" : " ")] \(rest)", set)
        if let why {
            let hasWhy = i + 1 < ls.count && ls[i + 1].range(of: #"^\s+why:"#, options: .regularExpression) != nil
            let w = why.map(clean) ?? ""
            if hasWhy {
                if w.isEmpty { ls.remove(at: i + 1) } else { ls[i + 1] = "  why: \(w)" }
            } else if !w.isEmpty {
                ls.insert("  why: \(w)", at: i + 1)
            }
        }
        return ls.joined(separator: "\n")
    }

    // MARK: Next actions (memory/tasks.md)

    public static func actions(_ domain: String, _ text: String) -> [OmegaAction] {
        lines(text).compactMap { l in
            guard let b = box(l) else { return nil }
            let (title, t) = split(b.rest)
            let due = title.range(of: #"(^|\s)@(\d{4}-\d{2}-\d{2})"#, options: .regularExpression).map {
                String(title[$0]).trimmingCharacters(in: .whitespaces).dropFirst().description
            }
            let words = title.replacingOccurrences(of: #"(^|\s)[@+]\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s~[a-z][a-z0-9_-]*(?=\s|$)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return OmegaAction(domain: domain, text: words, line: l, done: b.done, due: due, goal: t["goal"])
        }
    }

    /// A new next action for a goal, at the end of the task list.
    public static func addAction(_ text: String, words: String, goal: String?, due: String? = nil, said: String? = nil) -> String {
        var line = "- [ ] \(clean(words))"
        if let due { line += " @\(due)" }
        if let goal { line += " ~goal:\(goal)" }
        if let said { line += " ~said:\(said)" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "# Tasks\n\n\(line)\n" }
        return append(text, line)
    }

    /// Ticks or unticks a task (found by its exact line): ~closed: is the day it was ticked.
    public static func setActionDone(_ text: String, line: String, done: Bool, today: String = OmegaFormat.today()) -> String {
        var ls = lines(text)
        guard let i = ls.firstIndex(of: line), let b = box(line) else { return text }
        ls[i] = setTokens("\(b.prefix)[\(done ? "x" : " ")] \(b.rest)", ["closed": done ? today : nil])
        return ls.joined(separator: "\n")
    }

    /// Links an existing task to a goal (or unlinks it with nil).
    public static func linkAction(_ text: String, line: String, goal: String?) -> String {
        var ls = lines(text)
        guard let i = ls.firstIndex(of: line) else { return text }
        ls[i] = setTokens(line, ["goal": goal])
        return ls.joined(separator: "\n")
    }

    // MARK: The Compass (build/compass.md)

    static let sectionKind: [String: String] = [
        "purpose": "purpose", "core belief": "purpose", "values": "value", "mission statement": "statement", "vision": "vision",
        "objectives": "objective", "strategic objectives": "objective", "goals": "goal", "preferences": "preference",
    ]

    public static func compass(_ text: String) -> OmegaCompass {
        var c = OmegaCompass()
        var kind: String?
        var purpose: [String] = []
        var current: (kind: String, lines: [String])?
        func flush() {
            guard let cur = current, let first = cur.lines.first else { return }
            var rest = String(first.drop { $0 == "-" || $0 == " " })
            var done = false
            if let r = rest.range(of: #"^\[( |x|X)\]\s+"#, options: .regularExpression) {
                done = rest[r].lowercased().contains("x")
                rest = String(rest[r.upperBound...])
            }
            let (title, t) = split(rest)
            var words: String?
            for l in cur.lines.dropFirst() {
                if let r = l.range(of: #"^\s+words:\s*"#, options: .regularExpression) {
                    words = String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                }
            }
            let prefix = ["value": "v", "statement": "st", "vision": "vi", "objective": "o", "goal": "g", "preference": "p"][cur.kind] ?? "x"
            let e = OmegaCompassEntry(id: t["id"] ?? shortID(prefix, cur.kind, title), title: title, tokens: t, words: words, done: done)
            switch cur.kind {
            case "value": c.values.append(e)
            case "statement": c.missions.append(e)
            case "vision": c.visions.append(e)
            case "objective": c.objectives.append(e)
            case "goal": c.ambitions.append(e)
            case "preference": c.preferences.append(e)
            default: break
            }
            current = nil
        }
        for l in lines(text) {
            if l.hasPrefix("## ") {
                flush()
                kind = sectionKind[l.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()] ?? "other"
                continue
            }
            if l.hasPrefix("# ") { flush(); kind = nil; continue }
            guard let k = kind else { continue }
            if k == "purpose" {
                let s = l.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("~") { if s.contains("~status:proposed") { c.purposeProposed = true } }
                else if !l.hasPrefix("  ") && !s.isEmpty { purpose.append(s) }
                continue
            }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { flush(); current = (k, [l]) }
            else if l.hasPrefix(" "), current != nil { current!.lines.append(l) }
            else if l.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
        }
        flush()
        c.purpose = purpose.joined(separator: " ")
        c.values.sort { Int($0.tokens["rank"] ?? "") ?? 99 < Int($1.tokens["rank"] ?? "") ?? 99 }
        return c
    }

    static let order = ["Purpose", "Values", "Mission statement", "Vision", "Objectives", "Goals", "Preferences", "Roles",
                        "Non-negotiables", "Negotiables", "Capacity", "Routines"]

    /// The range of a section's body (the lines after its heading, up to the next ## heading).
    static func section(_ ls: [String], _ title: String) -> Range<Int>? {
        guard let h = ls.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## " + title.lowercased() }) else { return nil }
        let end = ls[(h + 1)...].firstIndex { $0.hasPrefix("## ") } ?? ls.count
        return (h + 1)..<end
    }

    /// The text with the section present (added in its place in the chain when missing).
    static func ensureSection(_ text: String, _ title: String) -> [String] {
        var ls = lines(text.isEmpty ? "# Compass\n~schema:2\n" : text)
        if section(ls, title) != nil { return ls }
        let later = order.drop { $0 != title }.dropFirst()
        let at = later.compactMap { t in ls.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## " + t.lowercased() } }.min()
        if let at {
            ls.insert(contentsOf: ["## \(title)", ""], at: at)
        } else {
            while ls.last == "" { ls.removeLast() }
            ls += ["", "## \(title)", ""]
        }
        return ls
    }

    /// The Purpose, in the user's words (a typed purpose is theirs: it is no longer a proposal).
    public static func setPurpose(_ text: String, _ purpose: String) -> String {
        var ls = ensureSection(text, "Purpose")
        let r = section(ls, "Purpose")!
        // The old text, its ~status:proposed and its quoted source go; compass.versions/ keeps them.
        ls.replaceSubrange(r, with: ["", clean(purpose), ""])
        return tidy(ls)
    }

    /// A new item at the end of a Compass section ("Vision", "Objectives", "Goals"). Returns the text and id.
    public static func addCompassItem(_ text: String, section title: String, words: String, tokens: [(String, String)] = []) -> (String, String) {
        var ls = ensureSection(text, title)
        let w = clean(words)
        let kind = ["Mission statement": ("st", "statement"), "Vision": ("vi", "vision"), "Objectives": ("o", "objective"), "Goals": ("g", "goal"), "Values": ("v", "value"), "Preferences": ("p", "preference")][title] ?? ("x", "other")
        let id = shortID(kind.0, kind.1, w)
        let box = title == "Goals" ? "[ ] " : ""
        let line = (["- \(box)\(w) ~id:\(id)"] + tokens.filter { !$0.1.isEmpty }.map { "~\($0.0):\($0.1)" }).joined(separator: " ")
        let r = section(ls, title)!
        var at = r.upperBound
        while at > r.lowerBound && ls[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        if at == r.lowerBound { ls.insert(contentsOf: ["", line], at: at) } else { ls.insert(line, at: at) }
        return (tidy(ls), id)
    }

    /// Changes one Compass item's tokens (nil removes), its words, or its box.
    public static func editCompassItem(_ text: String, id: String, tokens: [String: String?] = [:], title: String? = nil, done: Bool? = nil) -> String {
        var ls = lines(text)
        guard let i = ls.firstIndex(where: { ($0.hasPrefix("- ") || $0.hasPrefix("* ")) && ($0.hasSuffix("~id:\(id)") || $0.contains("~id:\(id) ")) }) else { return text }
        var l = ls[i]
        if let title {
            let marker = String(l.prefix(2))
            var rest = String(l.dropFirst(2))
            var box = ""
            if let r = rest.range(of: #"^\[( |x|X)\]\s+"#, options: .regularExpression) { box = String(rest[r]); rest = String(rest[r.upperBound...]) }
            let toks = rest.components(separatedBy: " ").filter { $0.hasPrefix("~") }
            l = marker + box + ([clean(title)] + toks).joined(separator: " ")
        }
        if let done, let r = l.range(of: #"\[( |x|X)\]"#, options: .regularExpression) { l.replaceSubrange(r, with: done ? "[x]" : "[ ]") }
        ls[i] = setTokens(l, tokens)
        return ls.joined(separator: "\n")
    }

    // MARK: Preferences (## Preferences in build/compass.md)
    //
    //   - Few words, no wraps ~id:p-x ~scope:design ~strength:soft ~added:2026-10-30
    //     from: <where it was said>
    //
    // ~status:proposed while it waits for a yes (agents skip it), ~status:archived once put away (never deleted).

    public static let preferenceScopes = ["design", "writing", "brand", "agents", "code", "food", "health", "schedule", "people", "travel", "general"]

    /// A new preference at the end of ## Preferences. The same words again give back the one already there.
    public static func addPreference(_ text: String, words: String, scope: String, strong: Bool = false, proposed: Bool = false,
                                     from: String? = nil, said: String? = nil, today: String = OmegaFormat.today()) -> (String, String) {
        let w = clean(words)
        let id = shortID("p", "preference", w)
        if compass(text).preferences.contains(where: { $0.id == id }) { return (text, id) }
        let scope = preferenceScopes.contains(scope.lowercased()) ? scope.lowercased() : guessScope(w)
        var tokens = [("scope", scope), ("strength", strong ? "strong" : "soft"), ("added", today)]
        if let said { tokens.append(("said", said)) }
        if proposed { tokens.append(("status", "proposed")) }
        var (out, _) = addCompassItem(text, section: "Preferences", words: w, tokens: tokens)
        if let from, !from.isEmpty {
            var ls = lines(out)
            if let i = ls.firstIndex(where: { $0.hasPrefix("- ") && $0.contains("~id:\(id) ") }) { ls.insert("  from: \(from)", at: i + 1) }
            out = ls.joined(separator: "\n")
        }
        return (out, id)
    }

    /// Puts a preference away (or back): ~status:archived. Never deleted.
    public static func archivePreference(_ text: String, id: String, _ on: Bool = true) -> String {
        editCompassItem(text, id: id, tokens: ["status": on ? "archived" : nil])
    }

    /// The preferences agents follow: neither proposed nor archived; only these scopes when given.
    public static func preferences(_ text: String, scopes: Set<String>? = nil) -> [OmegaCompassEntry] {
        compass(text).preferences.filter { $0.tokens["status"] == nil && (scopes?.contains($0.scope) ?? true) }
    }

    /// One line each, for an agent's instructions: "- No em dashes (writing, strong)".
    public static func preferenceLines(_ prefs: [OmegaCompassEntry]) -> String {
        prefs.map { "- \($0.title) (\($0.scope)\($0.strong ? ", strong" : ""))" }.joined(separator: "\n")
    }

    /// "design: big headers" -> (design, Big headers); otherwise the scope its words suggest.
    public static func parsePreference(_ said: String) -> (words: String, scope: String) {
        let s = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = s.firstIndex(of: ":"), case let head = s[..<c].lowercased().trimmingCharacters(in: .whitespaces), preferenceScopes.contains(head) {
            let w = s[s.index(after: c)...].trimmingCharacters(in: .whitespaces)
            return (w.prefix(1).uppercased() + w.dropFirst(), head)
        }
        return (s, guessScope(s))
    }

    /// The scope the words suggest (a keyword); general when none fits.
    public static func guessScope(_ words: String) -> String {
        let w = " " + words.lowercased().replacingOccurrences(of: #"[^a-z0-9#]+"#, with: " ", options: .regularExpression) + " "
        let keys: [(String, [String])] = [
            ("brand", ["brand", "logo", "gold", "green", "fru dev", "#008000"]),
            ("writing", ["dash", "dashes", "emoji", "emojis", "write", "writing", "word", "words", "copy", "prose", "tone", "wording", "label", "labels"]),
            ("design", ["design", "visual", "header", "headers", "icon", "icons", "layout", "font", "color", "colour", "screen", "minimal", "minimalist", "wrap", "wraps", "button", "dark mode"]),
            ("code", ["code", "repo", "commit", "public", "server", "package", "vault"]),
            ("food", ["eat", "food", "meal", "drink", "coffee", "breakfast", "lunch", "dinner"]),
            ("health", ["gym", "sleep", "run", "workout", "walk", "health"]),
            ("schedule", ["morning", "evening", "meeting", "meetings", "calendar", "alarm", "remind", "weekend", "schedule"]),
            ("people", ["call", "email", "message", "friends", "family"]),
            ("agents", ["agent", "agents", "suggest", "suggestions", "proactive", "ask me", "recommend"]),
        ]
        return keys.first { $0.1.contains { w.contains(" \($0) ") } }?.0 ?? "general"
    }

    /// No run of more than one blank line, one final newline.
    static func tidy(_ ls: [String]) -> String {
        var out: [String] = []
        for l in ls { if l.trimmingCharacters(in: .whitespaces).isEmpty && (out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? false) { continue }; out.append(l) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}

extension String {
    var omegaTrimmedTrailingSpaces: String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
