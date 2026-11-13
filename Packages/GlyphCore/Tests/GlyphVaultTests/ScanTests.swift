import Foundation
import Testing
@testable import GlyphVault

/// Made-up documents only: invented companies, people and numbers.
@Suite struct ScanTests {
    static let domains = ["career", "health", "insurance", "notes", "real-estate", "records", "tax", "wealth"]

    static let policy = """
        Northwind Mutual
        Homeowners Policy Declarations
        Named Insured: Ken Lee
        Policy Number: HO-55-7781-4821
        Property: 12 Elm Street, Springfield
        Policy Period: 10/03/2026 to 10/03/2027
        Annual Premium: $1,234.56
        Deductible $1,000
        """

    static let bill = """
        Lakeside Power and Light
        Statement Date: September 28, 2026
        Account Number 3300 1200 9876
        Service period 08/25/2026 - 09/24/2026
        Amount Due $87.40
        Please pay by October 15, 2026
        """

    static let receipt = """
        Corner Hardware
        123 Main St
        10/12/2026 4:12 PM
        Furnace filter 2 x 14.99
        Subtotal 29.98
        Sales Tax 2.40
        Total $32.38
        VISA ending 0042
        Thank you for your purchase
        """

    static let w2 = """
        Form W-2 Wage and Tax Statement 2025
        Employer: Acme Widgets Inc
        Employee SSN 123-45-6789
        Wages, tips, other compensation 84,210.00
        Federal income tax withheld 9,880.15
        Department of the Treasury Internal Revenue Service
        """

    @Test func types() {
        #expect(ScanText.type(of: Self.policy) == "Insurance Policy")
        #expect(ScanText.type(of: Self.bill) == "Bill")
        #expect(ScanText.type(of: Self.receipt) == "Receipt")
        #expect(ScanText.type(of: Self.w2) == "Tax Form")
        #expect(ScanText.type(of: "hello there") == "Document")
    }

    @Test func routing() {
        #expect(ScanText.domain(type: "Insurance Policy", text: Self.policy, domains: Self.domains) == "insurance")
        #expect(ScanText.domain(type: "Tax Form", text: Self.w2, domains: Self.domains) == "tax")
        #expect(ScanText.domain(type: "Receipt", text: Self.receipt, domains: Self.domains) == "records")
        // A receipt for a rental's repair goes to real estate.
        #expect(ScanText.domain(type: "Receipt", text: Self.receipt + "\nTenant: unit 2, rental property", domains: Self.domains) == "real-estate")
        // Only domains the vault has: no tax domain, so records.
        #expect(ScanText.domain(type: "Tax Form", text: Self.w2, domains: ["notes", "records"]) == "records")
        #expect(ScanText.domain(type: "Lab Result", text: "Patient: Dana Wells\nSpecimen collected", domains: Self.domains) == "health")
        // "irate" is not the IRS-free word "ira".
        #expect(ScanText.domain(type: "Letter", text: "Dear customer, an irate note", domains: Self.domains) == "records")
    }

    @Test func amounts() {
        let a = ScanText.amounts(in: Self.policy)
        #expect(a.contains(ScanAmount(label: "Premium", value: "1234.56")))
        #expect(a.contains(ScanAmount(label: "Deductible", value: "1000.00")))
        let r = ScanText.amounts(in: Self.receipt)
        #expect(r.contains(ScanAmount(label: "Subtotal", value: "29.98")))
        #expect(r.contains(ScanAmount(label: "Tax", value: "2.40")))
        #expect(r.contains(ScanAmount(label: "Total", value: "32.38")))
        #expect(!r.contains { $0.value == "123.00" }, "a street number is not money")
        #expect(ScanText.amounts(in: "Order 4821 shipped").isEmpty)
        #expect(ScanText.amounts(in: "Balance 0.50").first?.value == "0.50")
        #expect(ScanAmount(label: "Total", value: "1234.56").display == "$1,234.56")
        #expect(ScanAmount(label: "Total", value: "84210.00").decimal == Decimal(string: "84210")!)
    }

    @Test func references() {
        #expect(ScanText.references(in: Self.policy) == [ScanReference(label: "Policy", last4: "4821")])
        #expect(ScanText.references(in: Self.bill).first == ScanReference(label: "Account", last4: "9876"))
        #expect(ScanText.references(in: Self.w2).contains(ScanReference(label: "SSN", last4: "6789")))
        let masked = ScanText.masked(Self.policy + "\n" + Self.w2)
        #expect(!masked.contains("7781") && !masked.contains("123-45") && masked.contains("ending 4821"), "\(masked)")
    }

    @Test func dates() {
        let p = ScanText.dates(in: Self.policy)
        #expect(p.period == "2026-10-03 to 2027-10-03")
        let b = ScanText.dates(in: Self.bill)
        #expect(b.date == "2026-09-28" && b.due == "2026-10-15" && b.period == "2026-08-25 to 2026-09-24")
        #expect(ScanText.dates(in: "Date of birth 01/02/1990\nIssued 05/06/2024").date == "2024-05-06")
        #expect(ScanText.dates(in: "Expires 12/31/2030").expires == "2030-12-31")
    }

