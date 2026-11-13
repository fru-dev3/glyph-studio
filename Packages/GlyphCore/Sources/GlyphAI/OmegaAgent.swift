import CryptoKit
import Foundation
import FoundationModels
import GlyphVault

/// Glyph Omega's agent: goals by life domain, and the Compass's mission, vision and values. Every edit is Omega's
/// own (GlyphVault `OmegaFormat`, the bytes Omega writes) through the hub's Omega routes (`GET /omega`,
/// `PUT /omega/<path>` with the sha of the text it started from), so Omega shows it and nothing written in
/// between is lost. Undo puts the file back while it still holds what the agent wrote.
extension GlyphAgent {
    public static let omega = GlyphAgent(
        id: "omega", name: "Omega", color: "D9661F",
        instructions: """
        You are Glyph Omega's agent: goals in life domains, and the mission, vision and values. A new goal: add_goal \
        with its title in the person's words, its domain (health, wealth, career and so on) and its due date when said. \
        A change to a goal (a date, progress, a new title, why): update_goal. A goal finished: finish_goal. A line for \
        the mission, the vision or the values: add_to_compass. A preference they ask you to keep (how they like things: \
        few words, no emojis, coffee before nine): add_preference with its scope; one to put away: archive_preference.
        """,
        tools: { hub, ledger in [OmegaAddGoal(hub: hub, ledger: ledger), OmegaUpdateGoal(hub: hub, ledger: ledger),
                                 OmegaFinishGoal(hub: hub, ledger: ledger), OmegaAddToCompass(hub: hub, ledger: ledger),
                                 OmegaAddPreference(hub: hub, ledger: ledger), OmegaArchivePreference(hub: hub, ledger: ledger)] },
        fallback: { job, hub in await hub.omegaByRules(job.instruction) })
}

public struct OmegaAddGoal: Tool {
    public let name = "add_goal"
    public let description = "Add a goal to a life domain in Glyph Omega."
    @Generable public struct Arguments {
        @Guide(description: "The goal, in the person's words, like Run a half marathon.") public var title: String
        @Guide(description: "The life domain, like health, wealth, career.") public var domain: String
        @Guide(description: "When it is due, as said (by May 1, 2027-05-01), or empty.") public var due: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addGoal(domain: a.domain, title: a.title, due: a.due); await ledger.add(d); return d.line
    }
}

public struct OmegaUpdateGoal: Tool {
    public let name = "update_goal"
    public let description = "Change a goal in Glyph Omega: its due date, progress, title or why."
    @Generable public struct Arguments {
        @Guide(description: "The goal as said, like the half marathon.") public var goal: String
        @Guide(description: "A new due date as said, or empty.") public var due: String
        @Guide(description: "Progress in percent, or -1 when not said.", .range(-1...100)) public var progress: Int
        @Guide(description: "A new title, or empty.") public var title: String
        @Guide(description: "Why it matters, or empty.") public var why: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.updateGoal(a.goal, due: a.due, progress: a.progress < 0 ? nil : a.progress, title: a.title, why: a.why)
        await ledger.add(d); return d.line
    }
}

public struct OmegaFinishGoal: Tool {
    public let name = "finish_goal"
    public let description = "Mark a goal done in Glyph Omega."
    @Generable public struct Arguments {
        @Guide(description: "The goal as said, like the half marathon.") public var goal: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.finishGoal(a.goal); await ledger.add(d); return d.line
    }
}

public struct OmegaAddToCompass: Tool {
    public let name = "add_to_compass"
    public let description = "Add a line to the mission, the vision or the values in Glyph Omega."
    @Generable public struct Arguments {
        @Guide(description: "Where", .anyOf(["mission", "vision", "value"])) public var section: String
        @Guide(description: "The line, in the person's words.") public var text: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addToCompass(a.section, a.text); await ledger.add(d); return d.line
    }
}

public struct OmegaAddPreference: Tool {
    public let name = "add_preference"
    public let description = "Keep a preference in Glyph Omega: how the person likes things, softer than a goal."
    @Generable public struct Arguments {
        @Guide(description: "The preference, short, in their words, like No emojis.") public var text: String
        @Guide(description: "What it is about", .anyOf(OmegaFormat.preferenceScopes)) public var scope: String
        @Guide(description: "true when they said always, never or must.") public var strong: Bool
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addPreference(a.text, scope: a.scope, strong: a.strong); await ledger.add(d); return d.line
    }
}

