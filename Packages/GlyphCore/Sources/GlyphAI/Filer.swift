import Foundation
import GlyphVault
import PDFKit

/// The one filing pipeline every app and agent uses (`glyphcore-report file`, Jot, Studio, CRM,
/// the mini inbox): read -> fingerprint -> classify -> extract -> decide -> name -> write -> link
/// -> update -> log. Below the confidence bar a document waits in review rather than being guessed.
///
///     let result = await Filer(vault: url).file(Filer.Request(path: pdf, source: "email", from: "..."))
public struct Filer: Sendable {
    public let filing: Filing
    /// Off: rules and the word lists alone (tests, or a Mac without Apple Intelligence).
    public var useModel: Bool

    public init(vault: URL, useModel: Bool = true) {
        filing = Filing(root: vault)
        self.useModel = useModel
    }

    public struct Request: Sendable {
        public var path: URL
        public var source: String
        /// A short line about where it came from: sender, subject, account, date.
        public var from: String?
        /// The sender's address or name, matched against rules.json.
        public var sender: String?
        public var domain: String?
        public var entity: String?
        public var type: String?
        public var subject: String?
        public var device: String
        public var dryRun: Bool
        /// Fields a person already checked (Glyph Jot's review card): they win over what is read again,
        /// so a fix said on the phone is what gets filed.
        public var reviewed: ScanFields?

        public init(path: URL, source: String = "drop", from: String? = nil, sender: String? = nil, domain: String? = nil, entity: String? = nil,
                    type: String? = nil, subject: String? = nil, device: String = ThisDevice.name, dryRun: Bool = false, reviewed: ScanFields? = nil) {
            self.path = path; self.source = source; self.from = from; self.sender = sender; self.domain = domain; self.entity = entity
            self.type = type; self.subject = subject; self.device = device; self.dryRun = dryRun; self.reviewed = reviewed
        }
    }

    /// The answer, as `glyphcore-report file --json` prints it.
    public struct Result: Sendable {
        public var status: String  // filed, duplicate, review, error
        public var id = ""
        public var path: String?
        public var sidecar: String?
        public var record: FilingRecord?
        public var links: [String] = []
        public var proposals: [String] = []
        public var actions: [(kind: String, file: String)] = []
        public var duplicateOf: String?
        public var reviewReason: String?
        public var reviewPath: String?
        public var model = "off"
        public var dryRun = false
        public var error: String?
        public var seconds = 0.0

        public var exitCode: Int32 { status == "filed" || status == "duplicate" ? 0 : status == "review" ? 2 : 1 }

        public var json: [String: Any] {
            let f = record?.fields
            var fields: [String: Any] = [:]
            if let f {
                fields = ["issuer": f.issuer, "people": f.people, "about": f.about, "summary": f.summary,
                          "amounts": f.amounts.map { ["label": $0.label, "value": $0.value, "currency": $0.currency] },
                          "references": f.references.map { ["label": $0.label, "last4": $0.last4] }]
                for (k, v) in [("date", f.date), ("due", f.due), ("expires", f.expires), ("renews", f.renews), ("period", f.period)] { if let v { fields[k] = v } }
            }
            let null = NSNull()
            return ["status": status, "id": id, "path": path ?? null, "sidecar": sidecar ?? null, "type": f?.type ?? null, "domain": f?.domain ?? null,
                    "confidence": record.map { ($0.confidence * 100).rounded() / 100 } ?? null, "fields": fields,
                    "links": ["entities": links, "proposals": proposals], "actions": actions.map { ["kind": $0.kind, "file": $0.file] },
                    "duplicate_of": duplicateOf ?? null,
                    "review": reviewReason.map { ["reason": $0, "path": reviewPath ?? ""] as [String: Any] } ?? null,
                    "model": model, "dry_run": dryRun, "error": error ?? null, "seconds": (seconds * 10).rounded() / 10]
        }
    }

    // MARK: Reading

    /// The PDF (made from images, or given a text layer when it is a scan) and its words.
    public struct Read: Sendable {
        public var pdf: Data
        public var text: String
        public var pages: Int
        public var ocr: Bool
        public init(pdf: Data, text: String, pages: Int, ocr: Bool) { self.pdf = pdf; self.text = text; self.pages = pages; self.ocr = ocr }
    }

