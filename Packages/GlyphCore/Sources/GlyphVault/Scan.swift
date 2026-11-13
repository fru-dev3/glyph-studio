import Foundation

/// A scanned document's facts: what Glyph Jot shows on the review card, names the PDF by and
/// writes into the sidecar note beside it in the vault. Everything here is plain Swift so it is the
/// same on every device and testable without a model: dates and money are found by code
/// (NSDataDetector, a money pattern), never by the on-device model, which only labels (GlyphAI's
/// `DocumentReader` fills type, issuer, people and summary when Apple Intelligence is on).
///
/// Account, policy and other reference numbers are kept only as their last four characters: the
/// full number lives inside the PDF, never in the note.
public struct ScanFields: Codable, Equatable, Sendable {
    public var type: String
    /// Who sent or issued it (an Org in Glyph CRM): "Northwind Mutual".
    public var issuer: String
    /// People named on it, by name.
    public var people: [String]
    /// The property, place or thing it concerns: "12 Elm Street", "Blue pickup".
    public var about: [String]
    /// YYYY-MM-DD: the document's own date (issued, statement, invoice); the scan date when none.
    public var date: String?
    public var due: String?
    public var expires: String?
    public var renews: String?
    /// "YYYY-MM-DD to YYYY-MM-DD": a service, billing or coverage period.
    public var period: String?
    public var amounts: [ScanAmount]
    public var references: [ScanReference]
    public var summary: String
    /// The vault domain it is filed in (tax, insurance, real-estate...).
    public var domain: String
    /// A name said by voice; otherwise the name is made from date, issuer and type.
    public var customName: String?

    public init(type: String = "Document", issuer: String = "", people: [String] = [], about: [String] = [], date: String? = nil,
                due: String? = nil, expires: String? = nil, renews: String? = nil, period: String? = nil,
                amounts: [ScanAmount] = [], references: [ScanReference] = [], summary: String = "", domain: String = "records",
                customName: String? = nil) {
        self.type = type; self.issuer = issuer; self.people = people; self.about = about; self.date = date
        self.due = due; self.expires = expires; self.renews = renews; self.period = period
        self.amounts = amounts; self.references = references; self.summary = summary; self.domain = domain
        self.customName = customName
    }
}

public struct ScanAmount: Codable, Equatable, Sendable {
    public var label: String
    /// Digits and a dot, "1234.56": exact, never a float.
    public var value: String
    public var currency: String
    public init(label: String, value: String, currency: String = "USD") { self.label = label; self.value = value; self.currency = currency }
    public var decimal: Decimal { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    /// "$1,234.56"
    public var display: String { decimal.formatted(.currency(code: currency).locale(Locale(identifier: "en_US"))) }
}

public struct ScanReference: Codable, Equatable, Sendable {
    public var label: String
    public var last4: String
    public init(label: String, last4: String) { self.label = label; self.last4 = last4 }
    /// "Policy ending 4821"
    public var display: String { "\(label) ending \(last4)" }
}

// MARK: - Reading the words (no model)

public enum ScanText {
    /// The kinds of document, each with the words that give it away and the domain it goes to.
    public static let types: [(name: String, words: [String], domain: String)] = [
        ("Tax Form", ["form 1099", "1099-", "form w-2", "w-2 wage", "form 1098", "internal revenue service", "tax year", "schedule k-1", "property tax statement"], "tax"),
        ("Insurance Policy", ["policy number", "declarations", "policy period", "named insured", "coverage", "premium", "insured"], "insurance"),
        ("Lease", ["lease agreement", "residential lease", "tenant", "landlord", "lease term", "security deposit"], "real-estate"),
        ("Lab Result", ["reference range", "specimen", "collected", "lab report", "laboratory", "result flag"], "health"),
        ("Medical Record", ["patient", "diagnosis", "visit summary", "physician", "clinic", "prescription", "provider"], "health"),
        ("Statement", ["statement period", "beginning balance", "ending balance", "account statement", "statement date", "owner statement",
                       "ending cash balance", "owner disbursements", "estatement"], "wealth"),
        ("Invoice", ["invoice", "bill to", "billed to", "invoice number", "invoice date", "remit payment to"], "records"),
        ("Bill", ["amount due", "payment due", "please pay", "due date", "service period", "pay by"], "records"),
        ("Receipt", ["receipt", "subtotal", "change due", "cashier", "thank you for your purchase", "visa ending", "card ending"], "records"),
        ("Warranty", ["warranty", "warranted", "limited warranty"], "records"),
        ("ID Card", ["driver license", "driver's license", "identification card", "passport", "date of birth", "member id card"], "records"),
        ("Contract", ["agreement", "contract", "the parties", "hereby", "signature"], "records"),
        ("Letter", ["dear ", "sincerely", "regards", "this notice", "if you have any questions"], "records"),
    ]

