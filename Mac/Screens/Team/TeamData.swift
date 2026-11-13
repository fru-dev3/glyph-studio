import Foundation

// The team's data: what is waiting (with the teammate's own words from its task board), the pages
// agents wrote, chat threads, and the answers that clear a waiting item. Read from the vault and
// the engine; every write goes through IntentStore's guard.

/// Something a teammate is waiting on, with what the cards need.
struct Ask: Identifiable, Hashable {
    enum Style: Hashable {
        case allow      // an act or a Google write the gate is holding
        case book       // a paused task that asks "Can I ...?"
        case review     // a finished task to sign off
        case question   // a paused task that asks the owner something
        case loop       // a loop action (answered on the domain board)
    }
    var id: String          // kind|domain|summary: the engine's task ids can be empty
    var kind: String
    var engineID: String
    var domain: String
    var summary: String
    var since: Double
    var text: String        // the task's `ask:` line, else the summary
    var style: Style
    var due: String?
    var goal: String?
    var page: Brief?

    var primary: String {
        switch style {
        case .allow: return "Allow"
        case .book: return Self.verbButton(text)
        case .review: return "Approve"
        case .question: return "Answer"
        case .loop: return "Open"
        }
    }
    var secondary: String? {
        switch style {
        case .allow: return kind == "gws" ? "Later" : "Deny"
        case .book: return "Another day"
        case .review: return "Open"
        case .question: return "Not now"
        case .loop: return nil
        }
    }

    /// "Can I book the intake call ...?" -> "Book it".
    static func verbButton(_ ask: String) -> String {
        let words = ask.split(separator: " ")
        guard words.count > 2, words[0].lowercased() == "can", words[1] == "I" else { return "Yes" }
        return words[2].prefix(1).uppercased() + words[2].dropFirst().lowercased() + " it"
    }

    static func build(_ items: [WaitingItem], root: URL = Vault.root) -> [Ask] {
        let briefs = Brief.all(root: root)
        var boards: [String: String] = [:]
        return items.map { w in
            let domain = w.domain ?? AppModel.chiefID
            let kind = w.kind ?? "task"
            let summary = w.summary ?? w.kind ?? w.id
            var ask = Ask(id: "\(kind)|\(domain)|\(summary)", kind: kind, engineID: w.id, domain: domain, summary: summary,
                          since: w.since ?? 0, text: summary, style: .allow)
            switch kind {
            case "task":
                if boards[domain] == nil { boards[domain] = Vault.read(TeamTaskBoard.url(domain, root: root)) ?? "" }
                let t = TeamTaskBoard.task(in: boards[domain] ?? "", text: summary)
                ask.text = t?.ask ?? summary
                ask.due = t?.due
                ask.goal = t?.goal
                if t?.status == "review" { ask.style = .review }
                else if ask.text.hasPrefix("Can I ") { ask.style = .book }
                else { ask.style = .question }
            case "loop": ask.style = .loop
            default: ask.style = .allow
            }
            let hay = (summary + " " + ask.text).lowercased()
            ask.page = briefs.first { $0.domain == domain && hay.contains($0.title.lowercased()) }
            return ask
        }
    }
}

/// A page an agent wrote: a domain's memory/briefs/*.md, titled in its frontmatter.
struct Brief: Hashable {
    var domain: String
    var title: String
    var sources: Int
    var file: URL

