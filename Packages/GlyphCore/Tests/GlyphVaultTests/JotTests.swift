import Foundation
import Testing
@testable import GlyphVault

/// Jotting while recording: what you said while holding the talk key stays out of the transcript.
@Test func jotsLeaveTheTranscript() {
    let t = Transcript(language: "en-US", model: "test", segments: [
        .init(start: 0, end: 4.8, text: "Ken wants the renewal signed by Friday."),
        .init(start: 5.1, end: 8.9, text: "Remind me to book the dentist."),   // jotted
        .init(start: 9.2, end: 14, text: "We hold the price for two years."),
        .init(start: 14, end: 20, text: "Pricing for the new seats, then the timeline."), // 1.3 s jotted at its end
    ])
    let jots = [Jot(start: 5.0, end: 9.0, kind: "dictate"), Jot(start: 19.1, end: 21, kind: "thought", note: "n.md")]
    let kept = t.excluding(jots).segments.map(\.text)
    #expect(kept == ["Ken wants the renewal signed by Friday.", "We hold the price for two years."])
    #expect(t.excluding([]).segments.count == 4)
    // A brush at the edge (under a second and under half) keeps the sentence.
    #expect(t.excluding([Jot(start: 14.3, end: 14.5, kind: "dictate")]).segments.count == 4)
}

@Test func jotsRoundTripAndStayOutWhenEmpty() throws {
    var c = Conversation(id: "Recordings/2026-10-25-sync", title: "Sync", created: "2026-10-25T10:00:00Z")
    let empty = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
    #expect(!empty.contains("jots"))
    c.jots = [Jot(start: 1.5, end: 3, kind: "thought", note: "2026-10-25 10-00-02.md")]
    let back = try JSONDecoder().decode(Conversation.self, from: try JSONEncoder().encode(c))
    #expect(back.jots == c.jots)
}

/// meta.json as the vault writes it carries the jots, and reads them back.
@Test func jotsAreWrittenToMetaJSON() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "glyph-jots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = Vault(root: root)
    try vault.ensure()
    var meta = try vault.createConversation(in: "Recordings", title: "Sync")
    #expect(!(try String(contentsOf: vault.url(meta.id).appending(path: "meta.json"), encoding: .utf8)).contains("jots"))
    meta.jots = [Jot(start: 4.2, end: 9, kind: "dictate"), Jot(start: 12, end: 15.5, kind: "thought", note: "a.md")]
    try vault.write(meta)
    #expect(try vault.conversation(meta.id).jots == meta.jots)
}