public struct OmegaArchivePreference: Tool {
    public let name = "archive_preference"
    public let description = "Put away a preference in Glyph Omega (kept, no longer followed)."
    @Generable public struct Arguments {
        @Guide(description: "The preference as said, like the emojis one.") public var preference: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.archivePreference(a.preference); await ledger.add(d); return d.line
    }
}

extension Hub {

    /// What Omega reads: {path: text} and {slug: label}. nil when the hub can't be reached.
    func omegaFiles() async -> (files: [String: String], labels: [String: String])? {
        guard let got = await send("GET", "omega"), got.0 == 200,
              let j = (try? JSONSerialization.jsonObject(with: got.1)) as? [String: Any] else { return nil }
        return (j["files"] as? [String: String] ?? [:], j["labels"] as? [String: String] ?? [:])
    }

    /// Writes a whole Omega file over `base` (nil: a new file). 204, 409 when it changed since, nil when away.
    func omegaPut(_ rel: String, _ text: String, base: String?) async -> Int? {
        let sha = base.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "none"
        let path = rel.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return await send("PUT", "omega/" + path, body: Data(text.utf8), type: "text/markdown", headers: ["X-Base-SHA256": sha])?.0
    }

    /// One Omega edit: read, change, write over what was read; once more if it changed in between. The change
    /// returns the file's path, its new text and the card, or a card that says why not (nothing written).
    func omegaEdit(_ change: (_ files: [String: String], _ labels: [String: String]) -> Result<(path: String, text: String, done: Done), OmegaMiss>) async -> Done {
        for _ in 0..<2 {
            guard let (files, labels) = await omegaFiles() else { return unreachable("omega", "Omega") }
            switch change(files, labels) {
            case .failure(let miss): return miss.done
            case .success(let c):
                let before = files[c.path]
                if c.text == (before ?? "") { return c.done }
                let code = await omegaPut(c.path, c.text, base: before)
                if code == 409 { continue }
                guard code == 204 else { return Done(agent: "omega", line: "Omega didn't take it (\(code.map(String.init) ?? "no hub")): \(c.done.title)", title: c.done.title, ok: false) }
                var d = c.done
                d.undo = .restore(app: "omega", path: c.path, before: before, after: c.text)
                return d
            }
        }
        return Done(agent: "omega", line: "Omega kept changing; try again", title: "Try again", ok: false)
    }

    public func addGoal(domain: String, title: String, due: String) async -> Done {
        let title = Self.cap(OmegaFormat.clean(title))
        return await omegaEdit { files, labels in
            guard !title.isEmpty else { return .failure(.init("No goal heard", "Which goal?")) }
            guard let d = Self.omegaDomain(domain, labels) else {
                return .failure(.init("Which domain for \(title)? \(labels.keys.sorted().joined(separator: ", "))", "Which domain?"))
            }
            let rel = "data/domains/\(d)/source/goals.md"
            let day = Self.omegaDay(due, now: now())
            let (text, _) = OmegaFormat.addGoal(files[rel] ?? "", domain: d, title: title, due: day)
            return .success((rel, text, Done(agent: "omega", line: "Goal added in Omega (\(labels[d] ?? d))\(day.map { ", due \($0)" } ?? ""): \(title)",
                                              title: title, ok: true, link: URL(string: "glyph-omega://goals"))))
        }
    }

