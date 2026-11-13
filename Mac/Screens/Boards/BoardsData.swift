import Foundation

// What the three boards read from the vault, and the small line-preserving writers they need that
// IntentStore doesn't have (compass purpose and values, Never lines, task boxes and answers,
// proposed trade-offs). Every write goes through IntentStore.write (the vault's write guard) and
// changes only the lines it means to.

/// One line of a domain's task board (memory/tasks.md) and the indented lines under it.
struct GoalTask: Equatable, Identifiable {
    var line: Int          // index of the task line in the file
    var text: String
    var done: Bool
    var status: String?    // doing | review | blocked | icebox | nil (todo)
    var owner: String?
    var goal: String?
    var ask: String?
    var answer: String?
    var id: String { "\(line):\(text)" }

    enum State: String { case done, asksYou = "asks you", working, next, later }

    var state: State {
        if done { return .done }
        switch status {
        case "blocked", "review": return answer == nil ? .asksYou : .next
        case "doing": return .working
        case "icebox": return .later
        default: return .next
        }
    }

    /// An agent can move it now: an open AI task that is not waiting on the owner or put away.
    var agentWorking: Bool { owner == "ai" && !done && !["blocked", "icebox"].contains(status ?? "") }
}

enum TaskBoard {
    static func read(_ slug: String) -> [GoalTask] { parse(Vault.read(Vault.tasksFile(slug)) ?? "") }

    static func parse(_ text: String) -> [GoalTask] {
        let lines = text.components(separatedBy: "\n")
        var out: [GoalTask] = []
        for (i, line) in lines.enumerated() {
            if let g = GoalsDoc.goalLine(line), !line.hasPrefix(" ") {
                var t = GoalTask(line: i, text: words(g.title), done: g.done, status: g.tokens["status"], owner: g.tokens["owner"], goal: g.tokens["goal"])
                if t.status == "done" || t.status == "todo" { t.status = nil }
                out.append(t)
            } else if !out.isEmpty, let f = GoalsDoc.field(line) {
                if f.key == "ask" { out[out.count - 1].ask = f.value }
                if f.key == "answer" { out[out.count - 1].answer = f.value }
            }
        }
        return out
    }

    /// The title without `@date` and `+date` marks (tokens are already gone).
    static func words(_ s: String) -> String {
        s.split(separator: " ").filter { !(($0.hasPrefix("@") || $0.hasPrefix("+")) && $0.dropFirst().first?.isNumber == true) }.joined(separator: " ")
    }

    /// Checks a task off (`[x]`, `~closed:<today>`, no open status) or opens it again.
    static func setDone(_ done: Bool, line: Int, in text: String, today: String = Day.today) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        var parts = lines[line].components(separatedBy: " ").filter { !$0.hasPrefix("~closed:") && !(done && $0.hasPrefix("~status:")) }
        if let b = parts.firstIndex(where: { $0 == "[" || $0.hasPrefix("[") }) {
            // "- [ ] x" splits into "-", "[", "]", ...; "- [x] x" into "-", "[x]", ...
            if parts[b] == "[" && parts.indices.contains(b + 1) && parts[b + 1] == "]" { parts.replaceSubrange(b...b + 1, with: [done ? "[x]" : "[ ]"]) }
            else { parts[b] = done ? "[x]" : "[ ]" }
        }
        var l = parts.joined(separator: " ")
        if done { l += " ~closed:\(today)" }
        lines[line] = l
        return lines.joined(separator: "\n")
    }

    /// Writes the owner's answer under the task's ask (replacing an earlier one) and takes the task
    /// off hold, so its teammate picks it up again.
    static func answer(_ answer: String, line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        let clean = GoalsDoc.clean(answer)
        lines[line] = lines[line].components(separatedBy: " ").filter { $0 != "~status:blocked" && $0 != "~status:review" }.joined(separator: " ")
        var end = line + 1
        while end < lines.count, GoalsDoc.isContinuation(lines[end]) { end += 1 }
        if let a = (line + 1..<end).first(where: { GoalsDoc.field(lines[$0])?.key == "answer" }) {
            lines[a] = "  answer: \(clean)"
        } else {
            lines.insert("  answer: \(clean)", at: end)
        }
        return lines.joined(separator: "\n")
    }
}

/// Today as the vault writes dates.
enum Day {
    static var today: String { iso.string(from: AppClock.now) }
    static let iso: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let short: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"; return f }()

    /// "2026-12-01" -> "Dec 1"; anything else as written.
    static func show(_ s: String?) -> String {
        guard let s else { return "" }
        return iso.date(from: s).map { short.string(from: $0) } ?? s
    }

