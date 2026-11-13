import Foundation
import CryptoKit
import FoundationModels
import GlyphVault

// The app agents on a Mac (`glyphcore-report agents` and `run`, and through them the engine's MCP tools). The
// tools are the same ones the iPhone driver gives each agent; only where they write changes. On the iPhone a
// `Hub` sends to the hub's routes; on a Mac, `Hub.vault` is set and `MacHub` does those
// routes on the vault's own files, the way the hub does them, so a line written here is the line the hub
// would have written.

/// The hub's routes the agents use, done on a vault folder: `PUT memo/<stem>` and `PUT memo-undo/<stem>` (Jot),
/// `PUT well/<file>` (Well), `PUT wealth/<file>` (Wealth), `GET` and `PUT crm/file?path=`, `GET crm/names`, `PUT crm/move` (CRM), `GET omega` and
/// `PUT omega/<path>` (Omega), `GET life/context` and `PUT life/<file>` (Life). Another route answers 501: that tool needs the hub.
struct MacHub {
    let vault: URL
    var domains: URL { vault.appending(path: "data/domains") }

    func handle(_ method: String, _ path: String, query: [String: String], body: Data?, headers: [String: String] = [:]) -> (Int, Data)? {
        switch (method, path) {
        case ("PUT", _) where path.hasPrefix("memo/"): return (memo(String(path.dropFirst(5)), body ?? Data()), Data())
        case ("PUT", _) where path.hasPrefix("well/"): return (well(String(path.dropFirst(5)), body ?? Data()), Data())
        case ("PUT", _) where path.hasPrefix("wealth/"): return (lines(app: "wealth", name: String(path.dropFirst(7)), body: body ?? Data()), Data())
        case ("GET", "life/context"):
            return (200, (try? JSONSerialization.data(withJSONObject: lifeContext(), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
        case ("PUT", _) where path.hasPrefix("life/"):
            return (lines(app: "life", name: String(path.dropFirst(5)), body: body ?? Data()), Data())
        case ("PUT", _) where path.hasPrefix("travel/"):
            return (lines(String(path.dropFirst(7)), body ?? Data(), into: "data/apps/travel/trips"), Data())
        case ("PUT", _) where path.hasPrefix("memo-undo/"):
            let stem = String(path.dropFirst(10)).removingPercentEncoding ?? ""
            guard stem.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}/) != nil else { return (400, Data()) }
            return (undoMemo(stem) ? 204 : 404, Data())
        case ("PUT", "jot/file"), ("PUT", "jot/unfile"):
            guard let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: String] else { return (400, Data()) }
            return path == "jot/file" ? fileNote(o["note"] ?? "", o["place"] ?? "") : unfileNote(o["note"] ?? "", o["place"] ?? "")
        case ("GET", "omega"):
            return (200, (try? JSONSerialization.data(withJSONObject: omegaBundle(), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
        case ("PUT", _) where path.hasPrefix("omega/"):
            return (omegaWrite(String(path.dropFirst(6)).removingPercentEncoding ?? "", body ?? Data(), base: headers["X-Base-SHA256"] ?? ""), Data())
        case ("GET", "crm/names"):
            return (200, (try? JSONSerialization.data(withJSONObject: crmNames(), options: [.withoutEscapingSlashes])) ?? Data())
        case ("PUT", "crm/move"):
            guard let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] else { return (400, Data()) }
            return (crmMove(o["from"] as? String, o["to"] as? String), Data())
        case ("GET", "crm/file"):
            let rel = query["path"] ?? ""
            guard Self.safe(rel) else { return (403, Data()) }
            guard let text = read(rel) else { return (404, Data()) }
            return (200, Data(text.utf8))
        case ("PUT", "crm/file"):
            let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            guard let text = o?["text"] as? String else { return (400, Data()) }
            return (crmWrite(query["path"] ?? "", text: text, base: o?["base"] as? String), Data())
        case ("GET", "connect"): return (200, Data(connectHealth().utf8))
        case ("PUT", "connect/app"):
            guard let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any],
                  let id = o["app"] as? String, let on = o["enabled"] as? Bool else { return (400, Data()) }
            do { try AppRegistry.setEnabled(vault: vault, id: id, on) } catch { return (404, Data()) }
            return (204, Data())
        case ("PUT", "connect/tool"):
            guard let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any],
                  let id = o["app"] as? String, let tool = o["tool"] as? String else { return (400, Data()) }
            let sync = o["sync"] as? Bool, chat = o["chat"] as? Bool
            do {
                // "all" and "writes" are the two bulk gestures the app's column headers make.
                if tool == "all" { try AppRegistry.setTools(vault: vault, id: id, writes: nil, sync: sync, chat: chat) }
                else if tool == "writes" { try AppRegistry.setTools(vault: vault, id: id, writes: true, sync: sync, chat: chat) }
                else if tool == "reads" { try AppRegistry.setTools(vault: vault, id: id, writes: false, sync: sync, chat: chat) }
                else { try AppRegistry.setTool(vault: vault, id: id, tool: tool, sync: sync, chat: chat) }
            } catch { return (404, Data()) }
            return (204, Data())
        default: return (501, Data())
        }
    }

