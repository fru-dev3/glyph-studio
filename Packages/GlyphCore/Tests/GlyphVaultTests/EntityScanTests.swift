import Foundation
import Testing

@testable import GlyphVault

@Suite("Finding the entities the vault knows inside what was said")
struct EntityScanTests {
    static let known = EntityScan([
        .init(id: "orgs/walmart", kind: .org, name: "Walmart"),
        .init(id: "people/john-ryan", kind: .person, name: "John Ryan", aliases: ["JR"]),
        .init(id: "people/ken-lee", kind: .person, name: "Ken Lee"),
        .init(id: "people/ken-park", kind: .person, name: "Ken Park"),
        .init(id: "places/stone-arch-bridge", kind: .place, name: "Stone Arch Bridge"),
        .init(id: "tags/deep-work", kind: .tag, name: "deep work"),
        .init(id: "tags/learning", kind: .tag, name: "learning"),
        .init(id: "orgs/go", kind: .org, name: "Go"),
    ])

    @Test func namesTheVaultKnowsAreFound() {
        let said = "I went to Walmart with John Ryan and parked near the Stone Arch Bridge."
        let hits = Self.known.hits(in: said)
        #expect(hits.map(\.id) == ["orgs/walmart", "people/john-ryan", "places/stone-arch-bridge"])
        #expect(hits.map(\.said) == ["Walmart", "John Ryan", "Stone Arch Bridge"])
        #expect(hits.map(\.kind) == [.org, .person, .place])
    }

    @Test func theFullestNameWinsTheWordsItCovers() {
        // "Ken Lee" must not come back as a bare "Ken", and must not also yield "Lee".
        let hits = Self.known.hits(in: "Ken Lee called about Ken Park")
        #expect(hits.map(\.id) == ["people/ken-lee", "people/ken-park"])
        // No two hits may overlap, or a highlight would be drawn twice over the same words.
        for (a, b) in zip(hits, hits.dropFirst()) {
            #expect(a.range.upperBound <= b.range.lowerBound)
        }
    }

    @Test func aNameInsideALongerWordIsNotAMention() {
        #expect(Self.known.hits(in: "the Walmartians are coming").isEmpty)
        #expect(Self.known.hits(in: "a prewalmart era").isEmpty)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        #expect(Self.known.hits(in: "walmart").map(\.id) == ["orgs/walmart"])
        #expect(Self.known.hits(in: "WALMART, then home").map(\.id) == ["orgs/walmart"])
        // The canonical name comes back for display even when an alias was written.
        let jr = Self.known.hits(in: "spoke to JR today")
        #expect(jr.map(\.name) == ["John Ryan"])
        #expect(jr.map(\.said) == ["JR"])
    }

    @Test func aTagIsFoundBothWaysItIsWritten() {
        #expect(Self.known.hits(in: "filing this under #deep-work").map(\.id) == ["tags/deep-work"])
        #expect(Self.known.hits(in: "a morning of deep work").map(\.id) == ["tags/deep-work"])
        #expect(Self.known.hits(in: "#learning").map(\.id) == ["tags/learning"])
    }

    @Test func aShortOrCommonNameIsOnlyAMentionWhenWrittenAsATag() {
        // An entity really called "Go" would otherwise hit every other sentence.
        #expect(Self.known.hits(in: "I will go to the shop").isEmpty)
        #expect(Self.known.hits(in: "a note about #go").map(\.id) == ["orgs/go"])
    }

    @Test func theRangesPointAtTheWordsThemselves() {
        let said = "met John Ryan at Walmart"
        for hit in Self.known.hits(in: said) {
            #expect(String(said[hit.range]) == hit.said)
        }
    }

    @Test func onlyTheFirstMentionOfEachIsMarked() {
        let said = "Walmart again. Walmart every week. John Ryan was at Walmart too."
        #expect(Self.known.hits(in: said).map(\.id)
                == ["orgs/walmart", "orgs/walmart", "people/john-ryan", "orgs/walmart"])
        // What a reader sees: one link per entity, at its first mention, in order.
        let first = Self.known.firstMentions(in: said)
        #expect(first.map(\.id) == ["orgs/walmart", "people/john-ryan"])
        #expect(first[0].range.lowerBound == said.startIndex)
    }

    @Test func nothingKnownMeansNothingFound() {
        #expect(EntityScan([]).hits(in: "Walmart and John Ryan").isEmpty)
        #expect(Self.known.hits(in: "").isEmpty)
        #expect(Self.known.hits(in: "nobody here by that name").isEmpty)
    }
}

@Suite("An entity in more than one domain")
struct EntityDomainsTests {
    @Test func aPageWrittenBeforeDomainsWereAListStillReads() {
        let page = CRMPage(text: """
        ---
        name: Stone Arch Bridge
        kind: place
        domain: explore
        ---

        """, slug: "stone-arch-bridge", kind: "place")
        #expect(page.domains == ["explore"])
        #expect(page.domain == "explore")
    }

    @Test func aTagRollsUpIntoSeveralDomains() {
        let page = CRMPage(text: """
        ---
        name: learning
        kind: tag
        domains: ["growth", "career"]
        ---

        """, slug: "learning", kind: "tag")
        #expect(page.domains == ["growth", "career"])
        #expect(page.domain == "growth")
    }

    @Test func theListSurvivesBeingWrittenAndReadBack() {
        var page = CRMPage(name: "learning", kind: "tag")
        page.domains = ["growth", "career", "dev"]
        let back = CRMPage(text: page.render(), slug: "learning", kind: "tag")
        #expect(back.domains == ["growth", "career", "dev"])
        // The single key stays beside the list for every reader that knows only that one.
        #expect(page.render().contains("domain: growth"))
    }

    @Test func noDomainIsAFineAnswer() {
        let page = CRMPage(name: "A lamp", kind: "thing")
        #expect(page.domains.isEmpty)
        #expect(page.domain == nil)
        #expect(!page.render().contains("domain"))
    }
}