    static func all(root: URL = Vault.root) -> [Brief] {
        let fm = FileManager.default
        let domains = root.appending(path: "data/domains")
        let slugs = ((try? fm.contentsOfDirectory(atPath: domains.path)) ?? []).sorted()
        return slugs.flatMap { slug -> [Brief] in
            let dir = domains.appending(path: "\(slug)/memory/briefs")
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted().reversed()
            return files.compactMap { name in
                let url = dir.appending(path: name)
                let f = Frontmatter.read(url)
                guard let title = f["title"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).nonEmpty else { return nil }
                let src = (f["sources"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").count
                return Brief(domain: slug, title: title, sources: src, file: url)
            }
        }
    }

    /// The pages a message names, by title or by file name.
    static func referenced(in text: String, from briefs: [Brief]) -> [Brief] {
        let t = text.lowercased()
        return briefs.filter { t.contains($0.title.lowercased()) || t.contains($0.file.lastPathComponent.lowercased()) }
    }
}

/// A domain's task board (memory/tasks.md or _tasks.md), read and answered line by line.
enum TeamTaskBoard {
    struct Task: Equatable { var line: Int; var text: String; var status: String?; var due: String?; var goal: String?; var ask: String? }

    static func url(_ domain: String, root: URL = Vault.root) -> URL {
        let dir = root.appending(path: "data/domains/\(domain)")
        let v4 = dir.appending(path: "memory/tasks.md"), flat = dir.appending(path: "_tasks.md")
        let fm = FileManager.default
        if fm.fileExists(atPath: v4.path) { return v4 }
        if fm.fileExists(atPath: flat.path) { return flat }
        return fm.fileExists(atPath: dir.appending(path: "memory").path) ? v4 : flat
    }

    /// A task line's text without its trailing `@due`, `+added` and `~key:value` tokens, as the engine reads it.
    static func parse(_ line: String) -> (open: Bool, text: String, tokens: [String: String])? {
        let t = line.drop { $0 == " " }
        let open: Bool
        if t.hasPrefix("- [ ] ") { open = true } else if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") { open = false } else { return nil }
        var words = t.dropFirst(6).split(separator: " ").map(String.init)
        var tokens: [String: String] = [:]
        while let last = words.last {
            if last.hasPrefix("@"), isDate(last.dropFirst()) { tokens["due"] = String(last.dropFirst()) }
            else if last.hasPrefix("+"), isDate(last.dropFirst()) { tokens["added"] = String(last.dropFirst()) }
            else if last.hasPrefix("~"), let c = last.firstIndex(of: ":") { tokens[String(last[last.index(after: last.startIndex)..<c])] = String(last[last.index(after: c)...]) }
            else { break }
            words.removeLast()
        }
        return (open, words.joined(separator: " "), tokens)
    }

    private static func isDate(_ s: Substring) -> Bool { s.count == 10 && s.split(separator: "-").count == 3 }

    /// The open task with this text, and its indented `ask:` line.
    static func task(in md: String, text: String) -> Task? {
        let lines = md.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            guard let p = parse(l), p.open, p.text == text else { continue }
            var ask: String?
            for c in lines[(i + 1)...] {
                guard c.hasPrefix("  "), parse(c) == nil else { break }
                let s = c.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("ask:") { ask = s.dropFirst(4).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            return Task(line: i, text: p.text, status: p.tokens["status"], due: p.tokens["due"], goal: p.tokens["goal"], ask: ask)
        }
        return nil
    }

    /// Answers a task: sets its status (done ticks the box and stamps `~closed:`), and records the
    /// answer as an indented `answer:` line under it. nil when the task isn't on the board.
    static func answer(_ md: String, text: String, status: String, answer: String, date: String) -> String? {
        guard let t = task(in: md, text: text) else { return nil }
        var lines = md.components(separatedBy: "\n")
        var line = lines[t.line].components(separatedBy: " ").filter { !$0.hasPrefix("~status:") }.joined(separator: " ")
        if status == "done" {
            line = line.replacingOccurrences(of: "- [ ] ", with: "- [x] ") + " ~closed:\(date)"
        } else {
            line += " ~status:\(status)"
        }
        lines[t.line] = line
        var end = t.line + 1
        while end < lines.count, lines[end].hasPrefix("  "), parse(lines[end]) == nil {
            if lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("answer:") { lines.remove(at: end); continue }
            end += 1
        }
        let clean = answer.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        lines.insert("  answer: \(clean) (\(date))", at: end)
        return lines.joined(separator: "\n")
    }
}

/// A teammate's conversation, as the engine keeps it: `<domain>/memory/threads/<id>.jsonl` on a v4
/// domain, else `<domain>/_threads/<id>.jsonl`, one turn per line.
enum Threads {
    struct Turn: Equatable { var role: String; var text: String; var ts: Double }

    static func dirs(_ slug: String, root: URL = Vault.root) -> [URL] {
        let d = root.appending(path: "data/domains/\(slug)")
        return [d.appending(path: "memory/threads"), d.appending(path: "_threads")]
    }

    /// The newest thread file, which the next message continues.
    static func newest(_ slug: String, root: URL = Vault.root) -> URL? {
        let fm = FileManager.default
        return dirs(slug, root: root).flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" }
        }.max { TeamActivity.modified($0) < TeamActivity.modified($1) }
    }

    static func turns(_ text: String) -> [Turn] {
        text.split(separator: "\n").compactMap { raw in
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let role = o["role"] as? String, role == "user" || role == "assistant",
                  let c = o["content"] as? String, c.nonEmpty != nil else { return nil }
            return Turn(role: role, text: c, ts: (o["ts"] as? Double) ?? 0)
        }
    }
}

/// One line of `prevail chat --json` (docs/schemas/ChatEvent.json); unknown types are ignored.
struct ChatEvent: Decodable {
    var type: String
    var thread: String?
    var text: String?
    var error: String?
    var role: String?
    /// On a `tool` event: a step the agent took (a file it read, a tool it ran), as the engine labels it.
    struct Step: Decodable { var id: String?; var label: String?; var status: String? }
    var step: Step?
    var access: String?

    static func parse(_ line: String) -> ChatEvent? { try? JSONDecoder().decode(ChatEvent.self, from: Data(line.utf8)) }
}

/// What the cards' buttons do. Acts and Google writes go to the engine's gate; tasks are answered on
/// the domain's own task board (this engine has no task verb), through IntentStore's write guard.
@MainActor
enum Answers {
    enum Choice { case yes, no, answer(String) }

    /// Runs the answer and returns the line the card shows afterwards.
    static func run(_ ask: Ask, _ choice: Choice, root: URL = Vault.root) async throws -> String {
        let who = AppModel.shared.teammate(ask.domain)?.name ?? ask.domain.capitalized
        switch (ask.style, choice) {
        case (.allow, .yes):
            if ask.kind == "gws" { _ = try await Engine.run(["gws", "run", "--id", ask.engineID, "--json"]) }
            else { _ = try await Engine.run(["acts", "approve", "--id", ask.engineID, "--json"]) }
            return "Allowed. \(who) will go ahead."
        case (.allow, _):
            if ask.kind == "act" { _ = try await Engine.run(["acts", "deny", "--id", ask.engineID, "--json"]); return "Denied. \(who) won't do it." }
            return "Left for later."
        case (.book, .yes):
            try edit(ask, status: "doing", answer: "yes", root: root); return "Done. \(who) will \(bookVerb(ask)) it."
        case (.book, _):
            try edit(ask, status: "todo", answer: "another day", root: root); return "Moved. \(who) will find another day."
        case (.review, .yes):
            try edit(ask, status: "done", answer: "approved", root: root); return "Approved."
        case (.question, .answer(let text)):
            try edit(ask, status: "doing", answer: text, root: root)
            try await tell(ask.domain, "You asked me: \(ask.text)\nMy answer: \(text)")
            return "Sent to \(who)."
        case (.question, _), (.review, _):
            try edit(ask, status: "todo", answer: "not now", root: root); return "Not now. \(who) will ask again later."
        case (.loop, _):
            return ""
        }
    }

    private static func bookVerb(_ ask: Ask) -> String { String(Ask.verbButton(ask.text).dropLast(3)).lowercased() }

    nonisolated static func today() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: AppClock.now)
    }

