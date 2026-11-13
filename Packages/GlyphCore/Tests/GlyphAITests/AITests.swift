import Foundation
import Testing
@testable import GlyphAI
import GlyphVault

@Test func longTranscriptsSplitOnLinesAndKeepEveryWord() {
    let text = (0..<300).map { "line \($0) of the call" }.joined(separator: "\n")
    let parts = Summarizer.parts(text, max: 1_000)
    #expect(parts.count > 3)
    #expect(parts.allSatisfy { $0.count <= 1_000 })
    #expect(parts.joined().split(separator: "\n").count == 300, "nothing dropped")
    #expect(Summarizer.parts("short", max: 1_000) == ["short\n"])

    let long = String(repeating: "word ", count: 3_000) // one 15,000-character line
    let cut = Summarizer.parts(long, max: Summarizer.partCharacters)
    #expect(cut.count == 3)
    #expect(cut.allSatisfy { $0.count <= Summarizer.partCharacters })
    #expect(cut.map { $0.replacingOccurrences(of: "\n", with: "") }.joined() == long, "a long line is cut, never dropped")
}

@Test func promptsCarryTitleDateAndTranscript() {
    let p = Summarizer.prompt(title: "Weekly sync", date: "2026-10-20", transcript: "[00:00] Ken Lee: Hello.")
    #expect(p.contains("\"Weekly sync\"") && p.contains("recorded on 2026-10-20") && p.hasSuffix("[00:00] Ken Lee: Hello."))
    #expect(Summarizer.partPrompt("x").hasSuffix("TRANSCRIPT PART:\nx"))
}

@Test func firstNameOwnersGetTheLinkedFullName() {
    let g = GeneratedNotes(summary: "s", decisions: [], actions: [
        GeneratedAction(text: "Send the form", owner: "Ken", due: nil),
        GeneratedAction(text: "Book the room", owner: "Kim", due: nil),
        GeneratedAction(text: "Call Pat", owner: "Pat", due: nil),
    ])
    let heard = "Ken will send the form, Kim books the room, Pat gets a call."
    let n = Summarizer.notes(from: g, heard: heard, people: ["Ken Lee", "Kim Park", "Kim Ortiz"])
    #expect(n.actions.map(\.owner) == ["Ken Lee", "Kim", "Pat"], "one Ken resolves; two Kims and an unlinked Pat stay as said")
    #expect(Summarizer.notes(from: g, heard: heard).actions[0].owner == "Ken", "no linked people: unchanged")
}

@Test func modelAnswersAreCleaned() {
    let g = GeneratedNotes(summary: "  Acme renews. ", decisions: ["Hold the price", " ", "None."], actions: [
        GeneratedAction(text: "Send the order form", owner: "Ken Lee", due: "2026-10-24"),
        GeneratedAction(text: "Share the sheet", owner: "null", due: "Friday"),
        GeneratedAction(text: " ", owner: nil, due: nil),
        GeneratedAction(text: "Call back", owner: " ", due: "N/A"),
        GeneratedAction(text: "Invented", owner: "Pat Doe", due: "2026-10-21"),
        GeneratedAction(text: "send the order form", owner: nil, due: nil),
        GeneratedAction(text: "None", owner: nil, due: nil),
        GeneratedAction(text: "N/A.", owner: nil, due: nil),
        GeneratedAction(text: "No other action items mentioned.", owner: nil, due: nil),
        GeneratedAction(text: "No other decisions mentioned", owner: nil, due: nil),
        GeneratedAction(text: "Note the price", owner: nil, due: nil),
    ])
    let n = Summarizer.notes(from: g, heard: "Ken Lee will send it by October 24.")
    #expect(n.summary == "Acme renews.")
    #expect(n.decisions == ["Hold the price"])
    #expect(n.actions == [
        ActionItem(text: "Send the order form", owner: "Ken Lee", due: "2026-10-24"),
        ActionItem(text: "Share the sheet"),
        ActionItem(text: "Call back"),
        ActionItem(text: "Invented"),
        ActionItem(text: "Note the price"),
    ], "an owner or a date the call never says is dropped, and so is a repeat")
    #expect(Summarizer.notes(from: g, heard: "Ken Lee will send it.").actions.allSatisfy { $0.due == nil })

    #expect(Summarizer.saysDay("2026-10-24", in: "send it by 2026-10-24"))
    #expect(Summarizer.saysDay("2026-10-23", in: "by Friday please"), "2026-10-23 is a Friday")
    #expect(Summarizer.saysDay("2026-10-24", in: "on the 24th of Oct"))
    #expect(Summarizer.saysDay("2026-10-24", in: "October 24, 2026"))
    #expect(Summarizer.saysDay("2026-10-24", in: "due 10/24"))
    #expect(Summarizer.saysDay("2026-10-21", in: "send it tomorrow"))
    #expect(!Summarizer.saysDay("2026-10-21", in: "legal by 2026-11-02, the 21 tiers"), "another date, or a number alone, is not this day")
    #expect(!Summarizer.saysDay("Friday", in: "Friday"))
}

