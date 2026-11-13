import CoreGraphics
import CoreText
import Foundation
import FoundationModels
import GlyphVault
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads a document: the words of a PDF (PDFKit), or Vision's OCR of a scan or photo, a compact
/// searchable PDF with the OCR as an invisible text layer, and what Apple's on-device model can add
/// (type, issuer, people, which date is which, a summary). Every answer from the model must be found
/// in the text or it is dropped; dates, money and numbers come from `ScanText`, never the model.
public enum DocumentReader {
    /// One line of recognized text and where it sits on the page (0...1, origin bottom left).
    public struct Line: Sendable, Equatable {
        public var text: String
        public var box: CGRect
        public init(text: String, box: CGRect) { self.text = text; self.box = box }
    }

    // MARK: Text

    /// Each page's own text.
    public static func pageTexts(_ pdf: PDFDocument) -> [String] {
        (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
    }

    /// Thin: less than 40 characters a page, so it is a scan that needs OCR.
    public static func isThin(_ pages: [String]) -> Bool {
        pages.isEmpty || pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count }.reduce(0, +) < 40 * pages.count
    }

    /// Vision text recognition, accurate, top to bottom.
    public static func ocr(_ image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let found = try await request.perform(on: image)
        return found.compactMap { o in
            o.topCandidates(1).first.map { Line(text: $0.string, box: o.boundingBox.cgRect) }
        }.sorted { ($0.box.maxY, -$0.box.minX) > ($1.box.maxY, -$1.box.minX) }
    }

    public static func text(_ lines: [Line]) -> String { lines.map(\.text).joined(separator: "\n") }

