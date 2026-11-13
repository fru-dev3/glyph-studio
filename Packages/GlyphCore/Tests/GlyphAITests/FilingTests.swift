import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import GlyphAI
@testable import GlyphVault

/// The filing pipeline over a made-up vault and made-up documents, drawn here (no real document
/// ever enters the repo). The model is off, so every answer is the rules' and the word lists'.
@Suite(.serialized) struct FilingTests {
    /// Dated today, due in 30 days, so the Expiring list (the next 12 months) always shows it.
    static func day(_ days: Double, _ format: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
        return f.string(from: Date().addingTimeInterval(days * 86_400))
    }
    static let issued = day(0, "yyyy-MM-dd"), due = day(30, "yyyy-MM-dd")
    static let bill = ["Globex Utilities", "Statement Date: \(day(0, "MMMM d, yyyy"))", "Account Number 4400 1200 9876",
                       "Service period 08/25/2026 - 09/24/2026", "Amount Due $87.40", "Please pay by \(day(30, "MMMM d, yyyy"))"]
    static let policy = ["Acme Insurance", "Homeowners Policy Declarations", "Named Insured: Ken Lee", "Policy Number: HO-55-7781-4821",
                         "Policy Period: 10/01/2026 to 10/01/2027", "Annual Premium: $1,234.00"]
    static let lab = ["Lakeside Lab", "Lab Report", "Patient: Ken Lee", "Collected 10/20/2026", "Specimen: blood", "Glucose 92 mg/dL reference range 70-99"]