    @Test func fullRead() {
        let scanned = ScanText.day.date(from: "2026-10-29")!
        let f = ScanText.read(Self.policy, scanned: scanned, domains: Self.domains)
        #expect(f.type == "Insurance Policy" && f.issuer == "Northwind Mutual" && f.domain == "insurance")
        #expect(f.date == "2026-10-03" && f.expires == "2027-10-03")
        #expect(f.name == "2026-10-03 Northwind Mutual Insurance Policy")
        #expect(f.summary.contains("Insurance Policy from Northwind Mutual"))
        let r = ScanText.read(Self.receipt, scanned: scanned, domains: Self.domains)
        #expect(r.issuer == "Corner Hardware" && r.date == "2026-10-12" && r.mainAmount?.value == "32.38")
        #expect(r.name == "2026-10-12 Corner Hardware Receipt")
        // No date at all: the scan date.
        #expect(ScanText.read("Some Company\nhello", scanned: scanned).date == "2026-10-29")
    }

    @Test func naming() {
        var f = ScanFields(type: "Invoice", issuer: "Acme/Widgets: West_Coast", date: "2026-01-05")
        #expect(f.name == "2026-01-05 Acme Widgets West Coast Invoice")
        f.issuer = ""
        #expect(f.name == "2026-01-05 Invoice")
        f.type = "Document"; f.issuer = "Acme"
        #expect(f.name == "2026-01-05 Acme")
        f.customName = "  Furnace receipt for unit 2 "
        #expect(f.name == "Furnace receipt for unit 2")
        f.customName = String(repeating: "a", count: 300)
        #expect(f.name.count == 100)
        #expect(ScanFields(type: "Document", date: nil).name == "Document")
    }

    @Test func sidecar() {
        var f = ScanText.read(Self.policy, scanned: ScanText.day.date(from: "2026-10-29")!, domains: Self.domains)
        f.people = ["Ken Lee"]; f.about = ["12 Elm Street"]
        let note = f.sidecar(stem: "2026-10-29 10-12-00", pages: 3, device: "iPhone 17 Pro", scanned: Date(timeIntervalSince1970: 0))
        let lines = note.components(separatedBy: "\n")
        #expect(lines.first == "---")
        for key in ["title: \"2026-10-03 Northwind Mutual Insurance Policy\"", "kind: scan", "type: \"Insurance Policy\"", "issuer: \"Northwind Mutual\"",
                    "date: 2026-10-03", "expires: 2027-10-03", "domain: insurance", "entities: []", "people: [\"Ken Lee\"]",
                    "about: [\"12 Elm Street\"]", "pages: 3", "source: jot", "scan: 2026-10-29 10-12-00",
                    "file: \"2026-10-03 Northwind Mutual Insurance Policy.pdf\"",
                    "deadlines: [{\"date\":\"2027-10-03\",\"kind\":\"expires\"}]",
                    "references: [{\"label\":\"Policy\",\"last4\":\"4821\"}]"] {
            #expect(lines.contains(key), "missing \(key) in\n\(note)")
        }
        #expect(lines.contains { $0.hasPrefix("amounts: [") && $0.contains("\"value\":\"1234.56\"") })
        #expect(!note.contains("7781"), "a full number leaked into the note")
        #expect(note.contains("- Policy ending 4821") && note.contains("[Open the PDF](<2026-10-03 Northwind Mutual Insurance Policy.pdf>)"))
        // The entities line is GlyphCore's, so EntityRefs (and the hub) can fill it.
        #expect(EntityRefs.ids(in: note).isEmpty)
        #expect(EntityRefs.ids(in: EntityRefs.adding(["org/northwind-mutual"], to: note)!) == ["org/northwind-mutual"])
    }

    @Test func voiceFix() {
        let now = ScanText.day.date(from: "2026-10-29")!
        var f = ScanText.read(Self.receipt, scanned: now, domains: Self.domains)
        let changed = f.apply(spoken: "It's from Hilltop Supply and the date is March 3, 2027, file it under real estate", domains: Self.domains, now: now)
        #expect(Set(changed) == ["issuer", "date", "domain"], "\(changed)")
        #expect(f.issuer == "Hilltop Supply" && f.date == "2027-03-03" && f.domain == "real-estate")
        #expect(f.name == "2027-03-03 Hilltop Supply Receipt")
        f.apply(spoken: "type is invoice. Due date is April 1 2027. The total is $45.10", domains: Self.domains, now: now)
        #expect(f.type == "Invoice" && f.due == "2027-04-01" && f.mainAmount?.value == "45.10")
        f.apply(spoken: "name it furnace filter for unit two", domains: Self.domains, now: now)
        #expect(f.name == "furnace filter for unit two")
        var g = f
        #expect(g.apply(spoken: "lovely weather", domains: Self.domains, now: now).isEmpty)
        #expect(g == f)
    }
}