    /// A PDF page drawn as an image about `longSide` pixels on its long side, white behind it.
    public static func render(_ page: PDFPage, longSide: CGFloat = 2_000) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = longSide / max(box.width, box.height)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        if let ref = page.pageRef { ctx.drawPDFPage(ref) }
        return ctx.makeImage()
    }

    /// Images from a file: every frame of a JPEG, PNG, HEIC or TIFF.
    public static func images(_ data: Data) -> [CGImage] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            // Upright, whatever way the camera held it.
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 4_000]
            return CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary)
        }
    }

    // MARK: A searchable PDF

    /// The image made small: at most `longSide` pixels, JPEG at `quality`. About 150 to 250 KB a page.
    public static func jpeg(_ image: CGImage, longSide: Int = 1_700, quality: Double = 0.55) -> Data? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// One PDF from page images, each with its OCR words as invisible text (selectable, searchable in
    /// Spotlight and Finder). Pages are US Letter wide; the JPEG is kept as is inside the PDF.
    public static func pdf(pages: [(image: CGImage, lines: [Line])]) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for page in pages {
            guard let data = jpeg(page.image), let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            var box = CGRect(x: 0, y: 0, width: 612, height: 612 * CGFloat(img.height) / CGFloat(img.width))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(img, in: box)
            drawInvisible(page.lines, in: box, ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return pages.isEmpty ? nil : out as Data
    }

    /// The same PDF with an invisible text layer over each page (a scan with no words of its own).
    /// The pages themselves are drawn as they were.
    public static func addingText(to pdf: PDFDocument, lines: [[Line]]) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i), let ref = page.pageRef else { continue }
            var box = page.bounds(for: .mediaBox)
            ctx.beginPage(mediaBox: &box)
            ctx.drawPDFPage(ref)
            if i < lines.count { drawInvisible(lines[i], in: box, ctx) }
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }

    static func drawInvisible(_ lines: [Line], in box: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let r = CGRect(x: box.minX + line.box.minX * box.width, y: box.minY + line.box.minY * box.height,
                           width: line.box.width * box.width, height: line.box.height * box.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(2, r.height * 0.8), nil)
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font]))
            let width = CTLineGetTypographicBounds(ct, nil, nil, nil)
            ctx.textMatrix = CGAffineTransform(scaleX: width > 0 ? r.width / width : 1, y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.15)
            CTLineDraw(ct, ctx)
        }
        ctx.restoreGState()
    }

    // MARK: The on-device model

    public static var modelAvailable: Bool { OnDeviceModel.status == .available }

    @Generable
    struct Guess {
        @Guide(description: "What kind of document this is", .anyOf(["Receipt", "Invoice", "Bill", "Statement", "Lease", "Insurance Policy", "Tax Form",
                                                                      "Medical Record", "Lab Result", "Warranty", "ID Card", "Letter", "Contract", "Document"]))
        var type: String
        @Guide(description: "The company, agency or person who issued or sent it, exactly as written in the text. Empty if unclear.")
        var issuer: String
        @Guide(description: "Full names of people named in it, exactly as written. Empty when none.", .maximumCount(6))
        var people: [String]
        @Guide(description: "The property, address, vehicle or thing it is about, exactly as written. Empty when none.", .maximumCount(3))
        var about: [String]
        @Guide(description: "The date the document was issued, as YYYY-MM-DD, only if the text states it")
        var documentDate: String?
        @Guide(description: "The date a payment or action is due, as YYYY-MM-DD, only if the text states it")
        var dueDate: String?
        @Guide(description: "The date it expires or coverage ends, as YYYY-MM-DD, only if the text states it")
        var expiryDate: String?
        @Guide(description: "The date it renews, as YYYY-MM-DD, only if the text states it")
        var renewalDate: String?
        @Guide(description: "The one amount that matters most (amount due, else the total, net owner funds, premium or rent), copied exactly as printed, e.g. $1,234.56. Empty when none.")
        var mainAmount: String
        @Guide(description: "What that amount is, in two or three words, e.g. Amount due, Total, Net owner funds, Premium. Empty when none.")
        var mainAmountLabel: String
        @Guide(description: "Two short plain sentences saying what this document is and what it asks for. No account numbers.")
        var summary: String
    }

    /// What the model read, already checked against the text.
    public struct ModelFields: Sendable, Equatable {
        public var type: String?
        public var issuer: String?
        public var people: [String] = []
        public var about: [String] = []
        public var date: String?
        public var due: String?
        public var expires: String?
        public var renews: String?
        public var summary: String?
        /// The amount that matters most, exactly as printed and found in the text, with what it is.
        public var mainAmount: String?
        public var mainAmountLabel: String?
        public init() {}
    }

    static let instructions = """
        You read one document a person scanned or downloaded and fill in its fields. Use only what the \
        text says. Copy names exactly as written. Leave a field empty rather than guess. Never do math.
        """

    /// The model over the masked text in parts of about 6,000 characters (its window is 4,096 tokens,
    /// shared with the answer); the first part decides the type and issuer, the others add people,
    /// places and dates. Nil when the model can't run.
    public static func modelRead(_ text: String, parts maxParts: Int = 1) async -> ModelFields? {
        guard modelAvailable else { return nil }
        let masked = ScanText.masked(text)
        var guesses: [ModelFields] = []
        for part in Summarizer.parts(masked, max: 6_000).prefix(maxParts) {
            if let g = await guess(part) {
                var m = ModelFields()
                m.type = g.type; m.issuer = g.issuer; m.people = g.people; m.about = g.about; m.date = g.documentDate
                m.due = g.dueDate; m.expires = g.expiryDate; m.renews = g.renewalDate; m.summary = g.summary
                m.mainAmount = g.mainAmount; m.mainAmountLabel = g.mainAmountLabel
                guesses.append(m)
            }
        }
        guard !guesses.isEmpty else { return nil }
        return ground(guesses, in: text)
    }

    static func guess(_ part: String) async -> Guess? {
        let prompt = "DOCUMENT TEXT:\n\(part)"
        for _ in 0..<2 {
            do {
                return try await LanguageModelSession(instructions: instructions)
                    .respond(to: prompt, generating: Guess.self, options: GenerationOptions(temperature: 0)).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                return part.count > 1_500 ? await guess(String(part.prefix(part.count / 2))) : nil
            } catch {
                continue  // decoding failures and guardrails come and go; one more try
            }
        }
        return nil
    }

    /// Keeps only what the text backs: names found in it, dates among the dates in it.
    /// `guesses` are the model's raw answers, one per part, the first part first.
    public static func ground(_ guesses: [ModelFields], in text: String) -> ModelFields {
        let hay = squash(text)
        let days = Set(ScanText.allDays(in: text))
        func found(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count >= 2 && hay.contains(squash(t)) ? t : nil
        }
        func day(_ s: String?) -> String? { s.flatMap { days.contains($0) ? $0 : nil } }
        // A due, expiry or renewal date must be named so just before it on the page, not only be on it.
        func named(_ s: String?, _ kind: String) -> String? { day(s).flatMap { ScanText.dateIsLabelled($0, as: kind, in: text) ? $0 : nil } }
        var m = ModelFields()
        let first = guesses[0]
        m.type = first.type == "Document" || !ScanText.types.contains(where: { $0.name == first.type }) ? nil : first.type
        m.issuer = first.issuer.flatMap(found)
        for g in guesses {
            for p in g.people.compactMap(found) where !m.people.contains(p) { m.people.append(p) }
            for a in g.about.compactMap(found) where !m.about.contains(a) { m.about.append(a) }
            m.date = m.date ?? day(g.date)
            m.due = m.due ?? named(g.due, "due")
            m.expires = m.expires ?? named(g.expires, "expires")
            m.renews = m.renews ?? named(g.renews, "renews")
        }
        // The amount as printed, found in the text as is (never computed); its label kept short.
        if let a = first.mainAmount?.trimmingCharacters(in: .whitespaces), a.contains(where: \.isNumber), text.contains(a),
           ScanText.amounts(in: a.contains("$") || a.contains(".") ? a : "$" + a).first != nil {
            m.mainAmount = a
            m.mainAmountLabel = first.mainAmountLabel.map { String($0.trimmingCharacters(in: .whitespaces).prefix(30)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Amount"
        }
        let s = (first.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        m.summary = s.isEmpty ? nil : Filing.cut(s)
        return m
    }

    static func squash(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}
