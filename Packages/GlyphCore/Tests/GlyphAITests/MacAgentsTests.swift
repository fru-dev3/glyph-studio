import Foundation
import FoundationModels
import Testing
@testable import GlyphAI
import GlyphVault

// The app agents on a Mac: the catalog comes from the tools themselves, and a tool run by name writes into a
// vault folder what the hub would have written. Made-up vault, names and lines only.

private func tempVault(_ domains: [String] = ["notes", "dreams", "career"]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "glyph-mac-agents-\(UUID().uuidString)")
    for d in domains { try FileManager.default.createDirectory(at: root.appending(path: "data/domains/\(d)"), withIntermediateDirectories: true) }
    return root
}

private func macHub(_ vault: URL) -> Hub {
    var hub = Hub(base: nil, model: "Mac", app: "Glyph agents", timeQueue: vault.appending(path: "data/apps/time/requests.laptop-local.jsonl"))
    hub.vault = vault
    hub.hostName = "laptop-local"
    let at = DateComponents(calendar: .current, year: 2026, month: 10, day: 30, hour: 8, minute: 10).date!
    hub.now = { at }
    return hub
}

private func text(_ vault: URL, _ rel: String) -> String? { try? String(contentsOf: vault.appending(path: rel), encoding: .utf8) }

@Test func catalogIsTheToolsOwnDefinitions() throws {
    let catalog = try GlyphAgent.catalog()
    #expect(catalog.map { $0["id"] as? String } == GlyphAgent.all.map(\.id))
    let hub = Hub(base: nil, model: "Mac")
    for (entry, agent) in zip(catalog, GlyphAgent.all) {
        let listed = try #require(entry["tools"] as? [[String: Any]])
        let tools = agent.toolkit(hub, Ledger())
        #expect(listed.map { $0["name"] as? String } == tools.map(\.name))
        for (l, t) in zip(listed, tools) {
            #expect(l["description"] as? String == t.description)
            // The arguments are the tool's own schema, encoded: the same JSON, key for key.
            let own = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t.parameters))
            let a = try JSONSerialization.data(withJSONObject: try #require(l["arguments"]), options: .sortedKeys)
            let b = try JSONSerialization.data(withJSONObject: own, options: .sortedKeys)
            #expect(a == b, "\(agent.id).\(t.name)")
        }
    }
    // What a client sees, spelled out for one tool: Well's log_entry.
    let well = try #require((catalog.first { $0["id"] as? String == "well" }?["tools"] as? [[String: Any]])?.first)
    #expect(well["name"] as? String == "log_entry")
    let args = try #require(well["arguments"] as? [String: Any])
    let props = try #require(args["properties"] as? [String: Any])
    #expect(Set(props.keys) == ["text", "kind", "minutesAgo"])
    #expect(Set(args["required"] as? [String] ?? []) == ["text", "kind", "minutesAgo"])
    #expect(((props["kind"] as? [String: Any])?["enum"] as? [String]) == ["food", "symptom", "mood", "sleep"])
}

