import Foundation
import SwiftUI
import Testing

@testable import GlyphCapture

@Suite("The tags every app reads from the register")
@MainActor
struct TagsTests {
    /// A register as the hub serves it: the two names that used to disagree between Glyph Jot
    /// and the vault, with the old spellings kept as aliases.
    private func register() -> GlyphTags {
        let tags = GlyphTags()
        tags.take([
            GlyphTag(name: "Jokes", covers: "Funny lines.", hex: "#c83a46", aliases: ["Comedy"]),
            GlyphTag(name: "Learning", covers: "Books, courses.", hex: "#62c83a", aliases: ["Knowledge", "Books"]),
            GlyphTag(name: "Real Estate", covers: "Houses and land.", hex: "#983ac8"),
            GlyphTag(name: "Whisper", covers: "Sayings.", hex: "#c86a3a"),
        ])
        return tags
    }

    @Test("An old spelling reads as the tag it became, and an unknown one is left alone")
    func aliases() {
        let tags = register()
        #expect(tags.canonical("Comedy") == "Jokes")
        #expect(tags.canonical("comedy") == "Jokes")
        #expect(tags.canonical("Books") == "Learning")
        // Whisper is a tag of its own: Glyph Jot used to fold it into Content, and the vault
        // said otherwise (Fru has written with it).
        #expect(tags.canonical("Whisper") == "Whisper")
        // A tag made a second ago keeps its own name until the hub registers it.
        #expect(tags.canonical("Flare week") == "Flare week")
    }

    @Test("The slug is the vault's spelling, whatever the case or the spaces")
    func slugs() {
        #expect(GlyphTag.slug("Real Estate") == "real-estate")
        #expect(GlyphTag.slug("real-estate") == "real-estate")
        #expect(GlyphTag.slug("  Flare  week ") == "flare-week")
    }

    @Test("A tag's colour is the one its page carries, in every app")
    func colors() {
        let tags = register()
        #expect(tags.color("Jokes") == GlyphTag(name: "x", hex: "#c83a46").color)
        #expect(tags.color("real estate") == GlyphTag(name: "x", hex: "#983ac8").color)
        // One he has just made has no page yet, so it falls back to the family's hash, which is
        // at least the same hash in every app.
        #expect(tags.color("Flare week") == GlyphTagHash.color("Flare week"))
    }
}