    /// Words that send a document to a domain whatever its type: a receipt for a rental's furnace is real estate.
    static let domainWords: [(domain: String, words: [String])] = [
        ("tax", ["internal revenue service", "irs", "form 1099", "form w-2", "form 1098", "tax return", "department of revenue"]),
        ("real-estate", ["tenant", "landlord", "lease", "mortgage", "escrow", "hoa", "homeowners association", "rental property", "property management"]),
        ("insurance", ["policy number", "premium", "coverage", "claim number", "insured", "deductible"]),
        ("health", ["patient", "diagnosis", "clinic", "hospital", "pharmacy", "lab", "specimen", "physician", "vaccination", "immunization", "vaccine", "diet", "dietitian"]),
        ("wealth", ["brokerage", "401(k)", "ira", "dividend", "portfolio", "shares", "investment", "net worth", "assets", "liabilities", "savings account"]),
        ("records", ["passport", "driver license", "driver's license", "identification card", "uscis", "homeland security", "permit", "birth certificate",
                     "social security administration", "annual pass", "license number"]),
        ("career", ["employer", "payroll", "pay stub", "expense report", "offer letter", "employee id"]),
        ("benefits", ["benefits enrollment", "hsa", "fsa", "open enrollment"]),
        ("estate", ["will and testament", "trust agreement", "beneficiary", "power of attorney"]),
    ]

    /// Whether `text` (lower case) says `word` with no letter touching either end: "lease" is not in
    /// "please", "ira" not in "irate". A word ending in a space or a dash ("dear ", "1099-") ends there.
    static func says(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let w = NSRegularExpression.escapedPattern(for: word)
        let tail = word.last!.isLetter ? "(?![a-z])" : ""
        return text.range(of: "(?<![a-z])" + w + tail, options: .regularExpression) != nil
    }