@Test func jotNoteIsTheHubsMemoByteForByte() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    let done = try await GlyphAgent.jot.call("new_note", json: #"{"text":"  Ken Lee: call Acme/West\n second line ","tags":["Dreams","Task","Real  Estate","Dreams"]}"#, hub: hub)
    #expect(done.map { $0.card["status"] as? String } == ["done"])
    // What the hub's inbox save() wrote for the same memo (career exists but isn't tagged; real-estate doesn't exist).
    let head = "---\ndate: 2026-10-30T08:10:00\ntags: [\"Dreams\", \"Task\", \"Real Estate\"]\nkind: voice\ndevice: Glyph agents, Mac\nsource: jot\n"
    let body = "---\n\nKen Lee: call Acme/West\n second line\n"
    #expect(text(vault, "data/domains/notes/source/jot/2026-10-30 08-10-00.md") == head + body)
    #expect(text(vault, "data/domains/dreams/source/jot/2026-10-30 08-10-00.md") == head + "original: notes/source/jot/2026-10-30 08-10-00.md\n" + body)
    #expect(text(vault, "data/domains/career/source/jot/2026-10-30 08-10-00.md") == nil)
    #expect(text(vault, "data/domains/dreams/memory/tasks.md") == "# Tasks\n- [ ] Ken Lee: call Acme/West +2026-10-30 [src jot 2026-10-30 08-10-00]\n")
    _ = try await GlyphAgent.jot.call("new_note", json: #"{"text":"Ken Lee: call Acme/West","tags":["Dreams","Task"]}"#, hub: hub)
    #expect(text(vault, "data/domains/dreams/memory/tasks.md")?.components(separatedBy: "[src jot").count == 2, "a task once")
}

@Test func wellLineGoesInThisMacsMonthFile() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    let done = try await GlyphAgent.well.call("log_entry", json: #"{"text":"rice and beans","kind":"food","minutesAgo":30}"#, hub: hub)
    let card = try #require(done.first?.card)
    #expect(card["line"] as? String == "Logged in Well: Rice and beans")
    let id = try #require((card["undo"] as? [String: String])?["well_delete"])
    let line = try #require(text(vault, "data/apps/well/entries/2026-10.laptop-local.jsonl"))
    let o = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(o["id"] as? String == id && o["kind"] as? String == "food" && o["host"] as? String == "laptop-local")
    #expect((o["at"] as? String)?.hasPrefix("2026-10-30T07:40:00") == true)
    #expect(await hub.undo(.wellDelete(id: id)))
    #expect(text(vault, "data/apps/well/entries/2026-10.laptop-local.jsonl")?.split(separator: "\n").count == 2, "the delete line appended")
}

@Test func crmSuggestionOnceAndUndone() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    for _ in 0..<2 { _ = try await GlyphAgent.crm.call("propose", json: #"{"kind":"org","name":"Acme","note":"Ken Lee works there"}"#, hub: hub) }
    let rel = "data/apps/crm/proposals/2026-10.jsonl"
    #expect(text(vault, rel)?.split(separator: "\n").count == 1, "said twice, suggested once")
    #expect(text(vault, rel)?.contains(#""status":"pending""#) == true && text(vault, rel)?.contains(#""kind":"org""#) == true, "an org is filed as org")
    #expect(await hub.undo(.crmReject(id: CRMProposalLine.id(kind: "org", name: "Acme"), file: rel)))
    #expect(text(vault, rel)?.contains(#""status":"rejected""#) == true)
}

@Test func timeOnAMacWaitsForTheIPhone() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    try FileManager.default.createDirectory(at: hub.timeQueue.deletingLastPathComponent(), withIntermediateDirectories: true)
    let done = try await GlyphAgent.time.call("request_alarm", json: #"{"when":"in 2 hours","label":"Gym"}"#, hub: hub)
    let card = try #require(done.first?.card)
    #expect(card["status"] as? String == "waiting")
    #expect((card["message"] as? String)?.contains("Waiting for Time on the iPhone") == true)
    let pending = TimeRequest.pending(in: hub.timeQueue)
    #expect(pending.map(\.command) == ["wake me up in 2 hours for Gym"])
    #expect(pending.first?.id == card["request"] as? String)
}

@Test func badCallsFailAndNothingLeavesTheVault() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    await #expect(throws: GlyphAgent.UnknownTool.self) { try await GlyphAgent.jot.call("delete_everything", json: "{}", hub: hub) }
    await #expect(throws: (any Error).self) { try await GlyphAgent.well.call("log_entry", json: "not json", hub: hub) }
    let m = MacHub(vault: vault)
    #expect(m.handle("GET", "crm/file", query: ["path": "data/../../etc/passwd"], body: nil)?.0 == 403)
    #expect(m.handle("PUT", "crm/file", query: ["path": "data/domains/notes/source/jot/x.md"], body: Data(#"{"text":"x","base":null}"#.utf8))?.0 == 403)
    #expect(m.handle("PUT", "well/../x.jsonl", query: [:], body: Data("{}".utf8))?.0 == 400)
    #expect(m.handle("PUT", "memo/../../x", query: [:], body: Data("{}".utf8))?.0 == 400)
    #expect(m.handle("GET", "well/context", query: [:], body: nil)?.0 == 501, "a route no agent uses stays the hub's")
    #expect(m.handle("PUT", "omega/data/domains/../x/source/goals.md", query: [:], body: Data("x".utf8), headers: ["X-Base-SHA256": "none"])?.0 == 400)
    #expect(m.handle("PUT", "memo-undo/..%2F..%2Fx", query: [:], body: nil)?.0 == 400)
    #expect(m.handle("PUT", "crm/move", query: [:], body: Data("not json".utf8))?.0 == 400)
    #expect(MacHub.keysSingleLine("---\nname: Ken Lee\nattributes:\n---\n") == false)
    #expect(MacHub.keysSingleLine("---\nname: Ken Lee\nattributes: {\"Care\":\"yes\"}\n---\n"))
}

// The routes the newer tools and Undo use, on a Mac (the hub's omega_bundle, omega_write, crm_names,
// crm_move and undo_memo, done on the vault's files).

private func put(_ vault: URL, _ rel: String, _ text: String) throws {
    let url = vault.appending(path: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func sha(_ s: String) -> String { Filing.sha256(Data(s.utf8)) }

@Test func jotNoteUndoArchivesNeverDeletes() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    let done = try await GlyphAgent.jot.call("new_note", json: #"{"text":"Dreamt of Acme","tags":["Dreams"]}"#, hub: hub)
    let undo = try #require(done.first?.card["undo"] as? [String: Any])
    let back = try #require(Done.Undo(card: undo))
    #expect(back == .jotArchive(stem: "2026-10-30 08-10-00"))
    #expect(await hub.undo(back))
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: vault.appending(path: "data/domains/notes/source/jot/2026-10-30 08-10-00.md").path))
    #expect(!fm.fileExists(atPath: vault.appending(path: "data/domains/dreams/source/jot/2026-10-30 08-10-00.md").path))
    let day = OmegaFormat.today(.now)
    #expect(text(vault, "data/domains/notes/source/jot/archived-\(day)/2026-10-30 08-10-00.md")?.contains("Dreamt of Acme") == true)
    #expect(text(vault, "data/domains/dreams/source/jot/archived-\(day)/2026-10-30 08-10-00.md")?.contains("original: notes/") == true)
    #expect(await hub.undo(back), "archived already counts")
    #expect(MacHub(vault: vault).handle("PUT", "memo-undo/2026-10-30 09-00-00", query: [:], body: nil)?.0 == 404)
    // A note in a domain that isn't Jot's copy stays where it is.
    try put(vault, "data/domains/career/source/jot/2026-10-30 07-00-00.md", "mine\n")
    try put(vault, "data/domains/notes/source/jot/2026-10-30 07-00-00.md", "memo\n")
    #expect(MacHub(vault: vault).undoMemo("2026-10-30 07-00-00"))
    #expect(text(vault, "data/domains/career/source/jot/2026-10-30 07-00-00.md") == "mine\n")
}

@Test func omegaGoalAddedAndUndone() async throws {
    let vault = try tempVault(["notes", "health"]), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    try put(vault, "data/domains/health/ideal-state.md", "# Health\n")
    try put(vault, "data/domains/health/manifest.json", #"{"identity":{"label":"Body and Health"}}"#)
    let m = MacHub(vault: vault)
    let got = try #require(m.handle("GET", "omega", query: [:], body: nil))
    let bundle = try #require(try JSONSerialization.jsonObject(with: got.1) as? [String: Any])
    #expect((bundle["labels"] as? [String: String]) == ["health": "Body and Health"], "notes has no manifest or ideal state: no life domain")
    #expect((bundle["files"] as? [String: String])?["data/domains/health/ideal-state.md"] == "# Health\n")

    let done = try await GlyphAgent.omega.call("add_goal", json: #"{"domain":"health","title":"swim a mile","due":""}"#, hub: hub)
    let card = try #require(done.first?.card)
    #expect(card["status"] as? String == "done", "\(card)")
    let goals = try #require(text(vault, "data/domains/health/source/goals.md"))
    #expect(goals.contains("Swim a mile"))
    let goalUndo = try #require(card["undo"] as? [String: Any])
    let back = try #require(Done.Undo(card: goalUndo))
    #expect(await hub.undo(back))
    #expect(text(vault, "data/domains/health/source/goals.md") == "", "a new file is put back empty, never deleted")

    // Over a stale base: 409; notes is no life domain: 400.
    try put(vault, "build/compass.md", "# Compass\n")
    #expect(m.omegaWrite("build/compass.md", Data("x".utf8), base: sha("old")) == 409)
    #expect(m.omegaWrite("data/domains/notes/source/goals.md", Data("x".utf8), base: "none") == 400)
    // The Compass keeps what it said before.
    #expect(m.handle("PUT", "omega/build/compass.md", query: [:], body: Data("# Compass\n\n## Vision\n".utf8), headers: ["X-Base-SHA256": sha("# Compass\n")])?.0 == 204)
    let versions = try FileManager.default.contentsOfDirectory(atPath: vault.appending(path: "build/compass.versions").path)
    #expect(versions.count == 1 && text(vault, "build/compass.versions/\(versions[0])") == "# Compass\n")
}

@Test func crmRecordAddedListedAndUndone() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    try put(vault, "data/entities/orgs/acme/entity.md", "---\nid: org/acme\nname: \"Acme\"\naliases: [\"Acme Corp\"]\n---\n")
    try put(vault, "data/entities/people/_merged/x/entity.md", "---\n---\n")
    let done = try await GlyphAgent.crm.call("add_record", json: #"{"kind":"person","name":"Ken Lee","note":"Met at the Springfield office","linkTo":["Acme"],"linkAs":["works at"]}"#, hub: hub)
    let card = try #require(done.first?.card)
    #expect(card["status"] as? String == "done", "\(card)")
    let page = try #require(text(vault, "data/entities/people/ken-lee/entity.md"))
    #expect(page.contains("org/acme") && page.contains("Met at the Springfield office"))

    let listed = try #require(MacHub(vault: vault).handle("GET", "crm/names", query: [:], body: nil))
    let names = try #require(try JSONSerialization.jsonObject(with: listed.1) as? [[String: Any]])
    #expect(names.map { $0["name"] as? String } == ["Ken Lee", "Acme"], "people first, as the hub lists them")
    #expect(names[1]["aliases"] as? [String] == ["Acme Corp"] && names[1]["id"] as? String == "org/acme" && names[1]["kind"] as? String == "org")

    // A note on the one page "Ken" fits now.
    let upd = try await GlyphAgent.crm.call("update_record", json: #"{"name":"Ken","note":"Likes tea","alias":"","key":"","value":""}"#, hub: hub)
    #expect(upd.first?.card["status"] as? String == "done")
    let updUndo = try #require(upd.first?.card["undo"] as? [String: Any])
    let back = try #require(Done.Undo(card: updUndo))
    #expect(await hub.undo(back))
    #expect(text(vault, "data/entities/people/ken-lee/entity.md") == page)

    let addUndo = try #require(card["undo"] as? [String: Any])
    let unmake = try #require(Done.Undo(card: addUndo))
    #expect(await hub.undo(unmake))
    #expect(!FileManager.default.fileExists(atPath: vault.appending(path: "data/entities/people/ken-lee").path))
    guard case .crmUnmake(_, let to) = unmake else { Issue.record("not an unmake"); return }
    #expect(text(vault, to + "/entity.md") == page, "kept in data/apps/crm/undone")
}

@Test func crmMovesOnlyWhatTheHubMoves() throws {
    let vault = try tempVault()
    defer { try? FileManager.default.removeItem(at: vault) }
    try put(vault, "data/entities/people/ken-lee/entity.md", "x")
    try put(vault, "data/entities/people/ken-park/entity.md", "y")
    try put(vault, "data/domains/notes/source/crm/2026-10-28 09-00-00.md", "n")
    let m = MacHub(vault: vault)
    func move(_ a: String, _ b: String) -> Int? { m.handle("PUT", "crm/move", query: [:], body: try? JSONSerialization.data(withJSONObject: ["from": a, "to": b]))?.0 }
    #expect(move("data/entities/people/ken-lee", "data/entities/_merged/people/ken-lee") == 204)
    #expect(move("data/entities/_merged/people/ken-lee", "data/entities/people/ken-lee") == 204)
    #expect(move("data/domains/notes/source/crm/2026-10-28 09-00-00.md", "data/apps/crm/undone/2026-10-28 09-00-00.md") == 204)
    #expect(move("data/entities/people/ken-park", "data/apps/crm/undone/people/ken-park-1") == 204)
    #expect(move("data/entities/people/ken-lee", "data/apps/crm/undone/places/ken-lee") == 403)
    #expect(move("data/entities/people/ken-lee", "data/domains/x") == 403)
    #expect(move("data/entities/people/nobody", "data/entities/_merged/people/nobody") == 409)
    #expect(move("data/domains/notes/source/jot/a.md", "data/apps/crm/undone/a.md") == 403)
}

// Preferences (Glyph Omega's ## Preferences): each agent is told the ones in its scopes; Omega adds and archives them;
// any agent proposes one, which waits for a yes.
@Test func agentsReadScopedPreferences() async throws {
    var compass = "# Compass\n"
    compass = OmegaFormat.addPreference(compass, words: "No emojis", scope: "writing").0
    compass = OmegaFormat.addPreference(compass, words: "Coffee before nine", scope: "food").0
    compass = OmegaFormat.addPreference(compass, words: "Alarms never before six", scope: "schedule", strong: true).0
    compass = OmegaFormat.addPreference(compass, words: "Short labels", scope: "design", proposed: true).0
    let prefs = OmegaFormat.preferences(compass)
    let well = GlyphAgent.well.instructions(with: prefs), time = GlyphAgent.time.instructions(with: prefs)
    #expect(well.hasPrefix(GlyphAgent.well.instructions))
    #expect(well.contains("- No emojis (writing)") && well.contains("- Coffee before nine (food)") && !well.contains("Alarms"))
    #expect(time.contains("- Alarms never before six (schedule, strong)") && !time.contains("Coffee"))
    #expect(!time.contains("Short labels"), "a proposal is not followed")
    #expect(GlyphAgent.omega.scoped(prefs).count == 3, "Omega reads them all")

    let vault = try tempVault(["notes"]), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    try put(vault, "build/compass.md", compass)
    #expect(await hub.preferenceText(for: "well").contains("- Coffee before nine (food)"))
}

@Test func omegaAddsArchivesAndAgentsPropose() async throws {
    let vault = try tempVault(["notes"]), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    try put(vault, "build/compass.md", "# Compass\n")
    let added = try await GlyphAgent.omega.call("add_preference", json: #"{"text":"no emojis, drawn icons","scope":"writing","strong":true}"#, hub: hub)
    #expect(added.first?.card["status"] as? String == "done")
    #expect(text(vault, "build/compass.md")?.contains("- No emojis, drawn icons ~id:p-") == true)
    #expect(text(vault, "build/compass.md")?.contains("~scope:writing ~strength:strong") == true)

    let offered = try await GlyphAgent.jot.call("propose_preference", json: #"{"text":"Short labels","scope":"design"}"#, hub: hub)
    #expect(offered.first?.card["status"] as? String == "review" && offered.first?.line == "Save as a preference? Short labels")
    #expect(await hub.preferences().map(\.title) == ["No emojis, drawn icons"], "the proposal waits for a yes")

    let off = try await GlyphAgent.omega.call("archive_preference", json: #"{"preference":"the emojis one"}"#, hub: hub)
    #expect(off.first?.ok == true)
    #expect(await hub.preferences().isEmpty)
    #expect(OmegaFormat.compass(text(vault, "build/compass.md") ?? "").preferences.count == 2, "archived, never deleted")
}

@Test func jotFileNoteCrossLinksAndUndoes() async throws {
    let vault = try tempVault(), hub = macHub(vault)
    defer { try? FileManager.default.removeItem(at: vault) }
    let note = "data/domains/notes/source/jot/2026-10-29 09-00-00.md"
    try put(vault, note, "---\ndate: 2026-10-29T09:00:00\ntags: []\nentities: [person/ken-lee]\nlinks: [person/ken-lee]\n---\n\nInterview with Acme went well, Ken asked about latency.\n")
    try put(vault, "data/domains/notes/source/jot/2026-10-29 10-00-00.md", "---\ntags: []\n---\n\nBuy milk.\n")
    try put(vault, "data/domains/career/memory/current/applications/2026-10-01-acme-field-engineer/notes.md", "x")
    try put(vault, "data/entities/orgs/acme/entity.md", "---\nname: Acme\nkind: org\n---\n")
    try put(vault, "data/apps/jot/places.json", #"[{"path":"data/domains/content/source/sayings","label":"Sayings","kind":"sayings"}]"#)

    let places = CrossLink.places(in: vault)
    #expect(places.contains { $0.kind == "application" && $0.label == "Acme field engineer" })
    #expect(places.contains { $0.kind == "org" && $0.label == "Acme" })
    #expect(places.contains { $0.label == "Sayings" })
    #expect(CrossLink.match("Acme application", in: places)?.kind == "application")
    #expect(CrossLink.match("sayings", in: places)?.path == "data/domains/content/source/sayings")

    let done = try await GlyphAgent.jot.call("file_note", json: #"{"note":"interview with acme","place":"my Acme application"}"#, hub: hub)
    let d = try #require(done.first)
    #expect(d.ok && d.line.contains("Acme"))
    let app = "data/domains/career/memory/current/applications/2026-10-01-acme-field-engineer"
    let list = try #require(text(vault, app + "/linked-notes.md"))
    #expect(list.contains("[Interview with Acme went well, Ken asked about latency.](<../../../../../notes/source/jot/2026-10-29 09-00-00.md>)"))
    let raw = try #require(text(vault, note))
    #expect(raw.contains("links: [person/ken-lee, \(app)]") && raw.contains("entities: [person/ken-lee]"))
    #expect(raw.hasSuffix("Interview with Acme went well, Ken asked about latency.\n"))
    // Twice is once.
    #expect(try CrossLink.file(note: note, title: "x", to: app, in: vault) == false)

    let card = try #require(d.card["undo"] as? [String: Any])
    let back = try #require(Done.Undo(card: card))
    #expect(await hub.undo(back))
    #expect(text(vault, app + "/linked-notes.md")?.contains("09-00-00") == false)
    #expect(text(vault, note)?.contains("links: [person/ken-lee]\n") == true)
    // An unknown place files nothing.
    #expect(try await GlyphAgent.jot.call("file_note", json: #"{"note":"","place":"Nowhere Inc"}"#, hub: hub).first?.ok == false)
}