@Test func errorsSayWhatToDo() async throws {
    #expect(AIError.unavailable(.appleIntelligenceOff).errorDescription?.contains("Turn on Apple Intelligence") == true)
    await #expect(throws: AIError.emptyTranscript) { try await Summarizer().summarize(Transcript(), title: "t", date: "2026-10-20") }
    #expect(try await LinkSuggester().hear(" ") == Heard())
}

/// One real call to Apple's on-device model, when this Mac has it on.
@Test(.timeLimit(.minutes(5))) func summarizesWithTheOnDeviceModel() async throws {
    print("on-device model: \(OnDeviceModel.status)")
    guard OnDeviceModel.status == .available else {
        await #expect(throws: AIError.unavailable(OnDeviceModel.status)) {
            try await Summarizer().summarize(Transcript(language: "en", model: "x", segments: [.init(start: 0, end: 1, text: "Hi.")]), title: "t", date: "2026-10-20")
        }
        try Test.cancel("Apple Intelligence is \(OnDeviceModel.status) on this Mac.")
    }
    let dir = FileManager.default.temporaryDirectory.appending(path: "glyph-ai-\(UUID().uuidString)")
    let vault = Vault(root: dir)
    try vault.saveEntity(Entity(kind: .person, name: "Ken Lee"))
    let id = try vault.createConversation(in: "Work", title: "Weekly sync with Acme", created: try Date("2026-10-20T15:00:00Z", strategy: .iso8601)).id
    try vault.writeTranscript(Transcript(language: "en", model: "apple-speech", speakers: ["S1": "Kim Park", "S2": "Ken Lee"], segments: [
        .init(start: 0, end: 10, speaker: "S1", text: "Thanks for joining. Acme wants to renew next quarter."),
        .init(start: 10, end: 20, speaker: "S2", text: "We agreed to hold the price at last year's level."),
        .init(start: 20, end: 30, speaker: "S2", text: "I will send the signed order form by October 24, 2026."),
        .init(start: 30, end: 40, speaker: "S1", text: "Great. Let's also talk about hiring for the Globex project."),
    ]), for: id)
    let notes = try await Summarizer().summarize(id, in: vault)
    print("summary: \(notes.summary)\ndecisions: \(notes.decisions)\nactions: \(notes.actions)")
    #expect(!notes.summary.isEmpty)
    #expect(!notes.actions.isEmpty)
    #expect(vault.notes(id).summary == notes.summary, "notes.md was written")

    let meta = try await LinkSuggester().suggest(id, in: vault)
    print("suggested: \(meta.suggested)")
    #expect(meta.suggested.people.contains("Ken Lee"), "a known name the call says")
    #expect(meta.suggested.tags.count <= 3)
}

/// A call too long for one pass: noted in parts, then the notes summarized.
@Test(.timeLimit(.minutes(5))) func summarizesALongCallInParts() async throws {
    guard OnDeviceModel.status == .available else { try Test.cancel("Apple Intelligence is \(OnDeviceModel.status) on this Mac.") }
    let lines = [
        "Kim Park: Let's go through the Acme renewal pricing tiers one more time.",
        "Ken Lee: The board wants the price held at last year's level for every tier.",
        "Kim Park: Then we need the support hours and the onboarding plan written down too.",
        "Ken Lee: I can draft the onboarding plan once legal reviews the contract.",
    ]
    var segments: [Transcript.Segment] = []
    for i in 0..<240 { segments.append(.init(start: Double(i * 5), end: Double(i * 5 + 5), text: lines[i % lines.count])) }
    segments.append(.init(start: 1_200, end: 1_205, text: "Ken Lee: Final decision: we hold the price, and Kim sends the contract to legal by 2026-11-02."))
    let transcript = Transcript(language: "en", model: "apple-speech", segments: segments)
    #expect(transcript.plainText.count > 2 * Summarizer.partCharacters, "\(transcript.plainText.count) characters")
    let notes = try await Summarizer().summarize(transcript, title: "Acme renewal", date: "2026-10-20")
    print("long summary: \(notes.summary)\nlong decisions: \(notes.decisions)\nlong actions: \(notes.actions)")
    #expect(!notes.summary.isEmpty)
}