    public func updateGoal(_ goal: String, due: String = "", progress: Int? = nil, title: String = "", why: String = "") async -> Done {
        await omegaEdit { files, labels in
            switch Self.omegaGoal(goal, files, labels) {
            case .failure(let m): return .failure(m)
            case .success(let (rel, g)):
                var tokens: [String: String?] = [:]
                if let day = Self.omegaDay(due, now: now()) { tokens["due"] = day }
                if let p = progress { tokens["progress"] = String(min(100, max(0, p))) }
                let newTitle = OmegaFormat.clean(title)
                let w = why.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tokens.isEmpty || !newTitle.isEmpty || !w.isEmpty else { return .failure(.init("Nothing to change on \(g.title)", g.title)) }
                let text = OmegaFormat.editGoal(files[rel] ?? "", id: g.id, tokens: tokens, title: newTitle.isEmpty ? nil : newTitle, why: w.isEmpty ? nil : .some(w))
                let what = [tokens["due"].flatMap { $0 }.map { "due \($0)" }, progress.map { "\($0)%" }, newTitle.isEmpty ? nil : "now \(newTitle)", w.isEmpty ? nil : "why"]
                    .compactMap { $0 }.joined(separator: ", ")
                return .success((rel, text, Done(agent: "omega", line: "Goal changed in Omega (\(what)): \(g.title)", title: newTitle.isEmpty ? g.title : newTitle,
                                                  ok: true, link: URL(string: "glyph-omega://goals"))))
            }
        }
    }

    public func finishGoal(_ goal: String) async -> Done {
        await omegaEdit { files, labels in
            switch Self.omegaGoal(goal, files, labels) {
            case .failure(let m): return .failure(m)
            case .success(let (rel, g)):
                return .success((rel, OmegaFormat.editGoal(files[rel] ?? "", id: g.id, done: true),
                                 Done(agent: "omega", line: "Goal done in Omega: \(g.title)", title: g.title, ok: true, link: URL(string: "glyph-omega://goals"))))
            }
        }
    }

    /// A line under the Compass's Mission statement, Vision or Values (a value ranked last, as Omega adds one).
    public func addToCompass(_ section: String, _ words: String) async -> Done {
        let words = Self.cap(OmegaFormat.clean(words))
        let s = section.lowercased()
        let heading = s.hasPrefix("mission") ? "Mission statement" : s.hasPrefix("vision") ? "Vision" : "Values"
        let name = heading == "Mission statement" ? "mission" : heading == "Vision" ? "vision" : "values"
        return await omegaEdit { files, _ in
            guard !words.isEmpty else { return .failure(.init("Nothing heard for the \(name)", "What for the \(name)?")) }
            let rel = "build/compass.md", old = files[rel] ?? ""
            let tokens = heading == "Values" ? [("rank", String(OmegaFormat.compass(old).values.count + 1))] : []
            let (text, _) = OmegaFormat.addCompassItem(old, section: heading, words: words, tokens: tokens)
            return .success((rel, text, Done(agent: "omega", line: "Added to your \(name) in Omega: \(words)", title: words, ok: true, link: URL(string: "glyph-omega://vision"))))
        }
    }