    /// The type a document's own heading says: "Billing Invoice", "Owner Statement", "Declarations".
    public static func titleType(_ text: String) -> String? {
        let heads = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 60 }.prefix(10)
        let titles: [(String, (String) -> Bool)] = [
            ("Invoice", { $0.hasSuffix("invoice") || $0.hasPrefix("invoice") && !$0.contains("date") || ["billed to", "bill to", "remit payment to"].contains($0) }),
            ("Document", { ["application", "brochure", "guide", "handbook", "instructions", "checklist", "worksheet"].contains(where: $0.hasSuffix) }),
            ("Receipt", { $0.hasSuffix("receipt") || $0.hasPrefix("receipt") }),
            ("Insurance Policy", { ["declarations", "evidence of coverage", "certificate of insurance", "insurance quote", "policy declarations"].contains(where: $0.contains) }),
            ("Statement", { $0.hasSuffix("statement") && !$0.contains("tax statement") || $0.hasSuffix("estatement") }),
            ("Lease", { $0.contains("lease agreement") || $0.contains("residential lease") }),
            ("Lab Result", { $0.contains("lab report") || $0.contains("laboratory report") || $0.contains("test results") }),
            ("Tax Form", { $0.range(of: #"^form (w-2|1099|1098|1040|1065|k-1)"#, options: .regularExpression) != nil }),
            ("Warranty", { $0.contains("warranty") }),
            ("Contract", { $0.hasSuffix("agreement") || $0.hasSuffix("contract") || $0.hasSuffix("authorization") }),
        ]
        for line in heads { if let t = titles.first(where: { $0.1(line) }) { return t.0 } }
        return nil
    }

    /// How many of each type's words the text has, best first (ties keep the list's order); the
    /// document's own heading counts three.
    public static func typeScores(_ text: String) -> [(name: String, score: Int)] {
        let t = text.lowercased()
        let title = titleType(text)
        return types.map { (name: $0.name, score: $0.words.filter { says(t, $0) }.count + ($0.name == title ? 3 : 0)) }
            .enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
    }

    /// How many strong words point to each domain, most first; only domains with some.
    public static func domainScores(_ text: String) -> [(domain: String, score: Int)] {
        let t = text.lowercased()
        return domainWords.map { (domain: $0.domain, score: $0.words.filter { says(t, $0) }.count) }.filter { $0.score > 0 }.sorted { $0.score > $1.score }
    }

    /// The type the words point to most, "Document" when nothing does.
    public static func type(of text: String) -> String {
        guard let best = typeScores(text).first, best.score > 0 else { return "Document" }
        return best.name  // ties go to the earlier, more specific type
    }

    /// Which domain to file in, among the vault's `domains`: strong words in the text first, then the
    /// type's home, then records; always one of `domains` when it has any.
    public static func domain(type: String, text: String, domains: [String]) -> String {
        let home = types.first { $0.name == type }?.domain
        var scores = domainScores(text)
        if let home {  // the type's home wins a tie
            if let i = scores.firstIndex(where: { $0.domain == home }) { scores[i].score += 1 }
        }
        let ranked = scores.sorted { $0.score > $1.score }.map(\.domain)
        for d in ranked + [home, "records", "notes"].compactMap({ $0 }) where domains.isEmpty || domains.contains(d) { return d }
        return domains.first ?? "records"
    }

    // MARK: Money

    private static let money = try! NSRegularExpression(pattern: #"(?<![\w.,])(\$|USD ?)?\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?(?![\d,]*\.?\d)"#)

    /// Every sum of money with the words before it on its line as its label. A number counts as money
    /// only with a $ (or USD) or cents. Parsed here, in Swift: never by the model.
    public static func amounts(in text: String) -> [ScanAmount] {
        var found: [ScanAmount] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            for m in money.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let sign = m.range(at: 1).location != NSNotFound
                let cents = m.range(at: 3).location != NSNotFound
                guard sign || cents else { continue }
                let whole = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ",", with: "")
                let value = whole + "." + (cents ? ns.substring(with: m.range(at: 3)) : "00")
                let before = ns.substring(to: m.range.location).lowercased()
                let a = ScanAmount(label: moneyLabel(before), value: value.trimmingLeadingZeros)
                if !found.contains(a) { found.append(a) }
            }
        }
        // The named sums first (due, total, premium...), then the rest, eight at most.
        return Array((found.filter { $0.label != "Amount" } + found.filter { $0.label == "Amount" }).prefix(10))
    }

    static func moneyLabel(_ before: String) -> String {
        let labels: [(String, [String])] = [("Amount due", ["amount due", "total due", "balance due", "please pay", "payment due", "new balance", "please remit", "remit"]),
                                            ("Net", ["net owner funds", "owner funds", "net pay", "net to owner"]),
                                            ("Subtotal", ["subtotal", "sub total"]), ("Tax", ["sales tax", "tax"]), ("Total", ["total"]),
                                            ("Premium", ["premium"]), ("Rent", ["rent"]), ("Deposit", ["deposit"]), ("Deductible", ["deductible"]),
                                            ("Balance", ["balance"]), ("Payment", ["payment", "paid"])]
        // The label nearest the number wins: "Subtotal 10.00 Tax 0.80" labels 0.80 Tax.
        // Compared by where each word ends, so "total" inside "subtotal" loses to "subtotal".
        var best: (String, String.Index, Int)?
        for (label, words) in labels {
            for w in words {
                guard let r = before.range(of: w, options: .backwards) else { continue }
                if best == nil || r.upperBound > best!.1 || (r.upperBound == best!.1 && w.count > best!.2) { best = (label, r.upperBound, w.count) }
            }
        }
        return best?.0 ?? "Amount"
    }

    // MARK: References

