import Foundation
import Testing
@testable import GlyphVault

/// The fixture is a made-up vault in Memosa's format (Fixtures/vault).
let fixture = Vault(root: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: "vault"))

@Test func treeSkipsNotesAndDotFolders() {
    let top = fixture.tree().map(\.name)
    #expect(top == ["Home", "Recordings", "Work"])
    let work = fixture.tree().first { $0.name == "Work" }!
    #expect(work.kind == .domain && work.count == 2)
    #expect(work.children.map(\.name) == ["2026-10-22-hiring-chat", "Acme"])
    let home = fixture.tree().first { $0.name == "Home" }!
    #expect(home.children.first { $0.name == "Empty folder" }?.kind == .folder)
}

@Test func conversationsReadNewestFirstWithDefaults() throws {
    let all = fixture.conversations()
    #expect(all.map(\.title) == ["Recording Oct 25", "Kitchen contractor call", "Hiring chat", "Weekly sync with Acme"])
    let sync = try fixture.conversation("Work/Acme/2026-10-20-weekly-sync")
    #expect(sync.suggested.people == ["Kim Park"] && sync.suggested.dismissed == ["Globex"])
    #expect(try fixture.conversation("Recordings/2026-10-25-recording").suggested.isEmpty)
}

@Test func notesParseSummaryDecisionsAndActions() {
    let n = fixture.notes("Work/Acme/2026-10-20-weekly-sync")
    #expect(n.summary == "Acme wants to renew next quarter. Price stays at last year's level.")
    #expect(n.decisions == ["Hold the price at last year's level"])
    #expect(n.actions == [
        ActionItem(text: "Send the signed order form", done: false, owner: "Ken Lee", due: "2026-10-24"),
        ActionItem(text: "Share last year's price sheet", done: true),
    ])
    #expect(fixture.notes("Home/2026-10-24-contractor-call").actions.map(\.text) == ["Pay the deposit"], "## Actions works too")
    #expect(fixture.notes("Work/2026-10-22-hiring-chat") == Notes(), "no notes.md is empty notes")
}

@Test func transcriptPlainTextNamesSpeakers() {
    let t = fixture.transcript("Work/Acme/2026-10-20-weekly-sync")
    #expect(t.plainText.hasPrefix("[00:00] Me: Thanks for joining, Kenny."))
    #expect(t.plainText.contains("[00:20] Ken Lee: Good."))
    #expect(fixture.transcript("Work/does-not-exist").segments.isEmpty)
}

@Test func peopleAndAccountsResolveAliasesAndEmployers() {
    let dir = fixture.directory()
    let count = { (name: String) in dir.entities.first { $0.entity.name == name }!.count }
    #expect(dir.entities.map(\.entity.name) == ["Acme Corp", "Globex", "Ken Lee", "Kim Park"])
    #expect(count("Acme Corp") == 1, "Ken works at ACME, an alias of Acme Corp")
    #expect(count("Globex") == 1, "linked directly and through Kim: still one call")
    #expect(dir.entities.first { $0.entity.name == "Globex" }!.entity.body == "Hand-written note, no front matter.\n")
    #expect(dir.tags.map(\.name) == ["hiring", "pricing", "renewal"])

    let ix = EntityIndex(fixture.entities())
    #expect(ix.canonical(.person, " kenny ") == "Ken Lee")
    #expect(ix.account(of: "Ken") == "Acme Corp")
    #expect(ix.canonical(.person, "Pat Doe") == "Pat Doe", "unknown names pass through")
}

@Test func searchMatchesNotesAndTranscriptAnyCase() {
    #expect(fixture.search("HOLD THE PRICE") == ["Work/Acme/2026-10-20-weekly-sync"])
    #expect(fixture.search("deposit") == ["Home/2026-10-24-contractor-call"])
    #expect(fixture.search("title:").isEmpty, "front matter is not searched")
    #expect(fixture.search("  ").isEmpty)
}

@Test func entityNoteRoundTrips() {
    var e = Entity(kind: .person, name: " ../Pat/Doe ")
    #expect(e.name == "-Pat-Doe")
    e.aliases = ["P"]
    e.account = "Northwind"
    e.body = "Notes.\n"
    #expect(Entity(kind: .person, name: e.name, text: e.rendered) == e)
}