    public func read(_ url: URL) async throws -> Read {
        let data = try Data(contentsOf: url)
        if let doc = PDFDocument(data: data) {
            let texts = DocumentReader.pageTexts(doc)
            guard DocumentReader.isThin(texts) else { return Read(pdf: data, text: texts.joined(separator: "\n\n"), pages: doc.pageCount, ocr: false) }
            var lines: [[DocumentReader.Line]] = []
            for i in 0..<min(doc.pageCount, 40) {
                guard let page = doc.page(at: i), let img = DocumentReader.render(page) else { lines.append([]); continue }
                lines.append((try? await DocumentReader.ocr(img)) ?? [])
            }
            let text = lines.map(DocumentReader.text).joined(separator: "\n\n")
            return Read(pdf: DocumentReader.addingText(to: doc, lines: lines) ?? data, text: text, pages: doc.pageCount, ocr: true)
        }
        let images = DocumentReader.images(data)
        guard !images.isEmpty else { throw FilerError.unreadable }
        var pages: [(image: CGImage, lines: [DocumentReader.Line])] = []
        for img in images { pages.append((img, (try? await DocumentReader.ocr(img)) ?? [])) }
        guard let pdf = DocumentReader.pdf(pages: pages) else { throw FilerError.unreadable }
        return Read(pdf: pdf, text: pages.map { DocumentReader.text($0.lines) }.joined(separator: "\n\n"), pages: pages.count, ocr: true)
    }

    public enum FilerError: LocalizedError {
        case unreadable
        public var errorDescription: String? { "not a PDF or an image this Mac can read" }
    }

    // MARK: Deciding

