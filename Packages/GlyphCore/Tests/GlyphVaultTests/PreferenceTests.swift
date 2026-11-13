import Testing
@testable import GlyphVault

// Glyph Omega's preferences: one line each under ## Preferences in build/compass.md (made-up words).

private let compass = "# Compass\n~schema:2\n\n## Values\n\n- Family ~id:v-111111 ~rank:1\n\n## Roles\n\n- Parent ~id:r-123456\n"

@Test func preferenceAddedInItsPlace() {
    let (t, id) = OmegaFormat.addPreference(compass, words: "Big legible headers", scope: "design", strong: true, from: "a capture", today: "2026-10-30")
    #expect(id.hasPrefix("p-"))
    #expect(t.contains("## Preferences\n\n- Big legible headers ~id:\(id) ~scope:design ~strength:strong ~added:2026-10-30\n  from: a capture\n\n## Roles"))
    #expect(t.contains("- Parent ~id:r-123456\n"), "every other line kept")
    let p = OmegaFormat.compass(t).preferences
    #expect(p.count == 1 && p[0].scope == "design" && p[0].strong && p[0].title == "Big legible headers")
    #expect(OmegaFormat.addPreference(t, words: "Big legible headers", scope: "design").0 == t, "the same words twice are one line")
}

@Test func preferenceArchivedNeverDeleted() {
    let (t, id) = OmegaFormat.addPreference(compass, words: "Tea after lunch", scope: "food")
    let off = OmegaFormat.archivePreference(t, id: id)
    #expect(off.contains("~status:archived"))
    #expect(OmegaFormat.compass(off).preferences.count == 1, "kept in the file")
    #expect(OmegaFormat.preferences(off).isEmpty, "agents don't read it")
    #expect(OmegaFormat.preferences(OmegaFormat.archivePreference(off, id: id, false)).count == 1, "and back")
}

@Test func preferencesReadByScope() {
    var t = compass
    t = OmegaFormat.addPreference(t, words: "No em dashes", scope: "writing").0
    t = OmegaFormat.addPreference(t, words: "Coffee before nine", scope: "food").0
    t = OmegaFormat.addPreference(t, words: "Short labels", scope: "design", proposed: true).0
    #expect(OmegaFormat.preferences(t).map(\.title) == ["No em dashes", "Coffee before nine"], "a proposal waits for a yes")
    #expect(OmegaFormat.preferences(t, scopes: ["food"]).map(\.title) == ["Coffee before nine"])
    #expect(OmegaFormat.preferenceLines(OmegaFormat.preferences(t, scopes: ["writing"])) == "- No em dashes (writing)")
    #expect(OmegaFormat.parsePreference("design: big icons") == ("Big icons", "design"))
    #expect(OmegaFormat.guessScope("I hate long labels") == "writing")
    #expect(OmegaFormat.guessScope("never gold") == "brand")
    #expect(OmegaFormat.guessScope("No emojis, drawn icons") == "writing")
}