    /// Without the model: "new goal for health: swim a mile by June 1", "I finished the half marathon goal",
    /// "add to my vision: a house by the lake", "change the half marathon goal to 40%", "preference: no emojis",
    /// "archive the emojis preference". Anything else goes to
    /// Omega's own Talk, which asks.
    public func omegaByRules(_ said: String) async -> Done {
        let low = said.lowercased()
        func after(_ marks: [String]) -> String? {
            for m in marks { if let r = low.range(of: m) { let s = said[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)); if !s.isEmpty { return s } } }
            return nil
        }
        if low.contains("preference") {
            if low.range(of: #"\b(archive|drop|forget|remove)\b"#, options: .regularExpression) != nil {
                return await archivePreference(said.replacingOccurrences(of: #"(?i)\b(archive|drop|forget|remove|the|my|preference)\b"#, with: " ", options: .regularExpression))
            }
            if let w = after([": ", "preference is ", "preference for ", "preference "]) { return await addPreference(Self.cap(w)) }
        }
        if let section = ["mission", "vision", "value"].first(where: { low.contains($0) }), !low.contains("goal") {
            if let w = after([": ", "\(section) is to ", "\(section) is ", "\(section)s: "]) { return await addToCompass(section, Self.cap(w)) }
        }
        if low.range(of: #"\b(finished|completed|achieved|done with|mark(ed)? .* done)\b"#, options: .regularExpression) != nil,
           let g = after(["finished ", "completed ", "achieved ", "done with ", "mark "]) {
            return await finishGoal(g.replacingOccurrences(of: #"(?i)\s*(as )?done$|\bgoal\b|\bmy\b|\bthe\b"#, with: " ", options: .regularExpression))
        }
        if let pct = low.range(of: #"\d{1,3}\s*(%|percent)"#, options: .regularExpression), let n = Int(low[pct].filter(\.isNumber)),
           let g = after(["goal ", "set ", "change ", "move "]) {
            return await updateGoal(String(g.prefix { !$0.isNumber }).replacingOccurrences(of: #"(?i)\b(goal|to|at|progress)\b"#, with: " ", options: .regularExpression), progress: n)
        }
        if low.contains("goal"), var title = after([": ", "goal is to ", "goal to ", "goal of ", "goal "]) {
            var due = ""
            if let r = title.range(of: #"(?i)\s+by\s+.+$"#, options: .regularExpression) { due = String(title[r]); title = String(title[..<r.lowerBound]) }
            if let (files, labels) = await omegaFiles(), let d = Self.omegaDomain(said, labels) {
                _ = files
                for w in [d, labels[d] ?? d] { title = title.replacingOccurrences(of: #"(?i)^(for |in )?\#(NSRegularExpression.escapedPattern(for: w))[:,]?\s*"#, with: "", options: .regularExpression) }
                return await addGoal(domain: d, title: Self.cap(title), due: due)
            }
        }
        var c = URLComponents(); c.scheme = "glyph-omega"; c.host = "talk"; c.queryItems = [URLQueryItem(name: "text", value: said)]
        return Done(agent: "omega", line: "Sent to Omega's Talk, waiting for your yes there: \(said)", title: said, ok: true, review: true, link: c.url)
    }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The domain said (its folder name or its label, or one of them said inside the words).
    static func omegaDomain(_ said: String, _ labels: [String: String]) -> String? {
        let s = " " + said.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression) + " "
        for (slug, label) in labels.sorted(by: { $0.key.count > $1.key.count }) {
            for name in [slug.replacingOccurrences(of: "-", with: " "), label.lowercased()] where !name.isEmpty && s.contains(" \(name) ") { return slug }
        }
        return nil
    }

    /// A day as Omega writes it (YYYY-MM-DD) from "2027-05-01", "by May 1", "next Friday"; nil when none.
    static func omegaDay(_ said: String, now: Date) -> String? {
        let t = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return t }
        guard !t.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let d = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))?.date else { return nil }
        // "May 1" said in October is next May: a goal's date is never in the past.
        let day = d < now.addingTimeInterval(-86400) ? Calendar.current.date(byAdding: .year, value: 1, to: d) ?? d : d
        return OmegaFormat.today(day)
    }

    /// The one goal the words name (its title, or every word said in its title), across every domain.
    static func omegaGoal(_ said: String, _ files: [String: String], _ labels: [String: String]) -> Result<(String, OmegaGoal), OmegaMiss> {
        let all = labels.keys.sorted().flatMap { d -> [(String, OmegaGoal)] in
            let rel = "data/domains/\(d)/source/goals.md"
            return OmegaFormat.goals(d, files[rel] ?? "").filter { $0.status != "archived" }.map { (rel, $0) }
        }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !["the", "and", "goal", "for", "with", "that", "this"].contains($0) })
        }
        let want = words(said)
        guard !want.isEmpty else { return .failure(.init("Which goal?", "Which goal?")) }
        var hits = all.filter { $0.1.title.caseInsensitiveCompare(said.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        if hits.isEmpty { hits = all.filter { want.isSubset(of: words($0.1.title)) } }
        if hits.isEmpty {
            let best = all.map { ($0, words($0.1.title).intersection(want).count) }.filter { $0.1 > 0 }
            let top = best.map(\.1).max() ?? 0
            hits = best.filter { $0.1 == top }.map(\.0)
        }
        if hits.count == 1 { return .success(hits[0]) }
        if hits.isEmpty { return .failure(.init("No goal in Omega like \(said)", "No such goal")) }
        return .failure(.init("Which goal: \(hits.prefix(3).map(\.1.title).joined(separator: " or "))?", "Which goal?"))
    }
}

/// Why an Omega edit wasn't made, for its card (nothing written).
public struct OmegaMiss: Error {
    let line: String, title: String
    init(_ line: String, _ title: String) { self.line = line; self.title = title }
    var done: Done { Done(agent: "omega", line: line, title: title, ok: false) }
}