    /// A fresh vault: a few domains, one Product page, an empty records board.
    static func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "filing-\(UUID().uuidString)")
        for d in ["insurance", "real-estate", "records", "tax", "health", "notes"] {
            try FileManager.default.createDirectory(at: root.appending(path: "data/domains/\(d)/source/files"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "data/domains/\(d)/memory"), withIntermediateDirectories: true)
        }
        let org = root.appending(path: "data/entities/orgs/globex-utilities")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try "---\nname: \"Globex Utilities\"\nkind: org\naliases: []\nid: org/globex-utilities\n---\n".write(to: org.appending(path: "entity.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// A text PDF of these lines (a real text layer, as a portal download has).
    static func textPDF(_ lines: [String], size: CGFloat = 13) -> Data {
        let out = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: nil, nil)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        ctx.beginPage(mediaBox: &box)
        draw(lines, ctx, height: 792, size: size)
        ctx.endPage(); ctx.closePDF()
        return out as Data
    }

    /// The same lines as a photo: pixels only, no text.
    static func image(_ lines: [String]) -> CGImage {
        let ctx = CGContext(data: nil, width: 1275, height: 1650, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1275, height: 1650))
        ctx.scaleBy(x: 1275 / 612, y: 1650 / 792)
        draw(lines, ctx, height: 792, size: 14)
        return ctx.makeImage()!
    }

    static func imagePDF(_ lines: [String]) -> Data {
        let out = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: nil, nil)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        ctx.beginPage(mediaBox: &box); ctx.draw(image(lines), in: box); ctx.endPage(); ctx.closePDF()
        return out as Data
    }

    static func draw(_ lines: [String], _ ctx: CGContext, height: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        for (i, l) in lines.enumerated() {
            ctx.textPosition = CGPoint(x: 60, y: height - 80 - CGFloat(i) * size * 2)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [.init(kCTFontAttributeName as String): font])), ctx)
        }
    }

    static func put(_ data: Data, _ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "in-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    static func read(_ root: URL, _ rel: String) -> String { (try? String(contentsOf: root.appending(path: rel), encoding: .utf8)) ?? "" }

    /// Every file and its bytes, to prove a dry run wrote nothing.
    static func snapshot(_ root: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where !u.hasDirectoryPath {
            out[u.path] = try? Data(contentsOf: u)
        }
        return out
    }

    // MARK: PDF

    @Test func searchablePDFFromAPhoto() async throws {
        let img = Self.image(Self.bill)
        let lines = try await DocumentReader.ocr(img)
        #expect(DocumentReader.text(lines).contains("Globex Utilities"))
        let pdf = try #require(DocumentReader.pdf(pages: [(img, lines), (img, lines)]))
        let doc = try #require(PDFDocument(data: pdf))
        #expect(doc.pageCount == 2)
        #expect((doc.page(at: 0)?.string ?? "").contains("Amount Due"), "no text layer")
        #expect(pdf.count < 2 * 300_000, "\(pdf.count) bytes for two pages")
    }

    @Test func scanGetsATextLayerWhenFiled() async throws {
        let root = try Self.vault()
        let r = await Filer(vault: root, useModel: false).file(.init(path: try Self.put(Self.imagePDF(Self.bill), "scan.pdf"), source: "jot"))
        #expect(r.status == "filed", "\(r.json)")
        let doc = try #require(PDFDocument(url: root.appending(path: r.path!)))
        #expect((doc.string ?? "").contains("Globex"))
    }

    // MARK: Filing

    @Test func billIsFiledLinkedAndTasked() async throws {
        let root = try Self.vault()
        let filer = Filer(vault: root, useModel: false)
        let input = try Self.put(Self.textPDF(Self.bill), "download.pdf")
        let r = await filer.file(.init(path: input, source: "email", from: "email, billing@globex.example", sender: "billing@globex.example"))
        #expect(r.status == "filed" && r.exitCode == 0, "\(r.json)")
        #expect(r.path == "data/domains/records/source/files/\(Self.issued) Globex Utilities Bill.pdf")
        let note = Self.read(root, r.sidecar!)
        #expect(note.contains("entities: [\"org/globex-utilities\"]") && note.contains("due: \(Self.due)") && note.contains("status: filed"))
        #expect(note.contains("source: email") && note.contains("sha256: \"") && note.contains("## Actions taken"))
        let tasks = Self.read(root, "data/domains/records/memory/tasks.md")
        #expect(tasks.contains("- [ ] Pay Globex Utilities $87.40 bill @\(Self.due) ~src:filing:\(r.id)"), "\(tasks)")
        #expect(Self.read(root, "data/domains/records/memory/expiring.md").contains("\(Self.due) due"))
        #expect(FileManager.default.fileExists(atPath: input.path), "the input is copied, never moved")
        // Again: a duplicate, nothing added.
        let again = await filer.file(.init(path: input, source: "email"))
        #expect(again.status == "duplicate" && again.duplicateOf == r.path)
        #expect(Self.read(root, "data/domains/records/memory/tasks.md") == tasks)
        // The same letter rendered another way: the same words, still a duplicate.
        let rerender = await filer.file(.init(path: try Self.put(Self.textPDF(Self.bill, size: 11), "other.pdf")))
        #expect(rerender.status == "duplicate", "\(rerender.json)")
    }

    @Test func rulesSubjectEntityAndOtherDomains() async throws {
        let root = try Self.vault()
        try Filing(root: root).learn(FilingRule(match: "acme insurance", issuer: "Acme Insurance", domain: "insurance", subject: "maple",
                                                entity: "place/maple-st", also: ["real-estate"]))
        let r = await Filer(vault: root, useModel: false).file(.init(path: try Self.put(Self.textPDF(Self.policy), "p.pdf")))
        #expect(r.status == "filed", "\(r.json)")
        #expect(r.path == "data/domains/insurance/source/files/maple/2026-10-01 Acme Insurance Insurance Policy.pdf")
        #expect(r.links.contains("place/maple-st"))
        #expect(r.record?.fields.expires == "2027-10-01")
        let keys = Self.read(root, "data/domains/insurance/memory/key-dates.md")
        #expect(keys.contains("- 2027-10-01: Acme Insurance insurance policy expires (filing \(r.id))"), "\(keys)")
        let updates = Self.read(root, "data/domains/real-estate/memory/updates.jsonl")
        #expect(updates.contains("\"thread\":\"filing:\(r.id)\"") && updates.contains("\"from_domain\":\"insurance\""))
        // Undo takes out exactly its lines and moves the files to review.
        #expect(try Filing(root: root).undo(r.id))
        #expect(!Self.read(root, "data/domains/insurance/memory/key-dates.md").contains(r.id))
        #expect(!Self.read(root, "data/domains/real-estate/memory/updates.jsonl").contains(r.id))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: r.path!).path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "data/apps/filing/review/\(r.id).pdf").path))
    }

    @Test func unclearGoesToReviewThenAcceptLearns() async throws {
        let root = try Self.vault()
        let filer = Filer(vault: root, useModel: false)
        let r = await filer.file(.init(path: try Self.put(Self.textPDF(["Northwind Garden Club", "Thanks for helping at the spring sale.", "See you soon"]), "n.pdf")))
        #expect(r.status == "review" && r.exitCode == 2, "\(r.json)")
        #expect(r.reviewReason?.contains("no document date") == true)
        #expect(Self.read(root, "data/domains/records/memory/tasks.md").contains("- [ ] Review 1 document waiting to be filed ~src:filing:review"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "data/domains/records/source/files").appending(path: "Document.pdf").path))
        let ok = await filer.accept(r.id, domain: "records", type: "Letter")
        #expect(ok.status == "filed", "\(ok.json)")
        #expect(ok.path?.hasPrefix("data/domains/records/source/files/") == true && ok.path?.hasSuffix("Northwind Garden Club Letter.pdf") == true)
        #expect(!Self.read(root, "data/domains/records/memory/tasks.md").contains("~src:filing:review"))
        #expect(Filing(root: root).rules().rules.contains { $0.match == "Northwind Garden Club" && $0.domain == "records" })
    }

    @Test func labGoesToHealth() async throws {
        let root = try Self.vault()
        let r = await Filer(vault: root, useModel: false).file(.init(path: try Self.put(Self.textPDF(Self.lab), "lab.pdf"), source: "well"))
        #expect(r.status == "filed" && r.record?.fields.domain == "health" && r.record?.fields.type == "Lab Result", "\(r.json)")
    }

    @Test func dryRunWritesNothing() async throws {
        let root = try Self.vault()
        let before = Self.snapshot(root)
        let filer = Filer(vault: root, useModel: false)
        let r = await filer.file(.init(path: try Self.put(Self.textPDF(Self.bill), "b.pdf"), dryRun: true))
        #expect(r.status == "filed" && r.dryRun && r.path == "data/domains/records/source/files/\(Self.issued) Globex Utilities Bill.pdf")
        let unclear = await filer.file(.init(path: try Self.put(Self.textPDF(["Hello there"]), "h.pdf"), dryRun: true))
        #expect(unclear.status == "review")
        #expect(Self.snapshot(root) == before)
    }

    @Test func longNumbersNeverLeaveThePDF() async throws {
        let root = try Self.vault()
        let filer = Filer(vault: root, useModel: false)
        let r = await filer.file(.init(path: try Self.put(Self.textPDF(Self.bill + ["Member ID 123456789", "Card 4111 1111 1111 1111"]), "m.pdf"),
                                       from: "email, ref 987654321000"))
        #expect(r.status == "filed")
        let digits = try NSRegularExpression(pattern: #"\d(?:[ -]?\d){8,}"#)
        for rel in [r.sidecar!, "data/domains/records/memory/tasks.md", "data/domains/records/memory/expiring.md"] + (try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "data/apps/filing/log").path)).map({ "data/apps/filing/log/" + $0 }) {
            let t = Self.read(root, rel).replacingOccurrences(of: #"[0-9a-f]{64}"#, with: "", options: .regularExpression)  // hashes are not ids
            #expect(digits.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) == nil, "\(rel) holds a long number")
        }
        #expect(!r.path!.contains("123456789"))
    }

    @Test func modelAnswersMustBeInTheText() {
        var g = DocumentReader.ModelFields()
        g.type = "Bill"; g.issuer = "Initech"; g.people = ["Ken Lee", "Pat Doe"]; g.due = Self.due; g.expires = "2030-01-01"; g.summary = "A bill."
        let m = DocumentReader.ground([g], in: Self.bill.joined(separator: "\n") + "\nFor Ken   Lee")
        #expect(m.type == "Bill" && m.issuer == nil && m.people == ["Ken Lee"] && m.due == Self.due && m.expires == nil)
    }

    @Test func backfillDryRunReportsAndInPlaceNotes() async throws {
        let root = try Self.vault()
        try Self.textPDF(Self.bill).write(to: root.appending(path: "data/domains/records/source/files/old bill.pdf"))
        try Self.textPDF(Self.bill).write(to: root.appending(path: "data/domains/tax/source/files/copy of bill.pdf"))
        let filer = Filer(vault: root, useModel: false)
        let before = Self.snapshot(root)
        let md = await filer.backfill("data/domains", inPlace: false, report: nil)
        #expect(md.contains("2 of 2 PDFs") && md.contains("Duplicate groups (1)") && md.contains("Globex Utilities Bill"), "\(md)")
        // B0 writes its log line only.
        #expect(Set(Self.snapshot(root).keys.filter { !$0.contains("/data/apps/filing/log/") }) == Set(before.keys))
        // B1: a note beside each PDF where it is; nothing moved or renamed.
        _ = await filer.backfill("data/domains", inPlace: true, report: "data/apps/filing/backfill-test.md")
        let note = Self.read(root, "data/domains/records/source/files/old bill.md")
        #expect(note.contains("kind: scan") && note.contains("file: \"old bill.pdf\"") && note.contains("source: backfill") && note.contains("domain: records"), "\(note)")
        #expect(Self.read(root, "data/domains/tax/source/files/copy of bill.md").contains("domain: tax"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "data/domains/records/source/files/old bill.pdf").path))
        #expect(Self.read(root, "data/domains/records/memory/expiring.md").contains("old bill.md"))
        // Under the bar: a review note in place, the record in review/, the PDF untouched; Accept files it there.
        try Self.textPDF(["Hello there", "nothing much here"]).write(to: root.appending(path: "data/domains/records/source/files/unclear.pdf"))
        _ = await filer.backfill("data/domains", inPlace: true, report: nil)
        let unclear = Self.read(root, "data/domains/records/source/files/unclear.md")
        #expect(unclear.contains("status: review") && unclear.contains("proposed_path:"), "\(unclear)")
        #expect(!Self.read(root, "data/domains/records/memory/expiring.md").contains("unclear"))
        let id = try #require(Filing(root: root).reviewIDs().first)
        #expect(Self.read(root, "data/domains/records/memory/tasks.md").contains("Review 1 document waiting"))
        let ok = await filer.accept(id, type: "Letter")
        #expect(ok.status == "filed" && ok.path == "data/domains/records/source/files/unclear.pdf", "\(ok.json)")
        #expect(Self.read(root, "data/domains/records/source/files/unclear.md").contains("status: filed"))
        // Resumable: a second run skips both.
        let again = await filer.backfill("data/domains", inPlace: true, report: nil)
        #expect(again.contains("0 read"), "\(again)")  // the reviewed one counts as noted too
    }
    /// One row per obligation, not one per copy. One real vault had the same policy under four domains
    /// and in four renders, so 38 lines were 12 obligations; sha256 alone would still have shown 18.
    @Test func expiringShowsOneRowPerObligationAndKeepsTheSourceCopy() {
        func note(_ md: String, sha: String, issuer: String = "Acme Insurance", last4: [String] = ["4821"]) -> FiledNote {
            FiledNote(md: md, id: String(sha.prefix(8)), sha256: sha, textSHA256: "t-" + sha, title: "2026-10-01 \(issuer) Insurance Policy",
                      issuer: issuer, type: "Insurance Policy", date: "2026-10-01", last4: last4,
                      deadlines: [(kind: "expires", date: "2027-10-01")], status: "filed")
        }
        // Four copies of one policy: two domains times two renders of the same paper.
        let copies = [note("data/domains/insurance/memory/current/a/policy.md", sha: "a1"),
                      note("data/domains/insurance/source/files/policy.md", sha: "a2"),
                      note("data/domains/real-estate/memory/current/x/y/policy.md", sha: "a3"),
                      note("data/domains/real-estate/source/files/policy.md", sha: "a4")]
        // A different policy from a different issuer, same expiry day: a second real obligation.
        let other = note("data/domains/insurance/source/files/other.md", sha: "b1", issuer: "Globex Insurance", last4: ["7781"])
        let rows = (copies + [other]).flatMap { n in n.deadlines.map { (n, $0) } }
        let out = Filing.oneRowPerObligation(rows)
        #expect(out.count == 2)
        #expect(Set(out.map(\.note.issuer)) == ["Acme Insurance", "Globex Insurance"])
        // The copy kept is under source/, and the shortest such path, never a memory/current one.
        let acme = out.first { $0.note.issuer == "Acme Insurance" }!
        #expect(acme.note.md == "data/domains/insurance/source/files/policy.md")
        // The suppressed copies are counted, so a reader can say a copy was collapsed.
        #expect(acme.copies == 4)
        #expect(out.first { $0.note.issuer == "Globex Insurance" }!.copies == 1)
        // Same input in any order gives the same answer (two machines, one list).
        #expect(Filing.oneRowPerObligation(rows.reversed()).map(\.note.md) == out.map(\.note.md))
    }

    /// A lapsed obligation is only a gap when nothing newer of the same kind was filed after it.
    @Test func lapsedReportsOnlyWhatHasNoReplacement() throws {
        let root = try Self.vault()
        let filing = Filing(root: root)
        // Three policies: one expired with a replacement on file, one expired with nothing after it,
        // and one that expired long ago (history, not a gap).
        func put(_ name: String, issuer: String, docDate: String, expires: String) throws {
            let md = """
                ---
                title: "\(docDate) \(issuer) Insurance Policy"
                kind: scan
                type: "Insurance Policy"
                issuer: "\(issuer)"
                date: \(docDate)
                deadlines: [{"date":"\(expires)","kind":"expires"}]
                references: []
                status: filed
                ---

                """
            try md.write(to: root.appending(path: "data/domains/insurance/source/files/\(name).md"), atomically: true, encoding: .utf8)
        }
        try put("acme-old", issuer: "Acme Insurance", docDate: "2024-01-01", expires: Self.day(-400, "yyyy-MM-dd"))
        try put("acme-new", issuer: "Acme Insurance", docDate: "2025-06-01", expires: Self.day(200, "yyyy-MM-dd"))
        try put("globex", issuer: "Globex Insurance", docDate: "2025-02-01", expires: Self.day(-40, "yyyy-MM-dd"))
        try put("ancient", issuer: "Initech Insurance", docDate: "2009-01-01", expires: "2010-01-01")

        let gaps = filing.lapsed()
        // Only Globex: Acme's expiry was replaced by a newer Acme policy, and Initech is history.
        #expect(gaps.map(\.note.issuer) == ["Globex Insurance"])
        // And it is not in the forward list, which is the whole reason this call exists.
        #expect(!filing.expiring().contains { $0.note.issuer == "Globex Insurance" })
    }

}
