import CryptoKit
import Foundation

// Filing: where a read document goes in the vault and everything written about it. Pure files, so
// it runs anywhere GlyphVault does; GlyphAI's `Filer` reads the PDF and calls this. Design:
// the dev domain's document-filing-design note. Everything personal (issuers, properties, accounts)
// lives in the vault's `data/apps/filing/rules.json`, never in this code.
//
//   data/domains/<d>/source/files/[<subject>/]<name>.pdf + <name>.md   a filed document and its note
//   data/apps/filing/rules.json            issuer or sender -> domain, type, subject, entity
//   data/apps/filing/inbox/                drop folder; inbox/.filed/<date>/ once filed
//   data/apps/filing/review/<id>.pdf .json .md   waiting for a yes
//   data/apps/filing/log/<YYYY-MM>.<host>.jsonl  one line per run, one writer per host
//   data/domains/records/memory/expiring.md      every due, expiry and renewal in the next year
//
// Every line written anywhere else carries the document's id (`~src:filing:<id>`, `(filing <id>)`,
// `"thread":"filing:<id>"`), so a rerun adds nothing and undo takes out exactly those lines.

/// One line of `rules.json`: when `match` (any case) is in the sender, the issuer or the first
/// page, the document takes these values. The longest match wins.
public struct FilingRule: Codable, Equatable, Sendable {
    public var match: String
    public var issuer: String?
    public var domain: String?
    public var type: String?
    /// A subfolder: a property's existing `source/current/<subject>/` in real estate, else `source/files/<subject>/`.
    public var subject: String?
    /// A Glyph CRM id the document is always about.
    public var entity: String?
    /// Other domains to tell (a line in their `memory/updates.jsonl`).
    public var also: [String]?

    public init(match: String, issuer: String? = nil, domain: String? = nil, type: String? = nil, subject: String? = nil,
                entity: String? = nil, also: [String]? = nil) {
        self.match = match; self.issuer = issuer; self.domain = domain; self.type = type
        self.subject = subject; self.entity = entity; self.also = also
    }
}

public struct FilingRules: Codable, Equatable, Sendable {
    public var rules: [FilingRule] = []
    /// Document types that may use a cloud model. Read, never acted on: cloud stays off (Fru, 2026-10-29).
    public var cloud_allow: [String] = []
    public init(rules: [FilingRule] = []) { self.rules = rules }

    /// The most specific rule for this sender, issuer and text.
    public func match(from: String?, issuer: String, text: String) -> FilingRule? {
        let hay = [from ?? "", issuer, String(text.prefix(2_500))].map { $0.lowercased() }
        return rules.filter { r in
            let m = r.match.lowercased().trimmingCharacters(in: .whitespaces)
            return m.count >= 3 && hay.contains { $0.contains(m) }
        }.max { $0.match.count < $1.match.count }
    }
}

/// Everything known about one document on its way into the vault. Saved as `review/<id>.json`
/// while it waits, and in each log line, so accept and undo can pick it up again.
public struct FilingRecord: Codable, Equatable, Sendable {
    public var id: String
    public var sha256: String
    public var textSHA256: String
    public var fields: ScanFields
    public var pages: Int
    /// Who called: jot, email, drop, studio, crm, well, backfill.
    public var source: String
    /// "email, account <a>, <sender>, <subject>, <date>" and the like.
    public var from: String?
    public var device: String
    public var scanned: Date
    public var confidence: Double
    public var subject: String?
    public var entityHints: [String]
    public var also: [String]
    public var reason: String?
    /// The vault path it already sits at (backfill notes it in place).
    public var inPlace: String?

    public init(id: String, sha256: String, textSHA256: String, fields: ScanFields, pages: Int, source: String, from: String? = nil,
                device: String, scanned: Date = .now, confidence: Double, subject: String? = nil, entityHints: [String] = [],
                also: [String] = [], reason: String? = nil, inPlace: String? = nil) {
        self.id = id; self.sha256 = sha256; self.textSHA256 = textSHA256; self.fields = fields; self.pages = pages
        self.source = source; self.from = from; self.device = device; self.scanned = scanned; self.confidence = confidence
        self.subject = subject; self.entityHints = entityHints; self.also = also; self.reason = reason; self.inPlace = inPlace
    }
}