    // MARK: Jot filing: the hub's jot/file and jot/unfile on the vault's files.

    static let notes = "data/domains/notes/source/jot"

    /// The note a few words or a file name mean (the newest that matches; the newest of all when empty).
    func findNote(_ said: String) -> String? {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: vault.appending(path: Self.notes).path)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted().reversed()
        if said.isEmpty { return files.first.map { "\(Self.notes)/\($0)" } }
        if let f = files.first(where: { $0 == said || $0 == said + ".md" || "\(Self.notes)/\($0)" == said }) { return "\(Self.notes)/\(f)" }
        return files.first { (read("\(Self.notes)/\($0)") ?? "").range(of: said, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map { "\(Self.notes)/\($0)" }
    }

    static func title(_ raw: String) -> String {
        var body = Substring(raw)
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) { body = raw[end.upperBound...] }
        let line = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(78)) + "\u{2026}" : line
    }

    func fileNote(_ note: String, _ place: String) -> (Int, Data) {
        guard let rel = findNote(note), let p = CrossLink.match(place, in: CrossLink.places(in: vault)) else { return (404, Data()) }
        let title = Self.title(read(rel) ?? "")
        do { try CrossLink.file(note: rel, title: title, to: p.path, in: vault) } catch { return (500, Data()) }
        return (200, (try? JSONSerialization.data(withJSONObject: ["note": rel, "place": p.path, "label": p.label, "title": title], options: [.withoutEscapingSlashes])) ?? Data())
    }

    func unfileNote(_ note: String, _ place: String) -> (Int, Data) {
        guard CrossLink.safe(note), CrossLink.safe(place) else { return (400, Data()) }
        do { try CrossLink.unfile(note: note, from: place, in: vault) } catch { return (500, Data()) }
        return (204, Data())
    }

    // MARK: Connect: the registry as the five states, for the agent's read tool and the phone's lists.

    /// `GET /connect`. The state of each app is worked out here and nowhere else, so the Mac app, the
    /// phone and the agent all read the same word. Runtime truth (has this machine's Claude really
    /// connected the server) is per machine, so it is read here from this machine's own config.
    func connectHealth() -> String {
        let apps = AppRegistry.read(vault: vault)
        let runtimes = [Runtimes.claude(), Runtimes.codex()]
        var counts: [String: Int] = ReachState.allCases.reduce(into: [:]) { $0[$1.rawValue] = 0 }
        var rows: [JSON] = []
        for a in apps {
            // No connector snapshot here: `glyphcore-report` does not shell out to the engine.
            let (state, why) = Runtimes.state(a, runtimes: runtimes, connector: nil)
            counts[state.rawValue, default: 0] += 1
            rows.append(.object([
                ("id", .string(a.id)), ("title", .string(a.title)), ("state", .string(state.words)),
                ("why", .string(why)), ("integration", .string(a.integration)),
                ("domains", .array(a.domains.map(JSON.string))),
                ("writeTools", .int(a.writeTools.count)),
                ("unattendedWrites", .int(a.unattendedWrites)), ("enabled", .bool(a.enabled)),
                ("integrationKind", .string(a.integration)),
                ("summary", .string(a.summary ?? "")),
                ("mirrorServer", .string(a.mirrorServer ?? "")),
                ("mirrorRuntime", .string(a.mirrorRuntime ?? "")),
                ("account", .string(a.account ?? "")),
                // The tool list, so Glyph Connect on the iPhone can show the same two columns of
                // permission the Mac shows. It is the biggest part of this answer and the point of it.
                ("tools", .array(a.tools.map { t in
                    .object([("name", .string(t.name)), ("full_name", .string(t.fullName)), ("kind", .string(t.kind)),
                             ("sync_allowed", .bool(t.syncAllowed)), ("chat_default", .bool(t.chatDefault))])
                })),
            ]))
        }
        return JSON.object([
            ("counts", .object(counts.sorted { $0.key < $1.key }.map { ($0.key, JSON.int($0.value)) })),
            ("apps", .array(rows)),
        ]).pretty
    }

    func read(_ rel: String) -> String? { try? String(contentsOf: vault.appending(path: rel), encoding: .utf8) }

    func write(_ rel: String, _ text: String) -> Bool {
        let url = vault.appending(path: rel)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    // MARK: Jot: the hub's save() for an agent's memo (no photo, place or coords): the note in notes, a copy in
    // each existing domain its tags name, and a Task note's first line on that domain's task list.

    func memo(_ stem: String, _ body: Data) -> Int {
        guard stem.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}/) != nil,
              let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return 400 }
        let tags = Array(NSOrderedSet(array: ((o["tags"] as? [String]) ?? []).prefix(20)
            .map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60)) }.filter { !$0.isEmpty })) as? [String] ?? []
        let kind = ["voice", "typed", "photo"].contains(o["kind"] as? String ?? "") ? o["kind"] as! String : "voice"
        let text = o["text"] as? String ?? ""
        let device = String(((o["device"] as? String) ?? "unknown").filter { $0.isLetter || $0.isNumber || " _,.()+-".contains($0) }.prefix(60))
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: domains.path)) ?? [])
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isDir(domains.appending(path: $0)) })
        let routed = Set((o["domains"] as? [String]) ?? []).intersection(existing).subtracting(["notes"])

        func markdown(copy: Bool) -> String {
            let date = stem.prefix(10) + "T" + stem.dropFirst(11).replacingOccurrences(of: "-", with: ":")
            let list = "[" + tags.map(Self.quote).joined(separator: ", ") + "]"   // Python's json.dumps
            return "---\ndate: \(date)\ntags: \(list)\nkind: \(kind)\ndevice: \(device.isEmpty ? "unknown" : device)\nsource: jot\n"
                + (copy ? "original: notes/source/jot/\(stem).md\n" : "") + "---\n\n"
                + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        guard write("data/domains/notes/source/jot/\(stem).md", markdown(copy: false)) else { return 500 }
        for d in routed.sorted() where !write("data/domains/\(d)/source/jot/\(stem).md", markdown(copy: true)) { return 500 }

        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map {
            String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240)) } ?? ""
        if tags.contains(where: { $0.lowercased() == "task" }), !first.isEmpty {
            let rel = "data/domains/\(routed.sorted().first ?? "notes")/memory/tasks.md", mark = "[src jot \(stem)]"
            let old = read(rel) ?? "# Tasks\n"
            if !old.contains(mark), !write(rel, old.replacing(/\n+$/, with: "") + "\n- [ ] \(first) +\(stem.prefix(10)) \(mark)\n") { return 500 }
        }
        return 204
    }

    // MARK: Well: the month file's new lines appended (Glyph Well appends too), each line once.

    func well(_ name: String, _ body: Data) -> Int { lines(app: "well", name: name, body: body) }

    /// A month file of an app that writes JSON lines (Glyph Well's entries, Glyph Wealth's and Glyph Life's), appended, never
    /// replaced: a line already there is not written twice, so sending the same bytes again is the same file.
    func lines(app: String, name: String, body: Data) -> Int {
        lines(name, body, into: "data/apps/\(app)/entries")
    }

    /// A month file merged line by line into a folder of the vault: every line of both, once, and
    /// nothing replaced. The same line again changes nothing, so sending it twice is sending it once.
    func lines(_ name: String, _ body: Data, into folder: String) -> Int {
        guard name.wholeMatch(of: /\d{4}-(0[1-9]|1[0-2])\.[a-z0-9-]{1,60}\.jsonl/) != nil else { return 400 }
        let rows = String(decoding: body, as: UTF8.self).split(separator: "\n").map(String.init)
        for l in rows {
            guard let e = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                  e["event"] is String, e["ts"] is String else { return 400 }
        }
        let url = vault.appending(path: "\(folder)/\(name)")
        let had = Set((read("\(folder)/\(name)") ?? "").split(separator: "\n").map(String.init))
        let new = rows.filter { !had.contains($0) }
        guard !new.isEmpty else { return 204 }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data((new.joined(separator: "\n") + "\n").utf8))
            return 204
        } catch { return 500 }
    }

    // MARK: Life: the hub's GET /life/context, from the vault's own files. Small files only, as the hub
    // serves them: the app registry's manifests (their costs), each life domain's loops, and Life's own lines.

    func lifeContext() -> [String: String] {
        var out: [String: String] = [:]
        let apps = vault.appending(path: "data/apps")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []).sorted()
        where !name.hasPrefix(".") && !name.hasPrefix("_") {
            if let text = read("data/apps/\(name)/manifest.json") { out["data/apps/\(name)/manifest.json"] = text }
        }
        for d in MacHub.lifeDomains {
            for rel in ["_loops.json", "memory/key-dates.md", "memory/tasks.md"] {
                if let text = read("data/domains/\(d)/\(rel)") { out["data/domains/\(d)/\(rel)"] = text }
            }
        }
        let entries = vault.appending(path: "data/apps/life/entries")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: entries.path)) ?? []).sorted() where name.hasSuffix(".jsonl") {
            if let text = read("data/apps/life/entries/\(name)") { out["data/apps/life/entries/\(name)"] = text }
        }
        return out
    }

    static let lifeDomains = ["records", "insurance", "benefits", "estate", "homestead", "family", "civic", "general"]

    // MARK: CRM: the hub's crm_write (entity pages, task boards, CRM notes, its own files), the text it read as
    // the base: 409 when the file changed since. Other apps' notes (CRM's tagging) stay the hub's.

    func crmWrite(_ rel: String, text: String, base: String?) -> Int {
        guard Self.writable(rel) else { return 403 }
        if rel.hasSuffix("entity.md"), !Self.keysSingleLine(text) { return 403 }
        guard read(rel) == base else { return 409 }
        return write(rel, text) ? 204 : 500
    }

    // MARK: Jot's Undo: the hub's undo_memo. The memo, its photo and each domain's copy (a copy carries the original's
    // line) move into archived-<day>/ beside them, never deleted. True when there was one, or it is archived already.

    func undoMemo(_ stem: String, day: String? = nil) -> Bool {
        let day = day ?? OmegaFormat.today(.now)
        let fm = FileManager.default
        var found = false
        for d in domainList() {
            let folder = domains.appending(path: "\(d)/source/jot"), md = folder.appending(path: stem + ".md")
            guard fm.fileExists(atPath: md.path),
                  d == "notes" || ((try? String(contentsOf: md, encoding: .utf8)) ?? "").contains("original: notes/source/jot/") else { continue }
            let keep = folder.appending(path: "archived-" + day)
            try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
            for ext in [".md", ".jpg"] where fm.fileExists(atPath: folder.appending(path: stem + ext).path) {
                let to = keep.appending(path: stem + ext)
                try? fm.removeItem(at: to)   // os.replace: the archived copy is the same memo
                try? fm.moveItem(at: folder.appending(path: stem + ext), to: to)
            }
            found = true
        }
        let root = domains.appending(path: "notes/source/jot")
        return found || ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains {
            $0.hasPrefix("archived-") && fm.fileExists(atPath: root.appending(path: "\($0)/\(stem).md").path)
        }
    }

    /// The vault's domains: its folders, minus _meta, _log and the like (the hub's list_domains).
    func domainList() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: domains.path)) ?? [])
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isDir(domains.appending(path: $0)) }.sorted()
    }

    // MARK: Omega: the hub's omega_bundle and omega_write. Life domains are folders with a manifest.json or an
    // ideal-state.md; a write names the sha256 of the text it started from ("none" for a new file), else 409.

    func omegaDomains() -> [String] {
        domainList().filter { d in ["manifest.json", "ideal-state.md"].contains { FileManager.default.fileExists(atPath: domains.appending(path: "\(d)/\($0)").path) } }
    }

    func omegaBundle() -> [String: Any] {
        var files: [String: String] = [:], labels: [String: String] = [:]
        func take(_ rel: String) {
            var d: ObjCBool = false
            let url = vault.appending(path: rel)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &d), !d.boolValue, let data = try? Data(contentsOf: url) {
                files[rel] = String(decoding: data, as: UTF8.self)
            }
        }
        take("build/compass.md")
        for d in omegaDomains() {
            for rel in ["source/goals.md", "memory/tasks.md", "_tasks.md", "ideal-state.md"] { take("data/domains/\(d)/\(rel)") }
            var label = d.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
            if let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: domains.appending(path: "\(d)/manifest.json")))) as? [String: Any],
               let l = (m["identity"] as? [String: Any])?["label"] as? String, !l.isEmpty { label = l }
            labels[d] = label
        }
        for dir in ["reviews", "captures"] {
            let ext = dir == "reviews" ? ".jsonl" : ".md"
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: vault.appending(path: "data/apps/omega/\(dir)").path)) ?? [])
                .filter { $0.hasSuffix(ext) }.sorted()
            for n in dir == "captures" ? Array(names.suffix(300)) : names { take("data/apps/omega/\(dir)/\(n)") }   // the latest 300 said
        }
        return ["files": files, "labels": labels]
    }

    nonisolated(unsafe) static let omegaWritable = /(build\/compass\.md|data\/domains\/[a-z0-9][a-z0-9-]{0,60}\/(source\/goals\.md|memory\/tasks\.md|_tasks\.md)|data\/apps\/omega\/reviews\/\d{4}-\d{2}\.[a-z0-9-]{1,60}\.jsonl|data\/apps\/omega\/captures\/\d{4}-\d{2}-\d{2}-\d{4,6}(-[a-z0-9-]{1,40})?\.md)/

    /// 204, 400 (not one of Omega's files) or 409 (changed since). The Compass keeps its earlier text in
    /// build/compass.versions/<UTC time>.md, as the hub and the engine do.
    func omegaWrite(_ rel: String, _ data: Data, base: String) -> Int {
        guard rel.wholeMatch(of: Self.omegaWritable) != nil, !rel.contains(".."), let text = String(data: data, encoding: .utf8) else { return 400 }
        if let d = rel.wholeMatch(of: /data\/domains\/([^\/]+)\/.*/)?.1, !omegaDomains().contains(String(d)) { return 400 }
        let url = vault.appending(path: rel)
        let now = try? Data(contentsOf: url)
        guard (now.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none") == base else { return 409 }
        if rel == "build/compass.md", let now, case let old = String(decoding: now, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
           !old.isEmpty, old != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
            let stamp = f.string(from: .now)
            var keep = "build/compass.versions/\(stamp).md", n = 1
            while FileManager.default.fileExists(atPath: vault.appending(path: keep).path) { keep = "build/compass.versions/\(stamp)-\(n).md"; n += 1 }
            guard write(keep, String(decoding: now, as: UTF8.self)) else { return 500 }
        }
        return write(rel, text) ? 204 : 500
    }

    // MARK: CRM: the hub's crm_names (front matter only) and crm_move (a merge's archive, an agent's Undo; never deleted).

    func crmNames() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (d, prefix) in [("people", "person"), ("places", "place"), ("orgs", "org"), ("things", "thing")] {
            let dir = vault.appending(path: "data/entities/\(d)")
            let slugs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isDir(dir.appending(path: $0)) }.sorted()
            for slug in slugs {
                let rel = "data/entities/\(d)/\(slug)/entity.md"
                let text = read(rel) ?? ""
                var front: [String: String] = [:]
                if text.hasPrefix("---\n") {
                    let body = text.dropFirst(4)
                    let head = body.range(of: "\n---").map { body[..<$0.lowerBound] } ?? body.dropLast()
                    for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
                        let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        front[kv[0].trimmingCharacters(in: .whitespaces)] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
                    }
                }
                let al = front["aliases"] ?? ""
                let aliases: [String] = al.hasPrefix("[")
                    ? ((try? JSONSerialization.jsonObject(with: Data(al.utf8))) as? [Any])?.map { "\($0)" }
                        ?? al.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    : []
                let name = (front["name"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                out.append(["id": (front["id"] ?? "").isEmpty ? "\(prefix)/\(slug)" : front["id"]!, "name": name.isEmpty ? slug : name, "kind": prefix,
                            "aliases": aliases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "path": rel])
            }
        }
        return out
    }

    static let crmKinds = ["people", "places", "orgs", "things", "events"]

    /// The only moves: an entity folder to or from data/entities/_merged/, a CRM note into data/apps/crm/undone/,
    /// a page an agent made into data/apps/crm/undone/<kind dir>/.
    static func movable(_ src: String, _ dst: String) -> Bool {
        guard safe(src), safe(dst) else { return false }
        let f = src.split(separator: "/", omittingEmptySubsequences: false).map(String.init), t = dst.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if f.count == 6, f[1] == "domains", f[3] == "source", f[4] == "crm", f[5].hasSuffix(".md"),
           t.count == 5, t[1] == "apps", t[2] == "crm", t[3] == "undone", t[4] == f[5] { return true }
        if f.count == 4, f[1] == "entities", crmKinds.contains(f[2]),
           t.count == 6, t[1] == "apps", t[2] == "crm", t[3] == "undone", t[4] == f[2] { return true }
        func merged(_ p: [String]) -> Bool? {
            guard p.count >= 4, p[1] == "entities" else { return nil }
            if p.count == 4, crmKinds.contains(p[2]) { return false }
            if p.count == 5, p[2] == "_merged", crmKinds.contains(p[3]) { return true }
            return nil
        }
        guard let a = merged(f), let b = merged(t) else { return false }
        return a != b
    }

    /// 204 moved, 403 not allowed, 409 missing or already there.
    func crmMove(_ src: String?, _ dst: String?) -> Int {
        guard let src, let dst, Self.movable(src, dst) else { return 403 }
        let a = vault.appending(path: src), b = vault.appending(path: dst), fm = FileManager.default
        guard fm.fileExists(atPath: a.path), !fm.fileExists(atPath: b.path) else { return 409 }
        do {
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: a, to: b)
            return 204
        } catch { return 500 }
    }

    /// A vault-relative path under data/, with no hidden or parent parts.
    static func safe(_ rel: String) -> Bool {
        let p = rel.split(separator: "/", omittingEmptySubsequences: false)
        return p.count >= 2 && p[0] == "data" && p.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    static func writable(_ rel: String) -> Bool {
        guard safe(rel) else { return false }
        let p = rel.split(separator: "/").map(String.init)
        switch (p.count, p[1]) {
        case (5, "entities"): return ["people", "places", "orgs", "things", "events"].contains(p[2]) && p[4] == "entity.md"
        case (5, "domains"): return !p[2].hasPrefix("_") && p[3] == "memory" && p[4] == "tasks.md"
        case (6, "domains"): return !p[2].hasPrefix("_") && p[3] == "source" && p[4] == "crm" && p[5].hasSuffix(".md")
        case (4, "apps"): return p[2] == "crm" && (["settings.json", "synthesis.json"].contains(p[3]) || p[3].hasPrefix("import-"))
        case (5, "apps"): return p[2] == "crm" && ((p[3] == "proposals" && p[4].hasSuffix(".jsonl")) || (p[3] == "merges" && p[4].hasSuffix(".json")))
        default: return rel == "data/entities/merges.json"
        }
    }

    /// attributes: and links: in an entity page's front matter each stay one line of JSON.
    static func keysSingleLine(_ md: String) -> Bool {
        guard md.hasPrefix("---\n") else { return true }
        let rest = md.dropFirst(4)
        let front = rest.range(of: "\n---").map { String(rest[..<$0.lowerBound]) } ?? ""
        for line in front.split(separator: "\n") {
            for key in ["attributes:", "links:"] where line.hasPrefix(key) {
                let v = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if v.isEmpty || (try? JSONSerialization.jsonObject(with: Data(v.utf8), options: .fragmentsAllowed)) == nil { return false }
            }
        }
        return true
    }

    static func quote(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s], options: .withoutEscapingSlashes)) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }

    func isDir(_ url: URL) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue }
}