    /// "Dec 1", "dec 1 2026", "2026-12-01" -> ISO. The year is the next one that date falls in.
    static func parse(_ s: String, now: Date = AppClock.now) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if iso.date(from: t) != nil { return t }
        let withYear = DateFormatter(); withYear.locale = Locale(identifier: "en_US_POSIX"); withYear.dateFormat = "MMM d yyyy"
        if let d = withYear.date(from: t.replacingOccurrences(of: ",", with: "")) { return iso.string(from: d) }
        guard let d = short.date(from: t) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let md = cal.dateComponents([.month, .day], from: d)
        var c = DateComponents(year: cal.component(.year, from: now), month: md.month, day: md.day)
        if let this = cal.date(from: c), this < cal.startOfDay(for: now) { c.year! += 1 }
        return cal.date(from: c).map { iso.string(from: $0) }
    }
}

/// build/compass.md, edited in place: the purpose's text lines and a value's words. Everything else
/// (tokens, `words:` lines, other sections) is written back as it was.
enum CompassEdit {
    static func setPurpose(_ purpose: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let clean = GoalsDoc.clean(purpose)
        guard let h = lines.firstIndex(where: { Markdown.heading($0)?.caseInsensitiveCompare("Purpose") == .orderedSame }) else {
            return text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + "\n## Purpose\n\(clean)\n"
        }
        let end = lines[(h + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        let body = (h + 1..<end).filter { i in
            let l = lines[i]
            return !l.trimmingCharacters(in: .whitespaces).isEmpty && !l.hasPrefix(" ") && !l.hasPrefix("\t") && !l.hasPrefix("~")
        }
        if let first = body.first {
            for i in body.dropFirst().reversed() { lines.remove(at: i) }
            lines[first] = clean
        } else {
            lines.insert(clean, at: h + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Renames the value whose `~id:` is `id` (or whose words are `id`), keeping its tokens.
    static func setValue(_ id: String, title: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { Markdown.heading($0)?.caseInsensitiveCompare("Values") == .orderedSame }) else { return text }
        let end = lines[(h + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        for i in h + 1..<end where lines[i].hasPrefix("- ") {
            let words = lines[i].dropFirst(2).split(separator: " ").map(String.init)
            let tokens = words.filter { $0.hasPrefix("~") }
            let name = words.filter { !$0.hasPrefix("~") }.joined(separator: " ")
            guard tokens.contains("~id:\(id)") || name == id else { continue }
            lines[i] = "- " + ([GoalsDoc.clean(title)] + tokens).joined(separator: " ")
            return lines.joined(separator: "\n")
        }
        return text
    }
}

/// A trade-off a weekly review proposed for a domain (`## Proposed trade-offs for <Domain>` in
/// general/memory/reviews/*.md, `- X over Y ~status:proposed`).
struct ProposedTradeOff: Equatable, Identifiable {
    var file: URL
    var line: Int
    var text: String
    var id: String { "\(file.lastPathComponent):\(line)" }

    static func find(for label: String, root: URL = Vault.root) -> [ProposedTradeOff] {
        let dir = root.appending(path: "data/domains/general/memory/reviews")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return files.flatMap { f in parse(Vault.read(f) ?? "", label: label).map { ProposedTradeOff(file: f, line: $0.0, text: $0.1) } }
    }

    static func parse(_ text: String, label: String) -> [(Int, String)] {
        let lines = text.components(separatedBy: "\n")
        var inSection = false, out: [(Int, String)] = []
        for (i, l) in lines.enumerated() {
            if l.hasPrefix("#") { inSection = Markdown.heading(l)?.caseInsensitiveCompare("Proposed trade-offs for \(label)") == .orderedSame; continue }
            guard inSection, l.hasPrefix("- "), l.contains("~status:proposed") else { continue }
            out.append((i, l.dropFirst(2).split(separator: " ").filter { !$0.hasPrefix("~") }.joined(separator: " ")))
        }
        return out
    }

    /// `~status:proposed` -> `~status:accepted|rejected` on that one line.
    static func mark(_ text: String, line: Int, as status: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        lines[line] = lines[line].replacingOccurrences(of: "~status:proposed", with: "~status:\(status)")
        return lines.joined(separator: "\n")
    }
}

/// A page an agent wrote (memory/briefs/*.md).
struct AgentPage: Identifiable, Equatable {
    var url: URL
    var title: String
    var draft: Bool
    var note: String?
    var body: String
    var id: String { url.path }

    /// The last numeric column of the page's first table, for its thumbnail.
    var series: [Double] {
        body.components(separatedBy: "\n").filter { $0.hasPrefix("|") && !$0.contains("---") }
            .compactMap { row in row.split(separator: "|").last.flatMap { Double($0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) } }
    }

    static func list(_ slug: String) -> [AgentPage] {
        let dir = Vault.domain(slug).appending(path: "memory/briefs")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return files.compactMap { f in
            guard let text = Vault.read(f) else { return nil }
            let fm = Frontmatter.read(f)
            var body = text
            if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
                body = String(text[end.upperBound...])
            }
            let heading = body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            let title = fm["title"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? heading ?? f.deletingPathExtension().lastPathComponent
            return AgentPage(url: f, title: title, draft: fm["status"] == "draft", note: fm["note"], body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A playbook on a clock for a domain (build/playbooks/*.json).
struct Routine: Equatable, Identifiable {
    var id: String
    var name: String
    var when: String

    static func list(_ slug: String) -> [Routine] {
        let dir = Vault.build.appending(path: "playbooks")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        return files.compactMap { f -> Routine? in
            guard let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let sched = o["schedule"] as? [String: Any]
            let domain = o["domain"] as? String ?? sched?["space"] as? String
            guard domain == slug, sched?["enabled"] as? Bool != false, let cron = o["cron"] as? String else { return nil }
            return Routine(id: o["id"] as? String ?? f.lastPathComponent, name: o["name"] as? String ?? "Routine", when: describe(cron: cron))
        }.sorted { $0.name > $1.name }
    }

    /// "0 8 1 * *" -> "1st, 8:00"; "0 8 1 1,4,7,10 *" -> "every quarter"; "0 9 * * 1" -> "Mondays, 9:00".
    static func describe(cron: String) -> String {
        let p = cron.split(separator: " ").map(String.init)
        guard p.count == 5 else { return cron }
        let time = "\(p[1]):\(p[0].count == 1 ? "0" + p[0] : p[0])"
        if p[3].split(separator: ",").count == 4 { return "every quarter" }
        if let d = Int(p[2]), p[3] == "*" { return "\(ordinal(d)), \(time)" }
        if p[2] == "*", let w = Int(p[4]), (0...6).contains(w) {
            return "\(["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"][w]), \(time)"
        }
        if p[2] == "*", p[4] == "*" { return "daily, \(time)" }
        return cron
    }

    static func ordinal(_ n: Int) -> String {
        let s = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(s)"
    }
}

/// What a domain's memory/state.md says: its status line and the feeds it lists.
struct DomainState {
    var status: String?
    var feeds: [(name: String, live: Bool)] = []

    init(_ slug: String) { self.init(text: Vault.read(Vault.domain(slug).appending(path: "memory/state.md")) ?? "") }

    init(text: String) {
        let md = Markdown(text)
        status = text.components(separatedBy: "\n").first { $0.hasPrefix("Status:") }
            .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }?.nonEmpty
        feeds = md.lines(of: "Feeds").compactMap { l in
            guard l.hasPrefix("- ") else { return nil }
            let w = l.dropFirst(2).split(separator: " ")
            let name = w.filter { !$0.hasPrefix("~") }.joined(separator: " ")
            let st = w.first { $0.hasPrefix("~status:") }?.dropFirst(8) ?? "live"
            return name.isEmpty ? nil : (name, st == "live")
        }
    }

    /// Calm words leave a domain grey; anything else is the warn colour.
    var calm: Bool {
        guard let s = status?.lowercased() else { return true }
        return ["steady", "on track", "healthy", "calm", "done"].contains { s.hasPrefix($0) }
    }
}

/// The `note:` line of a goal in goals.md: the status line its teammate keeps current.
enum GoalNote {
    static func notes(_ slug: String, store: IntentStore = IntentStore()) -> [String: String] {
        let text = Vault.read(store.goalsFile(slug)) ?? ""
        var out: [String: String] = [:], current: String?
        for line in text.components(separatedBy: "\n") {
            if let g = GoalsDoc.goalLine(line), !line.hasPrefix(" ") { current = g.tokens["id"]; continue }
            if let id = current, let f = GoalsDoc.field(line), f.key == "note" { out[id] = f.value }
        }
        return out
    }
}

extension IntentStore {
    /// Sets ideal-state.md "What to avoid" to `- Never <item>` lines (the demo vault's shape).
    func setNever(_ items: [String], in slug: String) throws {
        let url = domainDir(slug).appending(path: "ideal-state.md")
        let before = Vault.read(url) ?? ""
        var md = Markdown(before)
        md.setBullets(of: "What to avoid", items.map { $0.lowercased().hasPrefix("never ") ? $0 : "Never " + $0.prefix(1).lowercased() + $0.dropFirst() })
        guard md.text != before else { return }
        try keepVersion(before, slug)
        try write(md.text, to: url)
    }

    /// The prior ideal-state.md in ideal-state.versions/, as IntentStore's own edits do.
    func keepVersion(_ before: String, _ slug: String) throws {
        guard before.nonEmpty != nil else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        var keep = domainDir(slug).appending(path: "ideal-state.versions/\(stamp).md")
        var n = 1
        while FileManager.default.fileExists(atPath: keep.path) { keep = domainDir(slug).appending(path: "ideal-state.versions/\(stamp)-\(n).md"); n += 1 }
        try write(before, to: keep)
    }
}

extension String {
    /// "Never move money without my yes" -> "Move money without my yes".
    var withoutNever: String {
        guard lowercased().hasPrefix("never ") else { return self }
        let rest = dropFirst(6)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// A goal title short enough for a breadcrumb: whole words up to `max` characters.
    func crumb(_ max: Int = 28) -> String {
        guard count > max else { return self }
        var out = ""
        for w in split(separator: " ") {
            if out.count + w.count + (out.isEmpty ? 0 : 1) > max { break }
            out += (out.isEmpty ? "" : " ") + w
        }
        return out.isEmpty ? String(prefix(max)) : out
    }
}
