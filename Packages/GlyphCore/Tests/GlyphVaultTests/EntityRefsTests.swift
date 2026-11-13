import Testing
@testable import GlyphVault

// Made-up names only.

@Test func entityRefsReadAddAndGuard() {
    let note = "---\ndate: 2026-10-28T09:00:00\nentities: [person/ken-lee]\nkind: voice\n---\n\nMet Ken Lee at Acme.\n"
    #expect(EntityRefs.ids(in: note) == ["person/ken-lee"])
    let added = EntityRefs.adding(["org/acme", "person/ken-lee"], to: note)!
    #expect(added == note.replacingOccurrences(of: "entities: [person/ken-lee]", with: #"entities: ["person/ken-lee", "org/acme"]"#))
    #expect(EntityRefs.adding(["org/acme"], to: added) == nil)
    #expect(EntityRefs.onlyEntitiesChanged(note, added))
    #expect(!EntityRefs.onlyEntitiesChanged(note, added + "x"))
    #expect(!EntityRefs.onlyEntitiesChanged(added, note))  // never takes an id away

    let bare = "---\ndate: 2026-10-28\n---\n\nHello.\n"
    let tagged = EntityRefs.adding(["place/springfield"], to: bare)!
    #expect(tagged == "---\ndate: 2026-10-28\nentities: [\"place/springfield\"]\n---\n\nHello.\n")
    #expect(EntityRefs.onlyEntitiesChanged(bare, tagged))

    let plain = "Just words.\n"
    let made = EntityRefs.adding(["thing/blue-bike"], to: plain)!
    #expect(made == "---\nentities: [\"thing/blue-bike\"]\n---\n\nJust words.\n")
    #expect(EntityRefs.onlyEntitiesChanged(plain, made))
}
