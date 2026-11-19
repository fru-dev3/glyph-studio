import Foundation
import SwiftUI
import Testing

@testable import GlyphCapture
import GlyphVault

@Suite("Marking the entities an answer names")
struct EntityLinksTests {
    static let scan = EntityScan([
        .init(id: "orgs/walmart", kind: .org, name: "Walmart"),
        .init(id: "people/john-ryan", kind: .person, name: "John Ryan", aliases: ["JR"]),
        .init(id: "tags/deep-work", kind: .tag, name: "deep work"),
    ])

    /// Every run of the text that carries a link, with the link it carries.
    private func links(_ a: AttributedString) -> [(String, String)] {
        a.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(a[run.range].characters), url.absoluteString)
        }
    }

    @Test func aNameTheVaultKnowsBecomesALink() {
        let a = EntityLinks.attributed("Went to Walmart with John Ryan.", scan: Self.scan)
        #expect(links(a).map(\.0) == ["Walmart", "John Ryan"])
        #expect(links(a).map(\.1) == ["glyph-crm://entity/orgs/walmart",
                                      "glyph-crm://entity/people/john-ryan"])
    }

    @Test func theTextItselfIsNeverChanged() {
        let said = "Went to Walmart with John Ryan about #deep-work."
        let a = EntityLinks.attributed(said, scan: Self.scan)
        #expect(String(a.characters) == said, "nothing added, nothing reworded")
    }

    @Test func anAliasLinksToItsPage() {
        let a = EntityLinks.attributed("JR called.", scan: Self.scan)
        #expect(links(a).map(\.0) == ["JR"])
        #expect(links(a).map(\.1) == ["glyph-crm://entity/people/john-ryan"])
    }

    @Test func onlyTheFirstMentionCarriesTheLink() {
        let a = EntityLinks.attributed("Walmart, then Walmart again.", scan: Self.scan)
        #expect(links(a).count == 1)
    }

    @Test func withNoRegisterNothingIsMarked() {
        let said = "Went to Walmart with John Ryan."
        let a = EntityLinks.attributed(said, scan: nil)
        #expect(links(a).isEmpty)
        #expect(String(a.characters) == said)
    }

    @Test func aLinkSaysWhichEntityItOpens() {
        let url = try! #require(EntityLinks.url("people/john-ryan"))
        #expect(EntityLinks.entity(in: url) == "people/john-ryan")
        #expect(EntityLinks.entity(in: URL(string: "https://example.com/x")!) == nil)
        #expect(EntityLinks.entity(in: URL(string: "glyph-crm://other/x")!) == nil)
    }

    @Test func aNameWithACharacterThatIsNotPlainAsciiStillLinesUp() {
        // The ranges come from the String and are applied by character count, so anything that is
        // one character but several bytes must not shift the marks along.
        let said = "Café notes: Walmart was shut 🙂 and John Ryan called."
        let a = EntityLinks.attributed(said, scan: Self.scan)
        #expect(links(a).map(\.0) == ["Walmart", "John Ryan"])
        #expect(String(a.characters) == said)
    }
}