/// A filed document's note, as the index reads it back.
public struct FiledNote: Equatable, Sendable {
    public var md: String  // vault-relative path of the note
    public var id: String
    public var sha256: String
    public var textSHA256: String
    public var title: String
    public var issuer: String
    public var type: String
    public var date: String
    public var last4: [String]
    public var deadlines: [(kind: String, date: String)]
    public var status: String
    public static func == (a: FiledNote, b: FiledNote) -> Bool { a.md == b.md && a.id == b.id }

    /// The PDF beside the note.
    public var pdf: String { String(md.dropLast(3)) + ".pdf" }
}

public struct Filing: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// The vault named by `GLYPH_VAULT` in the environment (the installed command sets it from the
    /// owner's own config), nil when unset.
    public static func configuredVault() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["GLYPH_VAULT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public static let app = "data/apps/filing"
    func url(_ rel: String) -> URL { root.appending(path: rel) }
    func read(_ rel: String) -> String? { try? String(contentsOf: url(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url(rel).path) }

    func write(_ rel: String, _ text: String) throws { try write(rel, Data(text.utf8)) }
    /// A report or any other text the filer owns, written whole.
    public func writeText(_ rel: String, _ text: String) throws { try write(rel, text) }
    func write(_ rel: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url(rel), options: .atomic)  // temp file, then rename
    }

    // MARK: Ids and masking

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The same words however the PDF was rendered: lower case letters and digits, single spaces.
    public static func textSHA256(_ text: String) -> String {
        let norm = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
        return sha256(Data(norm.utf8))
    }

    private static let longNumber = try! NSRegularExpression(pattern: #"\d(?:[ -]?\d){8,}"#)

    /// The last net: any run of 9 or more digits (an account, a card, an SSN) cut to its last 4.
    public static func cut(_ s: String) -> String {
        var out = s
        let ns = s as NSString
        for m in longNumber.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            out = (out as NSString).replacingCharacters(in: m.range, with: "ending " + digits.suffix(4))
        }
        return out
    }

    // MARK: Domains, rules, places

    public func domains() -> [String] {
        let dir = url("data/domains")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && (try? dir.appending(path: $0).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted()
    }

    public func rules() -> FilingRules {
        guard let data = try? Data(contentsOf: url(Self.app + "/rules.json")) else { return FilingRules() }
        return (try? JSONDecoder().decode(FilingRules.self, from: data)) ?? FilingRules()
    }

    /// Learns from a yes: the issuer files itself next time.
    public func learn(_ rule: FilingRule) throws {
        var r = rules()
        guard rule.match.count >= 3, !r.rules.contains(where: { $0.match.lowercased() == rule.match.lowercased() }) else { return }
        r.rules.append(rule)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(Self.app + "/rules.json", try e.encode(r))
    }

    /// The tax year a tax form is for: "2025" from "Tax year 2025", "Form W-2 ... 2025".
    public static func taxYear(_ text: String) -> String? {
        let head = String(text.prefix(3_000))
        for p in [#"(?i)tax year:?\s*(20\d{2})"#, #"(?i)(?:form|schedule)\s+[\w-]+.{0,60}?\b(20\d{2})\b"#, #"(?i)\b(20\d{2})\s+form\b"#] {
            if let r = head.range(of: p, options: .regularExpression),
               let y = String(head[r]).range(of: #"20\d{2}"#, options: [.regularExpression, .backwards]) { return String(String(head[r])[y]) }
        }
        return nil
    }

    /// The folder a document goes in: `data/domains/<d>/source/files/`, or a subject under it (a rule's,
    /// or "<YYYY> Tax Year" for a tax form), or a property's existing `source/current/<subject>/` in real estate.
    public func folder(domain: String, subject: String?) -> String {
        let base = "data/domains/\(domain)/source"
        if let s = subject.map(ScanFields.safeName), !s.isEmpty, s != "Document" {
            if domain == "real-estate", exists("\(base)/current/\(s)") { return "\(base)/current/\(s)" }
            return "\(base)/files/\(s)"
        }
        return "\(base)/files"
    }

    /// `name`, or "name 2", "name 3"... when a PDF or note of that name is there already.
    public func freeName(_ folder: String, _ name: String) -> String {
        var n = name, i = 2
        while exists("\(folder)/\(n).pdf") || exists("\(folder)/\(n).md") { n = "\(name) \(i)"; i += 1 }
        return n
    }

    // MARK: The index of filed notes

    /// Every document note in the vault (`kind: scan` front matter) and those waiting in review.
    /// Read each run; about 2,000 small files is well under a second.
    public func index() -> [FiledNote] {
        var out: [FiledNote] = []
        let fm = FileManager.default
        var roots = domains().flatMap { ["data/domains/\($0)/source", "data/domains/\($0)/memory"] }
        roots.append(Self.app + "/review")
        for r in roots {
            guard let walker = fm.enumerator(at: url(r), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                let name = file.lastPathComponent
                if ["threads", "skills", "node_modules", "_archive"].contains(name) || name.hasPrefix("archived-") { walker.skipDescendants(); continue }
                guard file.pathExtension == "md", let note = Self.note(file, root: root) else { continue }
                out.append(note)
            }
        }
        return out
    }

    public static func note(_ file: URL, root: URL) -> FiledNote? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 6_000), let text = String(data: head, encoding: .utf8) ?? String(data: head.dropLast(4), encoding: .utf8),
              text.hasPrefix("---\n"), text.contains("\nkind: scan\n") else { return nil }
        var f: [String: String] = [:]
        for line in text.dropFirst(4).components(separatedBy: "\n") {
            if line == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { f[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        func s(_ k: String) -> String { f[k].map { ($0.hasPrefix("\"") ? (try? JSONDecoder().decode(String.self, from: Data($0.utf8))) : $0) ?? $0 } ?? "" }
        let refs = (f["references"].flatMap { try? JSONDecoder().decode([ScanReference].self, from: Data($0.utf8)) } ?? []).map(\.last4)
        let dl = (f["deadlines"].flatMap { try? JSONDecoder().decode([[String: String]].self, from: Data($0.utf8)) } ?? [])
            .compactMap { d in d["kind"].flatMap { k in d["date"].map { (kind: k, date: $0) } } }
        let rel = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        return FiledNote(md: rel, id: s("scan"), sha256: s("sha256"), textSHA256: s("text_sha256"), title: s("title"), issuer: s("issuer"),
                         type: s("type"), date: s("date"), last4: refs, deadlines: dl, status: s("status").isEmpty ? "filed" : s("status"))
    }

    /// The filed note this document already is: same bytes or same words.
    public func duplicate(of r: FilingRecord, in index: [FiledNote]) -> FiledNote? {
        index.first { $0.status != "review" && ($0.sha256 == r.sha256 || (!r.textSHA256.isEmpty && $0.textSHA256 == r.textSHA256)) }
    }

    /// A different file that looks like the same document: issuer, type, date and a reference's last 4.
    public func lookalike(of r: FilingRecord, in index: [FiledNote]) -> FiledNote? {
        let f = r.fields
        guard !f.issuer.isEmpty, let d = f.date, let l4 = f.references.first?.last4 else { return nil }
        return index.first { $0.status != "review" && $0.issuer.lowercased() == f.issuer.lowercased() && $0.type == f.type && $0.date == d && $0.last4.contains(l4) }
    }

    // MARK: The note

    /// Scan.swift's note plus Filing's keys and what was done.
    public func sidecar(_ r: FilingRecord, file: String, status: String, entities: [String], actions: [String], proposedPath: String? = nil) -> String {
        var f = r.fields
        f.summary = Self.cut(f.summary)
        var note = f.sidecar(stem: r.id, pages: r.pages, device: r.device, scanned: r.scanned, source: r.source)
        // The file it really is ("<name> 2", or where backfill found it); the title stays the proposed name.
        if file != f.name {
            note = note.components(separatedBy: "\n").map { $0.hasPrefix("file: ") ? "file: " + Self.quote(file + ".pdf") : $0 }.joined(separator: "\n")
                .replacingOccurrences(of: "(<\(f.name).pdf>)", with: "(<\(file).pdf>)")
        }
        var extra = ["from: \(Self.quote(r.from.map(Self.cut) ?? ""))", "sha256: \"\(r.sha256)\"", "text_sha256: \"\(r.textSHA256)\"",
                     "status: \(status)", "confidence: \(String(format: "%.2f", r.confidence))"]
        if let p = proposedPath { extra.append("proposed_path: \(Self.quote(p))") }
        if let reason = r.reason { extra.append("reason: \(Self.quote(reason))") }
        extra.append("moved_from:")
        if let end = note.range(of: "\n---\n", range: note.index(note.startIndex, offsetBy: 3)..<note.endIndex) {
            note.insert(contentsOf: "\n" + extra.joined(separator: "\n"), at: end.lowerBound)
        }
        if let withIDs = EntityRefs.adding(entities, to: note) { note = withIDs }
        if !actions.isEmpty { note += "\n## Actions taken\n\n" + actions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return note
    }

    static func quote(_ s: String) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        return (try? e.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    // MARK: Writing a filed document

    public struct Written: Sendable {
        public var pdf: String
        public var md: String
        public var entities: [String]
        public var proposals: [String]
        public var actions: [(kind: String, file: String)]
    }

    /// Writes the PDF and its note, links and every other place. `pdf` nil: the PDF is already at
    /// `record.inPlace` (backfill), so only the note goes beside it and nothing else is touched but
    /// the Expiring list and suggestions.
    /// `expiring` false: the caller remakes the Expiring list once at the end (backfill).
    public func file(_ r: FilingRecord, pdf: Data?, directory: StudioDirectory? = nil, now: Date = .now, expiring: Bool = true) throws -> Written {
        let f = r.fields
        let pdfRel: String
        if let place = r.inPlace {
            pdfRel = place
        } else {
            let folder = folder(domain: f.domain, subject: r.subject)
            pdfRel = folder + "/" + freeName(folder, Self.cut(f.name)) + ".pdf"
        }
        let base = String(pdfRel.dropLast(4))
        let mdRel = base + ".md"
        let fileName = (base as NSString).lastPathComponent
        let dir = directory ?? StudioDirectory(root: root)
        let (entities, wanted) = link(r, dir)
        var actions: [(kind: String, file: String)] = []
        var said: [String] = []
        if r.inPlace == nil {
            let issuer = f.issuer.isEmpty ? f.type : f.issuer
            if let due = f.due {
                let what = "Pay \(issuer)\(f.mainAmount.map { " " + $0.display } ?? "") \(f.type.lowercased())"
                if try addLine(taskFile(f.domain), "- [ ] \(Self.cut(what)) @\(due) ~src:filing:\(r.id)", token: "~src:filing:\(r.id)", header: "# Tasks") {
                    actions.append(("task", taskFile(f.domain))); said.append("Task in \(f.domain): pay by \(due)")
                }
            }
            for d in f.deadlines where d.kind != "due" {
                let file = "data/domains/\(f.domain)/memory/key-dates.md"
                let token = "\(d.kind) (filing \(r.id))"  // one line per kind: expires, renews
                if try addLine(file, "- \(d.date): \(Self.cut(issuer)) \(f.type.lowercased()) \(token)", token: token, header: "# Key Dates") {
                    if !actions.contains(where: { $0.file == file }) { actions.append(("key-date", file)) }
                    said.append("Key date in \(f.domain): \(d.date) \(d.kind == "expires" ? "expiry" : "renewal")")
                }
            }
            for other in r.also where other != f.domain && domains().contains(other) {
                let file = "data/domains/\(other)/memory/updates.jsonl"
                let fact = Self.cut("\(f.type) from \(issuer)\(f.date.map { ", \($0)" } ?? ""): \(f.summary) (\(mdRel))")
                let obj: [String: Any] = ["ts": Int(now.timeIntervalSince1970 * 1000), "from_domain": f.domain, "thread": "filing:\(r.id)", "fact": fact, "entities": entities]
                let line = String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
                if try addLine(file, line, token: "\"thread\":\"filing:\(r.id)\"", header: nil) {
                    actions.append(("updates", file)); said.append("Noted in \(other) (updates.jsonl)")
                }
            }
        }
        let proposals = try propose(wanted, note: mdRel, evidence: f.summary, now: now)
        if let pdf, r.inPlace == nil { try write(pdfRel, pdf) }
        try write(mdRel, sidecar(r, file: fileName, status: "filed", entities: entities, actions: said))
        if expiring { try writeExpiring(now: now) }
        return Written(pdf: pdfRel, md: mdRel, entities: entities, proposals: proposals, actions: actions)
    }

    func taskFile(_ domain: String) -> String {
        exists("data/domains/\(domain)/_tasks.md") && !exists("data/domains/\(domain)/memory/tasks.md")
            ? "data/domains/\(domain)/_tasks.md" : "data/domains/\(domain)/memory/tasks.md"
    }

    /// Appends `line` once: false when a line already carries `token`.
    @discardableResult
    func addLine(_ rel: String, _ line: String, token: String, header: String?) throws -> Bool {
        let old = read(rel) ?? header.map { $0 + "\n" } ?? ""
        if old.contains(token) { return false }
        try write(rel, (old.hasSuffix("\n") || old.isEmpty ? old : old + "\n") + line + "\n")
        return true
    }

    /// Existing ids for the issuer, people and places named; the rest as names to suggest.
    func link(_ r: FilingRecord, _ dir: StudioDirectory) -> (ids: [String], wanted: [(kind: String, name: String)]) {
        var ids = r.entityHints.filter(StudioObject.isID)
        var wanted: [(kind: String, name: String)] = []
        func add(_ name: String, _ kinds: [StudioObject.Kind], propose: String) {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard n.count >= 2 else { return }
            if let o = kinds.lazy.compactMap({ dir.match(n, $0) }).first { if !ids.contains(o.id) { ids.append(o.id) } }
            else if !wanted.contains(where: { $0.name.lowercased() == n.lowercased() }) { wanted.append((propose, n)) }
        }
        add(r.fields.issuer, [.org], propose: "org")
        r.fields.people.forEach { add($0, [.person], propose: "person") }
        r.fields.about.forEach { add($0, [.place, .thing], propose: $0.first?.isNumber == true ? "place" : "thing") }
        return (ids, wanted)
    }

    /// Glyph CRM suggestion lines (data/apps/crm/proposals/<YYYY-MM>.jsonl), each once. Returns their ids.
    func propose(_ wanted: [(kind: String, name: String)], note: String, evidence: String, now: Date) throws -> [String] {
        guard !wanted.isEmpty else { return [] }
        let month = String(ScanText.day.string(from: now).prefix(7))
        let rel = "data/apps/crm/proposals/\(month).jsonl"
        var text = read(rel) ?? ""
        var made: [String] = []
        let iso = ISO8601DateFormatter()
        for w in wanted {
            let name = w.name.split(whereSeparator: \.isNewline).joined(separator: " ")
            // The same id Glyph CRM gives this suggestion (CRMKit Proposal.init), so it is never made twice.
            let id = String(Self.sha256(Data([w.kind, name.lowercased(), "", "", "", "", "", note].joined(separator: "|").utf8)).prefix(16))
            made.append(id)
            guard !text.contains("\"id\":\"\(id)\"") else { continue }
            let obj: [String: Any] = ["at": iso.string(from: now), "source": "document", "kind": w.kind, "name": name,
                                      "evidence": String(Self.cut(evidence).prefix(240)), "path": note, "status": "pending", "id": id]
            text += String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)! + "\n"
        }
        try write(rel, text)
        return made
    }

    // MARK: Expiring list, review, log

    /// `records/memory/expiring.md`, made again from every note: due, expiry and renewal dates in the next 12 months.
    public func writeExpiring(now: Date = .now) throws {
        guard domains().contains("records") else { return }
        let rows = expiring(now: now)
        func lines(_ rs: [Obligation]) -> String {
            rs.map { o in
                // The collapsed copies are named in the line, so the count is never a silent omission.
                let also = o.copies > 1 ? " (\(o.copies) copies on file)" : ""
                return "- \(o.date) \(o.kind): [\(o.note.title)](<../../../../\(o.note.md)>)\(also)"
            }.joined(separator: "\n") + "\n"
        }
        var text = "# Expiring\n\nDue, expiry and renewal dates from filed documents, the next 12 months. Made by the filer; edits here are replaced.\n\n"
        text += rows.isEmpty ? "Nothing in the next 12 months.\n" : lines(rows)
        // The gap worth more than the forward list when the filed documents are mostly historical.
        let gaps = lapsed(now: now)
        if !gaps.isEmpty {
            text += "\n## Lapsed, nothing newer filed\n\nThese dates have passed and no later document from the same issuer of the same type is on file. Either the replacement was never filed, or the thing really has lapsed.\n\n"
            text += lines(gaps)
        }
        if read("data/domains/records/memory/expiring.md") != text { try write("data/domains/records/memory/expiring.md", text) }
    }

    /// One dated obligation: the document that carries it, what happens on that day, and how many
    /// filed copies of the same paper were collapsed into this row. `copies` exists so a reader can
    /// SAY a copy was suppressed; an absence nobody can see is a lie by omission.
    public struct Obligation: Sendable, Identifiable {
        public let note: FiledNote
        public let kind: String      // expires, renews, due
        public let date: String      // YYYY-MM-DD
        public let copies: Int       // 1 when this is the only copy on file
        public var id: String { "\(note.md)|\(kind)|\(date)" }
    }

    /// Every due, expiry and renewal in the next 12 months, one row per obligation, soonest first.
    /// `writeExpiring` turns this into the markdown an agent reads; an app shows it as a pane. Both
    /// call this, so the list a person sees and the list an agent reads can never disagree.
    public func expiring(now: Date = .now) -> [Obligation] {
        let today = ScanText.day.string(from: now)
        let end = ScanText.day.string(from: now.addingTimeInterval(366 * 86_400))
        let all = index().filter { $0.status == "filed" }.flatMap { n in n.deadlines.map { (n, $0) } }
            .filter { $0.1.date >= today && $0.1.date <= end }
        return Self.oneRowPerObligation(all)
    }

    /// The gap the Expiring list cannot show: obligations whose date has already passed and for which
    /// no newer document of the same kind was ever filed. A policy that expired with a replacement on
    /// disk is fine; one that expired with nothing after it is either unfiled or genuinely lapsed, and
    /// only the person can tell which. Looks back `months` (two years by default), because a date from
    /// 2009 is history, not a gap.
    ///
    /// "Nothing newer" means: among every filed document from the same issuer of the same type, this
    /// one carries the latest document date. If a replacement had been filed its own date would be
    /// later, so it would take this one's place and nothing would be reported.
    public func lapsed(now: Date = .now, months: Int = 24) -> [Obligation] {
        let today = ScanText.day.string(from: now)
        let from = ScanText.day.string(from: now.addingTimeInterval(-Double(months) * 30.5 * 86_400))
        let filed = index().filter { $0.status == "filed" }
        // The latest document date on file per issuer and type, which is what a replacement would move.
        var newest: [String: String] = [:]
        for n in filed where !n.issuer.isEmpty {
            let k = n.issuer.lowercased() + "|" + n.type.lowercased()
            if n.date > (newest[k] ?? "") { newest[k] = n.date }
        }
        let rows = filed.flatMap { n in n.deadlines.map { (n, $0) } }
            .filter { r in
                guard r.1.date < today, r.1.date >= from, !r.0.issuer.isEmpty, !r.0.date.isEmpty else { return false }
                return newest[r.0.issuer.lowercased() + "|" + r.0.type.lowercased()] == r.0.date
            }
        // Most recently lapsed first: the likeliest to still matter.
        return Self.oneRowPerObligation(rows).sorted { $0.date > $1.date }
    }

    /// One row per real obligation, not one per copy of the paper. The same policy is filed under
    /// several domains and re-rendered by the issuer, so bytes and even normalized text differ while
    /// the obligation is one: on one real vault 38 rows are 18 by sha256, 15 by text, 12 by this key.
    /// The key is the design's own duplicate rule (same issuer, type, document date, last 4) plus the
    /// deadline itself, so two genuinely different obligations are never merged into one line.
    /// The copy kept is the one under `source/` (the user's own material, per VAULT.md), then the
    /// shortest path, then alphabetical, so the list is the same on every machine and every run; the
    /// ones not kept are counted, never silently dropped.
    static func oneRowPerObligation(_ rows: [(FiledNote, (kind: String, date: String))]) -> [Obligation] {
        var at: [[String]: Int] = [:]
        var kept: [(FiledNote, (kind: String, date: String))] = []
        var copies: [Int] = []
        for r in rows {
            let key = [r.1.date, r.1.kind, r.0.issuer, r.0.type, r.0.date, r.0.last4.sorted().joined(separator: ",")]
            if let i = at[key] {
                copies[i] += 1
                if preferred(r.0, over: kept[i].0) { kept[i] = r }
            } else {
                at[key] = kept.count
                kept.append(r)
                copies.append(1)
            }
        }
        return zip(kept, copies).map { Obligation(note: $0.0, kind: $0.1.kind, date: $0.1.date, copies: $1) }
            .sorted { ($0.date, $0.note.title, $0.note.md) < ($1.date, $1.note.title, $1.note.md) }
    }

    /// Which copy of one document the list should point at.
    static func preferred(_ a: FiledNote, over b: FiledNote) -> Bool {
        let sa = a.md.contains("/source/"), sb = b.md.contains("/source/")
        if sa != sb { return sa }
        if a.md.count != b.md.count { return a.md.count < b.md.count }
        return a.md < b.md
    }

    public func reviewIDs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(Self.app + "/review").path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    public func reviewRecord(_ id: String) -> FilingRecord? {
        guard let data = try? Data(contentsOf: url(Self.app + "/review/\(id).json")) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(FilingRecord.self, from: data)
    }

    /// Puts a document in review: its PDF, its record and a proposed note, and the count on the records board.
    public func review(_ r: FilingRecord, pdf: Data?, proposedPath: String) throws -> String {
        let base = Self.app + "/review/\(r.id)"
        if let pdf { try write(base + ".pdf", pdf) }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601
        try write(base + ".json", try e.encode(r))
        try write(base + ".md", sidecar(r, file: r.id, status: "review", entities: [], actions: [], proposedPath: proposedPath))
        try updateReviewLine()
        return base + ".pdf"
    }

    /// A document already in the vault that is under the bar (backfill): its note beside the PDF says
    /// `status: review`, and its record waits in `review/<id>.json` without a copy of the PDF, so Accept
    /// files it where it is. Nothing is moved; no suggestions or Expiring lines are made from a guess.
    public func reviewInPlace(_ r: FilingRecord, proposedDomain: String) throws {
        guard let place = r.inPlace else { return }
        let base = String(place.dropLast(4))
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601
        try write(Self.app + "/review/\(r.id).json", try e.encode(r))
        let proposed = folder(domain: proposedDomain, subject: r.subject) + "/" + Self.cut(r.fields.name) + ".pdf"
        try write(base + ".md", sidecar(r, file: (base as NSString).lastPathComponent, status: "review", entities: [], actions: [], proposedPath: proposed))
        try updateReviewLine()
    }

    /// Takes a document out of review once filed.
    public func clearReview(_ id: String) throws {
        for ext in ["pdf", "json", "md"] { try? FileManager.default.removeItem(at: url(Self.app + "/review/\(id).\(ext)")) }
        try updateReviewLine()
    }

    /// One line on the records board saying how many wait, changed in place; gone when none do.
    func updateReviewLine() throws {
        guard domains().contains("records") else { return }
        let rel = taskFile("records")
        let n = reviewIDs().count
        let token = "~src:filing:review"
        var lines = (read(rel) ?? "# Tasks\n").components(separatedBy: "\n")
        let line = "- [ ] Review \(n) document\(n == 1 ? "" : "s") waiting to be filed \(token)"
        if let i = lines.firstIndex(where: { $0.contains(token) }) {
            if n == 0 { lines.remove(at: i) } else { lines[i] = line }
        } else if n > 0 {
            if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
        } else { return }
        try write(rel, lines.joined(separator: "\n"))
    }

    public static var host: String {
        let s = StudioDirectory.slug(ThisDevice.name)
        return s.isEmpty ? "mac" : String(s.prefix(40))
    }

    /// One JSON line in `log/<YYYY-MM>.<host>.jsonl`.
    public func log(_ object: [String: Any], now: Date = .now) throws {
        let rel = Self.app + "/log/\(ScanText.day.string(from: now).prefix(7)).\(Self.host).jsonl"
        var o = object
        o["ts"] = ISO8601DateFormatter().string(from: now)
        let line = String(data: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        let old = read(rel) ?? ""
        try write(rel, old + Self.cut(line) + "\n")
    }

    /// The last record logged for an id, from any host's log.
    public func loggedRecord(_ id: String) -> FilingRecord? {
        let dir = url(Self.app + "/log")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        var found: FilingRecord?
        for f in files {
            for line in (read(Self.app + "/log/" + f) ?? "").split(separator: "\n") where line.contains("\"id\":\"\(id)\"") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let rec = o["record"],
                      let data = try? JSONSerialization.data(withJSONObject: rec), let r = try? d.decode(FilingRecord.self, from: data) else { continue }
                found = r
            }
        }
        return found
    }

    /// Undo: the PDF and note go back to review (moved, never deleted) and every line carrying the id comes out.
    public func undo(_ id: String) throws -> Bool {
        guard let n = index().first(where: { $0.id == id && $0.status == "filed" }) else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: url(Self.app + "/review"), withIntermediateDirectories: true)
        let wasInPlace = (read(n.md) ?? "").contains("\nsource: backfill\n")
        if !wasInPlace, exists(n.pdf) {
            try? fm.removeItem(at: url(Self.app + "/review/\(id).pdf"))
            try fm.moveItem(at: url(n.pdf), to: url(Self.app + "/review/\(id).pdf"))
        }
        try? fm.removeItem(at: url(Self.app + "/review/\(id).md"))
        try fm.moveItem(at: url(n.md), to: url(Self.app + "/review/\(id).md"))
        if var r = loggedRecord(id) {
            r.inPlace = wasInPlace ? n.pdf : nil
            r.reason = "undone"
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
            try write(Self.app + "/review/\(id).json", try e.encode(r))
        }
        for d in domains() {
            for (rel, token) in [(taskFile(d), "~src:filing:\(id)"), ("data/domains/\(d)/memory/key-dates.md", "(filing \(id))"),
                                 ("data/domains/\(d)/memory/updates.jsonl", "\"thread\":\"filing:\(id)\"")] {
                guard let old = read(rel), old.contains(token) else { continue }
                try write(rel, old.components(separatedBy: "\n").filter { !$0.contains(token) }.joined(separator: "\n"))
            }
        }
        try writeExpiring()
        try updateReviewLine()
        return true
    }
}