    /// Fields, confidence, and why it must wait for a yes (nil: it can be filed).
    public func decide(_ read: Read, _ req: Request, rules: FilingRules, domains: [String], model: DocumentReader.ModelFields?) -> FilingRecord {
        let text = read.text
        var f = ScanText.read(text, scanned: .now, domains: domains)
        let scoredTypes = ScanText.typeScores(text)
        let words = scoredTypes.first.flatMap { $0.score > 0 ? $0 : nil }
        let rule = rules.match(from: req.sender ?? req.from, issuer: model?.issuer ?? f.issuer, text: text)
        // Type: a rule or the caller; else the words (a heading counts three), with the model choosing
        // only among types the words back. Nothing backed: a plain Document.
        var typeConf = 0.5
        if let t = req.type ?? rule?.type, ScanText.types.contains(where: { $0.name == t }) || t == "Document" {
            f.type = t; typeConf = 1
        } else if let t = ScanText.titleType(text) {
            f.type = t; typeConf = 0.9  // the document's own heading
        } else if let m = model?.type, let backed = scoredTypes.first(where: { $0.name == m }), backed.score > 0,
                  backed.score >= (words?.score ?? 0) - 1 {  // the model picks between close calls, never against clear words
            f.type = m
            typeConf = m == words?.name ? 0.95 : 0.85
        } else if let w = words {
            f.type = w.name
            let next = scoredTypes.dropFirst().first?.score ?? 0
            typeConf = w.score >= 3 && w.score > next ? 0.9 : w.score >= 2 && w.score > next ? 0.85 : 0.7
        } else {
            f.type = "Document"; typeConf = model == nil ? 0.6 : 0.8
        }
        // Issuer, people, places: the rule, else the model's (found in the text), else the letterhead.
        f.issuer = rule?.issuer ?? model?.issuer ?? f.issuer
        // People are people, not the company that sent it; a place or thing is not a line with a date in it.
        let issuers = Set([f.issuer, model?.issuer ?? "", ScanText.issuer(in: text)].map { $0.lowercased() })
        f.people = (model?.people ?? []).filter { !issuers.contains($0.lowercased()) }
        f.about = (model?.about ?? []).filter { ScanText.allDays(in: $0).isEmpty && !issuers.contains($0.lowercased()) }
        // Dates from the labelled words first; the model only fills gaps, and only with dates in the text.
        let found = ScanText.datesLabelled(in: text)
        // A statement is dated by the end of its period unless it names its own date.
        let periodEnd = f.type == "Statement" && !found.labelled ? found.period?.components(separatedBy: " to ").last : nil
        let dated = periodEnd ?? found.date ?? model?.date
        f.date = dated ?? f.date
        f.due = f.due ?? model?.due
        f.expires = f.expires ?? model?.expires
        f.renews = f.renews ?? model?.renews
        // Domain: the caller, a rule, else strong words, else the type's home.
        var domainConf = 0.5
        if let d = req.domain ?? rule?.domain, domains.isEmpty || domains.contains(d) {
            f.domain = d; domainConf = 1
        } else {
            f.domain = ScanText.domain(type: f.type, text: text, domains: domains)
            let scores = ScanText.domainScores(text)
            let top = scores.first, second = scores.dropFirst().first?.score ?? 0
            let home = ScanText.types.first { $0.name == f.type }?.domain
            if let top, top.domain == f.domain, top.score >= 2, top.score > second { domainConf = 0.92 }
            else if home == f.domain, typeConf >= 0.8, scores.isEmpty || top?.domain == home { domainConf = 0.88 }
            else if f.type == "Document", let top, top.domain == f.domain, second == 0 { domainConf = 0.86 }
        }
        // The amount the model pointed at, as printed on the page, goes first.
        if let a = model?.mainAmount, let parsed = ScanText.amounts(in: a.contains("$") || a.contains(".") ? a : "$" + a).first {
            let label = Self.amountLabel(model?.mainAmountLabel ?? "")
            f.amounts.removeAll { $0.value == parsed.value }
            f.amounts.insert(ScanAmount(label: label, value: parsed.value), at: 0)
        }
        // Deadlines only where a document can have them: no expiry on a statement or a receipt, and a
        // due date only on a bill or an invoice, or beside an amount due.
        if ["Statement", "Receipt", "Bill", "Invoice", "Tax Form", "Lab Result", "Medical Record"].contains(f.type) { f.expires = nil; f.renews = nil }
        if !["Bill", "Invoice"].contains(f.type), f.mainAmount?.label != "Amount due" { f.due = nil }
        if let due = f.due, let date = dated, due < date { f.due = nil }  // an old line in the document, not what is owed now
        f.summary = model?.summary ?? f.plainSummary
        var subject = req.subject ?? rule?.subject
        if subject == nil, f.domain == "tax", let y = Filing.taxYear(text) { subject = "\(y) Tax Year" }
        var reasons: [String] = []
        if typeConf < 0.8 { reasons.append("type unclear (\(f.type)?)") }
        if domainConf < 0.85 { reasons.append("domain unclear (\(f.domain)?)") }
        if dated == nil { reasons.append("no document date found") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 { reasons.append("no readable text") }
        let id = String(Filing.sha256(read.pdf).prefix(8))
        return FilingRecord(id: id, sha256: Filing.sha256(read.pdf), textSHA256: text.count < 20 ? "" : Filing.textSHA256(text), fields: f,
                            pages: read.pages, source: req.source, from: req.from, device: req.device,
                            confidence: min(typeConf, domainConf, dated == nil ? 0.5 : 1),
                            subject: subject, entityHints: [req.entity, rule?.entity].compactMap { $0 }, also: rule?.also ?? [],
                            reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }

    /// The model's words for an amount, as one of the labels the code uses.
    static func amountLabel(_ said: String) -> String {
        let l = said.lowercased()
        if ["due", "remit", "pay"].contains(where: l.contains) { return "Amount due" }
        if l.contains("net") || l.contains("owner") { return "Net" }
        for (k, v) in [("subtotal", "Subtotal"), ("total", "Total"), ("premium", "Premium"), ("rent", "Rent"), ("balance", "Balance"), ("deposit", "Deposit")] where l.contains(k) { return v }
        return "Amount"
    }

    // MARK: Filing one

    public func file(_ req: Request) async -> Result {
        let start = Date()
        var result = await fileOnce(req)
        result.seconds = Date().timeIntervalSince(start)
        if !req.dryRun || result.status == "error" {
            var line = result.json
            line["source"] = req.source
            if let r = result.record {
                let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
                line["record"] = (try? JSONSerialization.jsonObject(with: e.encode(r))) ?? NSNull()
            }
            try? filing.log(line)
        }
        return result
    }

    func fileOnce(_ req: Request) async -> Result {
        // The bytes as given: the same file again is a duplicate even before it is read.
        let raw = (try? Data(contentsOf: req.path)) ?? Data()
        let index = filing.index()
        if let n = index.first(where: { $0.status != "review" && $0.sha256 == Filing.sha256(raw) }) {
            return Result(status: "duplicate", id: n.id, path: n.pdf, sidecar: n.md, duplicateOf: n.pdf, dryRun: req.dryRun)
        }
        let read: Read
        do { read = try await self.read(req.path) } catch {
            return Result(status: "error", dryRun: req.dryRun, error: error.localizedDescription)
        }
        let model = useModel ? await DocumentReader.modelRead(read.text) : nil
        var r = decide(read, req, rules: filing.rules(), domains: filing.domains(), model: model)
        if var checked = req.reviewed {
            // What a person checked is filed as said: only a domain the vault has, references kept to their last 4.
            if !filing.domains().contains(checked.domain) { checked.domain = r.fields.domain }
            checked.summary = Filing.cut(checked.summary)
            r.fields = checked
            r.confidence = 1
            r.reason = checked.date == nil ? "no document date found" : nil
        }
        // The original's hash too, so the same download is caught however the PDF was rebuilt.
        if Filing.sha256(raw) != r.sha256 { r.sha256 = Filing.sha256(raw) }
        var result = Result(status: "filed", id: r.id, record: r, model: model == nil ? "off" : "on-device", dryRun: req.dryRun)
        if let dup = filing.duplicate(of: r, in: index) {
            result.status = "duplicate"; result.duplicateOf = dup.pdf; result.path = dup.pdf; result.sidecar = dup.md; result.id = dup.id
            return result
        }
        if r.reason == nil, let look = filing.lookalike(of: r, in: index) { r.reason = "looks like \(look.pdf)" }
        let folder = filing.folder(domain: r.fields.domain, subject: r.subject)
        let proposed = folder + "/" + filing.freeName(folder, Filing.cut(r.fields.name)) + ".pdf"
        result.record = r
        if let reason = r.reason {
            result.status = "review"; result.reviewReason = reason; result.path = proposed
            if !req.dryRun {
                do { result.reviewPath = try filing.review(r, pdf: read.pdf, proposedPath: proposed) } catch { return fail(result, error) }
            }
            return result
        }
        guard !req.dryRun else { result.path = proposed; result.sidecar = String(proposed.dropLast(4)) + ".md"; return result }
        do {
            let w = try filing.file(r, pdf: read.pdf)
            result.path = w.pdf; result.sidecar = w.md; result.links = w.entities; result.proposals = w.proposals; result.actions = w.actions
        } catch { return fail(result, error) }
        return result
    }

    func fail(_ r: Result, _ error: Error) -> Result {
        var r = r
        r.status = "error"; r.error = error.localizedDescription
        return r
    }

    // MARK: Accept, undo, inbox

    /// Files a document waiting in review, with the corrections given, and learns its issuer.
    public func accept(_ id: String, domain: String? = nil, type: String? = nil, subject: String? = nil) async -> Result {
        guard var r = filing.reviewRecord(id) else { return Result(status: "error", id: id, error: "nothing in review called \(id)") }
        if let domain { r.fields.domain = domain }
        if let type { r.fields.type = type }
        if let subject { r.subject = subject }
        r.reason = nil
        r.confidence = 1
        if r.fields.date == nil { r.fields.date = ScanText.day.string(from: r.scanned) }
        var result = Result(status: "filed", id: id, record: r, model: "off")
        do {
            let pdf = r.inPlace == nil ? try Data(contentsOf: filing.root.appending(path: "\(Filing.app)/review/\(id).pdf")) : nil
            let w = try filing.file(r, pdf: pdf)
            try filing.clearReview(id)
            if !r.fields.issuer.isEmpty {
                try filing.learn(FilingRule(match: r.fields.issuer, issuer: r.fields.issuer, domain: r.fields.domain, type: r.fields.type, subject: r.subject))
            }
            result.path = w.pdf; result.sidecar = w.md; result.links = w.entities; result.proposals = w.proposals; result.actions = w.actions
            var line = result.json
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            line["record"] = (try? JSONSerialization.jsonObject(with: e.encode(r))) ?? NSNull()
            line["source"] = "accept"
            try? filing.log(line)
        } catch { return fail(result, error) }
        return result
    }

    /// Everything in the drop folder, each moved to `inbox/.filed/<date>/` once read (never deleted).
    public func inbox(source: String = "drop") async -> [Result] {
        let fm = FileManager.default
        let dir = filing.root.appending(path: Filing.app + "/inbox")
        let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { ["pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Result] = []
        for item in items {
            // Hints beside it (the phone's upload): <name>.json {source, from, domain, entity, type, device}.
            let hintURL = item.deletingPathExtension().appendingPathExtension("json")
            let hints = (try? JSONSerialization.jsonObject(with: Data(contentsOf: hintURL))) as? [String: String] ?? [:]
            let reviewed = hints["fields"].flatMap { try? JSONDecoder().decode(ScanFields.self, from: Data($0.utf8)) }
            let r = await file(Request(path: item, source: hints["source"] ?? source, from: hints["from"], sender: hints["sender"], domain: hints["domain"],
                                       entity: hints["entity"], type: hints["type"], device: hints["device"] ?? ThisDevice.name, reviewed: reviewed))
            if r.status != "error" {
                let done = dir.appending(path: ".filed/\(ScanText.day.string(from: .now))")
                try? fm.createDirectory(at: done, withIntermediateDirectories: true)
                for f in [item, hintURL] where fm.fileExists(atPath: f.path) {
                    var to = done.appending(path: f.lastPathComponent)
                    if fm.fileExists(atPath: to.path) { to = done.appending(path: "\(r.id) \(f.lastPathComponent)") }
                    try? fm.moveItem(at: f, to: to)
                }
                // The phone asks for its result by name: GET /filing/<stem> reads this.
                if let data = try? JSONSerialization.data(withJSONObject: r.json, options: [.sortedKeys, .withoutEscapingSlashes]) {
                    try? data.write(to: dir.appending(path: ".filed/\(item.deletingPathExtension().lastPathComponent).result.json"))
                }
            }
            out.append(r)
        }
        return out
    }

    // MARK: Backfill

    /// Every PDF already in the vault under `folder` (vault-relative, e.g. data/domains): B0 is a
    /// dry run (a report only); B1 (`inPlace`) writes a note beside each PDF where it is, moving
    /// nothing. Resumable: a PDF that already has its note is skipped.
    public func backfill(_ folder: String, inPlace: Bool, report: String?, limit: Int = .max,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> String {
        let fm = FileManager.default
        let pdfs = Self.pdfs(under: filing.root.appending(path: folder), root: filing.root)
        let domains = filing.domains(), rules = filing.rules()
        var rows: [(rel: String, rec: FilingRecord?, note: String)] = []
        var byHash: [String: [String]] = [:], byText: [String: [String]] = [:]
        let dir = inPlace ? StudioDirectory(root: filing.root) : nil
        var index = inPlace ? filing.index() : []
        for (i, rel) in pdfs.prefix(limit).enumerated() {
            progress?(i + 1, min(limit, pdfs.count))
            let mdRel = String(rel.dropLast(4)) + ".md"
            if inPlace, let n = Filing.note(filing.root.appending(path: mdRel), root: filing.root) { rows.append((rel, nil, "already noted (\(n.id))")); continue }
            if inPlace, fm.fileExists(atPath: filing.root.appending(path: mdRel).path) { rows.append((rel, nil, "skipped: a note of the same name exists")); continue }
            guard let read = try? await read(filing.root.appending(path: rel)) else { rows.append((rel, nil, "unreadable")); continue }
            let model = useModel ? await DocumentReader.modelRead(read.text, parts: 1) : nil
            let parts = rel.split(separator: "/")
            let here = parts.count > 2 && parts[0] == "data" && parts[1] == "domains" ? String(parts[2]) : nil
            var r = decide(read, Request(path: filing.root.appending(path: rel), source: "backfill", device: ThisDevice.name, dryRun: !inPlace),
                           rules: rules, domains: domains, model: model)
            r.sha256 = Filing.sha256((try? Data(contentsOf: filing.root.appending(path: rel))) ?? Data())
            byHash[r.sha256, default: []].append(rel)
            if !r.textSHA256.isEmpty { byText[r.textSHA256, default: []].append(rel) }
            rows.append((rel, r, ""))
            if inPlace, let here {
                var noted = r
                noted.inPlace = rel
                let proposed = noted.fields.domain
                noted.fields.domain = here
                if r.reason != nil {
                    // Under the bar: never a guess. The note says "review" beside the untouched PDF, and the
                    // record waits in review/ (no PDF copy) for Fru's yes; no suggestions, no Expiring lines.
                    try? filing.reviewInPlace(noted, proposedDomain: proposed)
                } else {
                    if proposed != here { noted.reason = "proposed domain \(proposed)" }
                    if (try? filing.file(noted, pdf: nil, directory: dir, expiring: false)) != nil, let n = Filing.note(filing.root.appending(path: mdRel), root: filing.root) { index.append(n) }
                }
            }
        }
        if inPlace { try? filing.writeExpiring() }
        let md = Self.report(rows, byHash: byHash, byText: byText, inPlace: inPlace, total: pdfs.count)
        if let report { try? filing.writeText(report, md) }
        try? filing.log(["status": inPlace ? "backfill-notes" : "backfill-dry-run", "id": "backfill", "folder": folder,
                         "documents": rows.count, "report": report ?? NSNull()])
        return md
    }

    /// Every PDF under a folder, vault-relative, sorted; archives, chats and skills left out.
    static func pdfs(under base: URL, root: URL) -> [String] {
        var out: [String] = []
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in walker {
            let n = u.lastPathComponent
            if n == "_archive" || n.hasPrefix("archived-") || n == "threads" || n == "skills" || n == "node_modules" { walker.skipDescendants(); continue }
            if u.pathExtension.lowercased() == "pdf" { out.append(String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))) }
        }
        return out.sorted()
    }

    static func report(_ rows: [(rel: String, rec: FilingRecord?, note: String)], byHash: [String: [String]], byText: [String: [String]],
                       inPlace: Bool, total: Int) -> String {
        let read = rows.compactMap { r in r.rec.map { (r.rel, $0) } }
        var out = "# Filing backfill \(inPlace ? "B1, notes in place" : "B0, dry run") \(ScanText.day.string(from: .now))\n\n"
        out += "\(rows.count) of \(total) PDFs looked at; \(read.count) read. Nothing was moved or renamed.\n\n"
        let review = read.filter { $0.1.reason != nil }
        out += "Would file \(read.count - review.count), would send to review \(review.count) (\(read.isEmpty ? 0 : review.count * 100 / read.count)%).\n\n"
        out += "## By domain (where it is -> where it would go)\n\n| Now | Proposed | Count |\n|---|---|---|\n"
        var pairs: [String: Int] = [:]
        for (rel, r) in read {
            let p = rel.split(separator: "/")
            pairs["\(p.count > 2 ? String(p[2]) : "?")|\(r.fields.domain)", default: 0] += 1
        }
        for (k, n) in pairs.sorted(by: { $0.value > $1.value }) { let ab = k.split(separator: "|"); out += "| \(ab[0]) | \(ab[1]) | \(n) |\n" }
        let dupes = (Array(byHash.values) + Array(byText.values)).filter { $0.count > 1 }.map { Array(Set($0)).sorted() }
        let groups = Array(Set(dupes.map { $0.joined(separator: "\n") })).sorted()
        out += "\n## Duplicate groups (\(groups.count))\n\n"
        for g in groups { out += g.split(separator: "\n").map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        out += "## Low confidence or review (\(review.count))\n\n"
        for (rel, r) in review { out += "- \(rel): \(r.reason ?? "") -> \(r.fields.type), \(r.fields.domain)\n" }
        out += "\n## Every document\n\n| Now | Proposed name | Type | Domain | Date | Confidence |\n|---|---|---|---|---|---|\n"
        for (rel, r) in read {
            out += "| \(rel) | \(Filing.cut(r.fields.name)) | \(r.fields.type) | \(r.fields.domain) | \(r.fields.date ?? "") | \(String(format: "%.2f", r.confidence)) |\n"
        }
        for row in rows where row.rec == nil { out += "| \(row.rel) | \(row.note) | | | | |\n" }
        return Filing.cut(out)
    }
}
