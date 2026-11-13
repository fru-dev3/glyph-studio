import Foundation
import Testing
@testable import GlyphVault

/// The on-disk format is a contract with Memosa and every Glyph app. This builds one
/// conversation and its notes through the public writer and compares every file byte
/// for byte with Golden/. A change that alters the format fails here; if the change is
/// meant, update docs/vault-format.md and CHANGELOG.md, then regenerate with
/// `GLYPH_WRITE_GOLDEN=1 swift test --filter contract` and review the diff.
@Test func contractFilesMatchGolden() throws {
    let v = try scratchVault()
    let files = try buildGoldenVault(v)
    let golden = Bundle.module.url(forResource: "Golden", withExtension: nil)!
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Golden")
    for rel in files {
        let written = try String(contentsOf: v.url(rel), encoding: .utf8)
        if ProcessInfo.processInfo.environment["GLYPH_WRITE_GOLDEN"] == "1" {
            let out = source.appending(path: rel)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try written.write(to: out, atomically: true, encoding: .utf8)
            continue
        }
        let expected = try String(contentsOf: golden.appending(path: rel), encoding: .utf8)
        #expect(written == expected, "\(rel) changed: the vault format is a contract")
    }
}

/// The files the golden vault holds, vault-relative.
func buildGoldenVault(_ v: Vault) throws -> [String] {
    let id = try v.createConversation(in: "Work/Acme", title: "Weekly sync: pricing \"Q4\"", created: try Date("2026-10-20T15:00:00Z", strategy: .iso8601), device: "laptop").id
    var ken = Entity(kind: .person, name: "Ken Lee")
    ken.account = "Acme Corp"
    ken.aliases = ["Kenny", "Ken"]
    ken.body = "Runs procurement.\n"
    try v.saveEntity(ken)
    try v.setLinks(id, people: ["kenny", "Kim Park"], accounts: ["acme corp"], tags: ["#Q4 Renewal", "pricing"])
    try v.writeTranscript(Transcript(language: "en", model: "apple-speech", speakers: ["S2": "Ken Lee", "S1": "Me"], segments: [
        .init(start: 0, end: 4.25, speaker: "S1", text: "Thanks for joining, Kenny. Café prices / \"tiers\"?"),
        .init(start: 65.5, end: 70, speaker: "S2", text: "Hold the price\tat last year's level."),
        .init(start: 3_601, end: 3_602, text: "Bye."),
    ]), for: id)
    try v.suggest(id, heard: Heard(people: ["Kim Park"], companies: ["Globex"], topics: ["Budget"]))
    try v.answerSuggestion(id, .tag("budget"), accept: false)
    try v.writeNotes(Notes(summary: "Acme renews next quarter.\nThe price holds.", decisions: ["Hold the price"], actions: [
        ActionItem(text: "Send the order form", owner: "Ken Lee", due: "2026-10-24"),
        ActionItem(text: "Share the price sheet", done: true),
    ]), for: id)
    try v.setTask(id, text: "Send the order form", done: true)
    return ["\(id)/meta.json", "\(id)/transcript.json", "\(id)/transcript.txt", "\(id)/notes.md",
            "People/Ken Lee.md", "People/Kim Park.md", "Accounts/Acme Corp.md"]
}