    private static let reference = try! NSRegularExpression(
        pattern: #"\b(account|acct|policy|member|invoice|claim|reference|ref|loan|order|confirmation|customer|patient|card)\b\.?\s*(?:no\.?|number|num|#|id)?\s*[:#.]?\s*([A-Z0-9][A-Z0-9-]{2,}(?: [0-9]{4})*)"#,
        options: .caseInsensitive)
    private static let ssn = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-(\d{4})\b"#)

    /// Account, policy and other numbers, as a label and the last four characters only.
    public static func references(in text: String) -> [ScanReference] {
        let ns = text as NSString
        var found: [ScanReference] = []
        func add(_ r: ScanReference) { if !found.contains(r) { found.append(r) } }
        for m in reference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 2)).filter { $0.isLetter || $0.isNumber }
            guard raw.filter(\.isNumber).count >= 4 else { continue }
            var label = ns.substring(with: m.range(at: 1)).lowercased()
            label = ["acct": "account", "ref": "reference"][label] ?? label
            add(ScanReference(label: label.prefix(1).uppercased() + label.dropFirst(), last4: String(raw.suffix(4)).uppercased()))
        }
        for m in ssn.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            add(ScanReference(label: "SSN", last4: ns.substring(with: m.range(at: 1))))
        }
        return Array(found.prefix(6))
    }

    /// The text with every reference number cut to its last four: what may go to the on-device model.
    public static func masked(_ text: String) -> String {
        var out = text
        for re in [reference, ssn] {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let r = m.range(at: m.numberOfRanges > 2 ? 2 : 0)
                let s = ns.substring(with: r)
                guard s.filter(\.isNumber).count >= 4 else { continue }
                out = (out as NSString).replacingCharacters(in: r, with: "ending " + String(s.filter { $0.isLetter || $0.isNumber }.suffix(4)))
            }
        }
        return out
    }

    // MARK: Dates

    public static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A calendar date with its year written: "10/03/2026", "Oct 3, 2026", "2026-10-03". Not "today",
    /// "3 pm" or "January 1" (a date with no year lands in the wrong year).
    static func isCalendarDate(_ s: String) -> Bool {
        s.range(of: #"\d{4}|\d{1,2}[/.-]\d{1,2}[/.-]\d{2}\b"#, options: .regularExpression) != nil
    }

    static func detected(_ line: String) -> [(range: NSRange, day: String, end: String?)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = line as NSString
        return detector.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let d = m.date, isCalendarDate(ns.substring(with: m.range)) else { return nil }
            let y = Calendar(identifier: .gregorian).component(.year, from: d)
            guard (1900...2100).contains(y) else { return nil }
            return (m.range, day.string(from: d), m.duration > 86_400 ? day.string(from: d.addingTimeInterval(m.duration)) : nil)
        }
    }

    /// Every calendar date in the text (both ends of a period too), as YYYY-MM-DD: what a model's date must be one of.
    public static func allDays(in text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { detected($0).flatMap { [$0.day] + ($0.end.map { [$0] } ?? []) } }
    }

    static let dueWords = ["due", "pay by", "payment by", "remit by", "please pay"]
    static let expiryWords = ["expir", "exp ", "exp.", "exp:", "valid thru", "valid through", "valid until", "good through", "ends", "ending on", "end date", "until", "terminat"]
    static let renewWords = ["renew"]
    static let issueWords = ["date", "issued", "dated", "effective", "statement", "invoice", "printed", "as of", "notice", "commenc", "beginning on"]

    /// Whether the words just before a date (`window` characters, across lines) name it as `words` do:
    /// how a model's "due date" is checked against the page.
    public static func dateIsLabelled(_ day: String, as kind: String, in text: String, window: Int = 120) -> Bool {
        let words = kind == "due" ? dueWords : kind == "expires" ? expiryWords : kind == "renews" ? renewWords : issueWords
        let ns = text as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return false }
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let d = m.date, isCalendarDate(ns.substring(with: m.range)) else { continue }
            let days = [ScanText.day.string(from: d)] + (m.duration > 86_400 ? [ScanText.day.string(from: d.addingTimeInterval(m.duration))] : [])
            guard days.contains(day) else { continue }
            let from = max(0, m.range.location - window)
            let before = ns.substring(with: NSRange(location: from, length: m.range.location - from)).lowercased()
            if words.contains(where: before.contains) { return true }
        }
        return false
    }

    /// Dates found by NSDataDetector, each labelled by the words before it on its line, or by a short
    /// label line just above it (a form's "Due Date" over its value). `labelled` says the document date
    /// was named as such, not just the first date seen.
    public static func dates(in text: String, reference: Date = .now) -> (date: String?, due: String?, expires: String?, renews: String?, period: String?) {
        let d = datesLabelled(in: text, reference: reference)
        return (d.date, d.due, d.expires, d.renews, d.period)
    }

    public static func datesLabelled(in text: String, reference: Date = .now)
        -> (date: String?, due: String?, expires: String?, renews: String?, period: String?, labelled: Bool) {
        var out: (date: String?, due: String?, expires: String?, renews: String?, period: String?, labelled: Bool) = (nil, nil, nil, nil, nil, false)
        var loose: [String] = []
        // A document isn't dated more than two months ahead, nor before 1980.
        let latest = day.string(from: reference.addingTimeInterval(60 * 86_400))
        func plausible(_ d: String) -> Bool { d >= "1980-01-01" && d <= latest }
        var above = ""
        for line in text.components(separatedBy: .newlines) {
            let hits = detected(line)
            let lower = line.lowercased()
            defer { if !line.trimmingCharacters(in: .whitespaces).isEmpty { above = hits.isEmpty && line.count <= 60 ? lower : "" } }
            guard !hits.isEmpty else { continue }
            if ["birth", "dob", "born"].contains(where: { lower.contains($0) || above.contains($0) }) { continue }
            let ns = line as NSString
            // "10/03/2026 to 10/03/2027" comes back as one match lasting a year: that is a period too.
            var days = hits.map(\.day)
            if hits.count == 1, let end = hits[0].end { days.append(end) }
            if days.count >= 2, lower.range(of: #"\bto\b|through|thru|\s-\s|–|period|from"#, options: .regularExpression) != nil {
                out.period = out.period ?? "\(days[0]) to \(days[1])"
                if ["effective", "policy period", "coverage", "lease term", "term"].contains(where: { lower.contains($0) || above.contains($0) }) {
                    if out.date == nil { out.date = days[0]; out.labelled = true }
                }
                continue
            }
            for (i, hit) in hits.enumerated() {
                var before = ns.substring(to: hit.range.location).lowercased()
                if before.filter(\.isLetter).count < 3 { before = above }  // the label is the line above
                let d = days[i]
                if dueWords.contains(where: before.contains) { out.due = out.due ?? d }
                else if expiryWords.contains(where: before.contains) { out.expires = out.expires ?? d }
                else if renewWords.contains(where: before.contains) { out.renews = out.renews ?? d }
                else if issueWords.contains(where: before.contains), plausible(d) {
                    if out.date == nil { out.date = d; out.labelled = true }
                } else if plausible(d) { loose.append(d) }
            }
        }
        out.date = out.date ?? loose.first
        return out
    }

    /// The letterhead: the first short line near the top that reads like a name, not a form word.
    public static func issuer(in text: String) -> String {
        let skip = ["invoice", "receipt", "statement", "bill", "page", "date", "account", "policy", "dear", "to:", "from:", "www", "http", "@", "tel", "phone", "fax"]
        for line in text.components(separatedBy: .newlines).prefix(8) {
            let l = line.trimmingCharacters(in: .whitespaces)
            let letters = l.filter(\.isLetter).count
            guard l.count >= 3, l.count <= 48, letters * 10 >= l.count * 6, !skip.contains(where: l.lowercased().contains) else { continue }
            guard types.allSatisfy({ $0.name.lowercased() != l.lowercased() }) else { continue }
            return l.split(separator: " ").joined(separator: " ")
        }
        return ""
    }

    /// Every field the code alone can find. `scanned` is when it was scanned (the date when it has none).
    public static func read(_ text: String, scanned: Date = .now, domains: [String] = []) -> ScanFields {
        let type = type(of: text)
        var d = datesLabelled(in: text, reference: scanned)
        // A statement is dated by the end of its period unless it names its own date.
        if type == "Statement", !d.labelled, let end = d.period?.components(separatedBy: " to ").last { d.date = end }
        var f = ScanFields(type: type, issuer: issuer(in: text), date: d.date ?? day.string(from: scanned), due: d.due, expires: d.expires,
                           renews: d.renews, period: d.period, amounts: amounts(in: text), references: references(in: text),
                           domain: domain(type: type, text: text, domains: domains))
        // A policy, lease or warranty runs to the end of its period.
        if f.expires == nil, ["Insurance Policy", "Lease", "Warranty"].contains(type), let end = d.period?.components(separatedBy: " to ").last { f.expires = end }
        f.summary = f.plainSummary
        return f
    }
}

