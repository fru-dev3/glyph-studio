import Foundation
import FoundationModels
import GlyphVault

/// Glyph Jot's agent: notes, with tags (a dream is tagged Dreams, so it also lands in the dreams domain).
extension GlyphAgent {
    public static let jot = GlyphAgent(
        id: "jot", name: "Jot", color: "8A4FC8",
        instructions: "You are Glyph Jot's agent. Save the job as one note with new_note, in the person's words without lead-ins like 'jot down that'. Tag a dream Dreams. To file a note somewhere (\"file this under Acme\", \"put that note in my Acme application\"), use file_note: the note stays where it is and the place links to it.",
        tools: { hub, ledger in [JotNewNote(hub: hub, ledger: ledger), JotFileNote(hub: hub, ledger: ledger)] },
        fallback: { job, hub in await hub.newNote(job.instruction, tags: job.tag == "dream" ? ["Dreams"] : []) })
}

public struct JotNewNote: Tool {
    public let name = "new_note"
    public let description = "Save a new note in Glyph Jot, with tags."
    @Generable public struct Arguments {
        @Guide(description: "The note, as said.") public var text: String
        @Guide(description: "Tags, like Dreams for a dream. Empty when none.") public var tags: [String]
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.newNote(a.text, tags: a.tags); await ledger.add(d); return d.line
    }
}

/// Files a note to a place (an application folder, a CRM page, a project, a domain...) without moving it.
public struct JotFileNote: Tool {
    public let name = "file_note"
    public let description = "File a Glyph Jot note under a place: a company or job application, a person or org page, a project, a domain, or another place the vault lists. The note is not moved; the place links to it."
    @Generable public struct Arguments {
        @Guide(description: "Which note: a few of its words or its file name. Empty for the latest note.") public var note: String
        @Guide(description: "Where to file it, as said: a company, application, person, org, project or domain name.") public var place: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.fileNote(a.note, to: a.place); await ledger.add(d); return d.line
    }
}

extension Hub {
    /// `PUT jot/file` {note, place}: the hub finds the note and the place and cross-links them (CrossLink).
    public func fileNote(_ note: String, to place: String) async -> Done {
        guard let (code, data) = await send("PUT", "jot/file", body: json(["note": note, "place": place])) else { return unreachable("jot", place) }
        guard code == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let file = o["note"] as? String, let path = o["place"] as? String else {
            return Done(agent: "jot", line: code == 404 ? "Couldn't find that note or a place called \(place)" : "Jot didn't file it (\(code))", title: place, ok: false)
        }
        let label = o["label"] as? String ?? place, title = o["title"] as? String ?? file
        return Done(agent: "jot", line: "Filed under \(label): \(title)", title: title, ok: true, undo: .jotUnfile(note: file, place: path), link: URL(string: "jot://"))
    }

    /// Where a note could go, read by Glyph Core Intelligence (`POST understand` with kind "file"): up to three
    /// places from the vault's own list, each with its reason. Nil when the hub can't be reached.
    public func suggestPlaces(for text: String) async -> (places: [FilePlace], tags: [String])? {
        guard let (code, data) = await send("POST", "understand", body: json(["surface": "jot", "kind": "file", "text": String(text.prefix(4000))])),
              code == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = o["places"], let d = try? JSONSerialization.data(withJSONObject: raw),
              let places = try? JSONDecoder().decode([FilePlace].self, from: d) else { return nil }
        // The tags are his own vocabulary, read from the notes he has already tagged.
        return (places, Array(((o["tags"] as? [String]) ?? []).prefix(3)))
    }

    /// Jot's own memo (`PUT /memo/<stem>`, the body Glyph on the iPhone sends). The stem is its id.
    public func newNote(_ text: String, tags: [String]) async -> Done {
        let tags = tags.filter { !$0.isEmpty }
        let stem = fileStem(now())
        let code = await put("memo/\(stem)", body: JotMemo.body(text: text, tags: tags, device: device))
        if code == nil { return kept("jot", text) }
        guard code == 204 else { return Done(agent: "jot", line: "Jot didn't take it (\(code!)): \(text)", title: text, ok: false) }
        return Done(agent: "jot", line: "Saved in Jot\(tags.isEmpty ? "" : " as \(tags.joined(separator: ", "))"): \(text)", title: text, ok: true,
                    undo: .jotArchive(stem: stem), link: URL(string: "jot://"))
    }
}