    static func edit(_ ask: Ask, status: String, answer: String, root: URL) throws {
        let url = TeamTaskBoard.url(ask.domain, root: root)
        guard let md = Vault.read(url), let out = TeamTaskBoard.answer(md, text: ask.summary, status: status, answer: answer, date: today()) else {
            throw EngineError(message: "\(ask.summary) is no longer on the \(ask.domain) board.")
        }
        try IntentStore(root: root).write(out, to: url)
    }

    /// Sends a message to a teammate and waits for the turn to finish (the engine keeps the thread).
    static func tell(_ domain: String, _ text: String) async throws {
        for try await line in Engine.lines(["chat", "--domain", domain, "--json"], stdin: Data(text.utf8)) {
            if let e = ChatEvent.parse(line), e.type == "error" { throw EngineError(message: e.error ?? "The chat failed.") }
        }
    }
}

/// Which waiting items are on screen: the engine's list minus what was answered here (a fixture or
/// a slow engine may still list them for a moment).
@MainActor @Observable
final class TeamState {
    static let shared = TeamState()
    var handled: Set<String> = []
    var outcomes: [String: String] = [:]
    var busy: Set<String> = []
    var failures: [String: String] = [:]

    /// Built once per change of the engine's list (it reads the task boards and pages).
    var asks: [Ask] {
        let waiting = AppModel.shared.waiting
        let key = waiting.map { "\($0.kind ?? "")|\($0.domain ?? "")|\($0.summary ?? "")|\($0.id)" }.joined(separator: "\n")
        if key != builtFor { built = Ask.build(waiting); builtFor = key }
        return built.filter { !handled.contains($0.id) }
    }
    @ObservationIgnored private var built: [Ask] = []
    @ObservationIgnored private var builtFor: String?

    /// Answers an item; the card shows the outcome, then it leaves the lists.
    func answer(_ ask: Ask, _ choice: Answers.Choice) {
        guard !busy.contains(ask.id) else { return }
        busy.insert(ask.id); failures[ask.id] = nil
        Task {
            do {
                let line = try await Answers.run(ask, choice)
                outcomes[ask.id] = line
                busy.remove(ask.id)
                handled.insert(ask.id)
                await AppModel.shared.refresh()
            } catch {
                busy.remove(ask.id)
                failures[ask.id] = error.localizedDescription
            }
        }
    }
}