private extension String {
    var trimmingLeadingZeros: String {
        var s = Substring(self)
        while s.count > 4, s.hasPrefix("0") { s = s.dropFirst() }  // "0.50" stays
        return String(s)
    }
}

// MARK: - Name, note, voice

public extension ScanFields {
    /// The amount that matters most: what is due, else the total, else the first.
    var mainAmount: ScanAmount? {
        for l in ["Amount due", "Total", "Premium", "Net", "Rent", "Balance"] { if let a = amounts.first(where: { $0.label == l }) { return a } }
        return amounts.first
    }

    /// Two plain sentences when the model can't write one.
    var plainSummary: String {
        var s = "\(type == "Document" ? "A document" : type)\(issuer.isEmpty ? "" : " from \(issuer)")\(date.map { ", dated \($0)" } ?? "")."
        if let a = mainAmount { s += " \(a.label) \(a.display)\(due.map { " by \($0)" } ?? "")." }
        else if let e = expires { s += " Expires \(e)." }
        return s
    }

    /// The deadlines, soonest first: what becomes the Expiring list in the vault.
    var deadlines: [(kind: String, date: String)] {
        [("due", due), ("expires", expires), ("renews", renews)].compactMap { k, d in d.map { (k, $0) } }.sorted { $0.date < $1.date }
    }