// MARK: The agents for shells: what each one can do, generated from its tools, and a tool run by name.

extension GlyphAgent {
    /// Every agent and its tools, each with its JSON argument schema, from the tools themselves.
    public static func catalog() throws -> [[String: Any]] {
        let hub = Hub(base: nil, model: "catalog")
        return try all.map { a in
            ["id": a.id, "name": a.name, "color": a.color, "instructions": a.instructions,
             "tools": try a.toolkit(hub, Ledger()).map { t in
                 ["name": t.name, "description": t.description,
                  "arguments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(t.parameters))]
             }]
        }
    }

    public struct UnknownTool: LocalizedError {
        public let agent: String, tool: String
        public var errorDescription: String? { "\(agent) has no tool \(tool)" }
    }

    /// One tool, with its arguments as JSON, through the same `call` the model uses. What it did, as cards.
    public func call(_ tool: String, json: String, hub: Hub) async throws -> [Done] {
        let ledger = Ledger()
        guard let t = toolkit(hub, ledger).first(where: { $0.name == tool }) else { throw UnknownTool(agent: id, tool: tool) }
        _ = try await Self.invoke(t, json)
        return await ledger.done
    }

    static func invoke<T: Tool>(_ t: T, _ json: String) async throws -> String {
        String(describing: try await t.call(arguments: T.Arguments(GeneratedContent(json: json))))
    }
}

extension Done.Undo {
    /// The card's `undo` object back (`glyphcore-report undo '<it>'`), nil when it names none.
    public init?(card o: [String: Any]) {
        if let id = o["well_delete"] as? String { self = .wellDelete(id: id) }
        else if let id = o["crm_reject"] as? String, let file = o["file"] as? String { self = .crmReject(id: id, file: file) }
        else if let stem = o["jot_archive"] as? String { self = .jotArchive(stem: stem) }
        else if let note = o["jot_unfile"] as? String, let place = o["place"] as? String { self = .jotUnfile(note: note, place: place) }
        else if let path = o["restore"] as? String, let app = o["app"] as? String, let after = o["after"] as? String {
            self = .restore(app: app, path: path, before: o["before"] as? String, after: after)
        } else if let id = o["travel_delete"] as? String { self = .travelDelete(id: id) }
        else if let folder = o["crm_unmake"] as? String, let to = o["to"] as? String { self = .crmUnmake(folder: folder, to: to) }
        else if let id = o["life_delete"] as? String { self = .lifeDelete(id: id) }
        else { return nil }
    }
}

extension Done {
    /// The card a shell prints. A Time request says it waits for Time on the iPhone: nothing on a Mac arms it.
    public var card: [String: Any] {
        var o: [String: Any] = ["agent": agent, "ok": ok, "line": line, "title": title,
                                "status": !ok ? "failed" : waiting != nil ? "waiting" : review ? "review" : "done"]
        if let link { o["link"] = link.absoluteString }
        if let waiting {
            o["request"] = waiting
            o["message"] = "Waiting for Time on the iPhone: the request is queued, nothing on this Mac arms it."
        }
        switch undo {
        case .wellDelete(let id): o["undo"] = ["well_delete": id]
        case .travelDelete(let id): o["undo"] = ["travel_delete": id]
        case .crmReject(let id, let file): o["undo"] = ["crm_reject": id, "file": file]
        case .jotArchive(let stem): o["undo"] = ["jot_archive": stem]
        case .jotUnfile(let note, let place): o["undo"] = ["jot_unfile": note, "place": place]
        case .restore(let app, let path, let before, let after): o["undo"] = ["restore": path, "app": app, "before": before as Any? ?? NSNull(), "after": after] as [String: Any]
        case .crmUnmake(let folder, let to): o["undo"] = ["crm_unmake": folder, "to": to]
        case .wealthDelete(let id): o["undo"] = ["wealth_delete": id]
        case .lifeDelete(let id): o["undo"] = ["life_delete": id]
        case nil: break
        }
        return o
    }
}