    /// "2026-10-03 Northwind Mutual Insurance Policy": the file's name without ".pdf". Safe as one path
    /// part on every system (no slashes, colons or underscores), at most 100 characters.
    var name: String {
        let raw = customName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? [date ?? "", issuer, type == "Document" && !issuer.isEmpty ? "" : type].filter { !$0.isEmpty }.joined(separator: " ")
        return Self.safeName(raw)
    }

    static func safeName(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|_#%{}^~[]`").union(.controlCharacters).union(.newlines)
        let cleaned = raw.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        let words = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return words.isEmpty ? "Document" : String(words.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// The sidecar note beside the PDF: front matter every Glyph app and agent can read, one key per
    /// line (JSON values, so any character is safe YAML), then a short body. `entities: []` is filled
    /// with Glyph CRM ids by the hub, which knows the entity pages.
    func sidecar(stem: String, pages: Int, device: String, scanned: Date, source: String = "jot") -> String {
        func j(_ v: some Encodable) -> String {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var head = ["---", "title: \(j(name))", "kind: scan", "type: \(j(type))", "issuer: \(j(issuer))"]
        for (k, v) in [("date", date), ("due", due), ("expires", expires), ("renews", renews), ("period", period)] { if let v { head.append("\(k): \(v)") } }
        head += ["domain: \(domain)", "entities: []", "people: \(j(people))", "about: \(j(about))", "amounts: \(j(amounts))",
                 "references: \(j(references))", "deadlines: \(j(deadlines.map { ["kind": $0.kind, "date": $0.date] }))",
                 "file: \(j(name + ".pdf"))", "pages: \(pages)", "summary: \(j(summary))",
                 "device: \(j(device))", "scanned: \(iso.string(from: scanned))", "source: \(source)", "scan: \(stem)", "---", ""]
        var body = ["# \(name)", "", summary, ""]
        if !deadlines.isEmpty { body += ["## Dates", ""] + deadlines.map { "- \($0.kind.prefix(1).uppercased() + $0.kind.dropFirst()) \($0.date)" } + [""] }
        if !amounts.isEmpty { body += ["## Amounts", ""] + amounts.map { "- \($0.label) \($0.display)" } + [""] }
        if !references.isEmpty { body += ["## References", ""] + references.map { "- \($0.display)" } + [""] }
        body += ["[Open the PDF](<\(name).pdf>)", ""]
        return (head + body).joined(separator: "\n")
    }

    /// Fixes said out loud on the review card: "the date is March 3 2027 and it's from Northwind,
    /// file it under insurance". Each field word starts a clause that runs to the next one. Returns
    /// which fields changed (empty: nothing understood).
    @discardableResult
    mutating func apply(spoken: String, domains: [String], now: Date = .now) -> [String] {
        let keys: [(field: String, pattern: String)] = [
            ("due", #"\b(?:the )?due(?: date)?(?: is| on|:)?\b"#), ("expires", #"\b(?:it )?(?:expires|expiry(?: date)?(?: is)?|expiration(?: date)?(?: is)?)\b"#),
            ("renews", #"\b(?:it )?renews(?: on)?\b|\brenewal(?: date)?(?: is)?\b"#),
            ("date", #"\b(?:the )?(?:issue )?date(?: is)?\b|\bdated\b"#),
            ("issuer", #"\b(?:the )?(?:issuer|company|sender)(?: is)?\b|\b(?:it'?s|it is) from\b|\bfrom\b"#),
            ("type", #"\b(?:the )?type(?: is)?\b|\b(?:it'?s|it is) an?\b"#),
            ("domain", #"\b(?:the )?domain(?: is)?\b|\bfile (?:it )?(?:in|under|to|into)\b"#),
            ("name", #"\b(?:name it|call it|the name is|rename it(?: to)?)\b"#),
            ("amount", #"\b(?:the )?(?:amount|total)(?: due)?(?: is)?\b"#),
        ]
        let text = spoken.replacingOccurrences(of: "\n", with: " ")
        let lower = text.lowercased() as NSString
        var hits: [(field: String, range: NSRange)] = []
        for (field, p) in keys {
            let re = try! NSRegularExpression(pattern: p)
            for m in re.matches(in: lower as String, range: NSRange(location: 0, length: lower.length))
            where !hits.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) { hits.append((field, m.range)) }
        }
        hits.sort { $0.range.location < $1.range.location }
        var changed: [String] = []
        for (i, hit) in hits.enumerated() {
            let start = hit.range.location + hit.range.length
            let end = i + 1 < hits.count ? hits[i + 1].range.location : lower.length
            guard end > start else { continue }
            var value = (text as NSString).substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            for tail in [" and", " also", " then", " so"] where value.lowercased().hasSuffix(tail) { value = String(value.dropLast(tail.count)) }
            value = value.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            guard !value.isEmpty else { continue }
            switch hit.field {
            case "due", "expires", "renews", "date":
                guard let d = Self.spokenDay(value, now: now) else { continue }
                switch hit.field { case "due": due = d; case "expires": expires = d; case "renews": renews = d; default: date = d }
            case "issuer": issuer = value.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            case "type":
                guard let t = ScanText.types.first(where: { value.lowercased().contains($0.name.lowercased()) })?.name
                    ?? ScanText.types.first(where: { value.lowercased().hasPrefix(String($0.name.lowercased().split(separator: " ")[0])) })?.name else { continue }
                type = t
            case "domain":
                let slug = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
                guard let d = domains.first(where: { $0 == slug || slug.hasPrefix($0) || $0.hasPrefix(slug) && slug.count >= 3 }) else { continue }
                domain = d
            case "name": customName = value
            case "amount":
                guard let a = ScanText.amounts(in: value.contains("$") || value.contains(".") ? value : "$" + value.filter { $0.isNumber || $0 == "." || $0 == "," }).first else { continue }
                let label = mainAmount?.label ?? "Amount"
                amounts.removeAll { $0.label == label }
                amounts.insert(ScanAmount(label: label, value: a.value), at: 0)
            default: continue
            }
            if !changed.contains(hit.field) { changed.append(hit.field) }
        }
        if !changed.isEmpty && customName == nil { summary = changed.contains("issuer") || changed.contains("type") ? plainSummary : summary }
        return changed
    }

    /// "March 3 2027", "3/15/2027", "next Friday" as YYYY-MM-DD.
    static func spokenDay(_ s: String, now: Date) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), let d = m.date else { return nil }
        _ = now
        return ScanText.day.string(from: d)
    }
}
