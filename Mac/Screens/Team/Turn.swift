import Foundation

/// One chat turn's plumbing, shared by the Mac chat and the iPhone link: what the agent was given to
/// read (numbered, so the reply can cite it), what the reply asks to save, and the save itself.
///
/// The excerpts ride in the message after a marker, so the thread the engine keeps in the vault
/// records exactly what the agent saw; the chat hides that part and shows it as "Read" instead.
/// A reply asks to save with lines `SAVE: <plain words>`; nothing is saved until you say Save, and
/// then only through `prevail tell` (filed by the engine, a receipt in its ledger, Undo-able).
enum Turn {
    static let marker = "\n\n---\nGlyph Bot gave you these to read"

    /// What to say while a turn has been quiet for `seconds`.
    static func slowHint(_ seconds: TimeInterval) -> String {
        seconds < 20 ? "Working on your Mac" :
            "Still working on your Mac. If macOS is asking Glyph Bot for access (Documents, files), choose Allow there."
    }

    static func message(_ text: String, excerpts: [SourceExcerpt], attachments: [String] = [], root: URL = Vault.root) -> String {
        var s = text + marker
        if excerpts.isEmpty {
            s += " (none matched this question)."
        } else {
            s += ". Cite them by number, like [1], when you use them; say plainly when they don't answer the question.\n"
            for e in excerpts { s += "\n[\(e.n)] \(e.title) · \(e.path)\n\(e.text)\n" }
        }
        s += "\nTo save something to the vault (a task, a fact, a note), end your reply with one line per item: SAVE: <it, in plain words>. Glyph Bot asks before saving anything."
        if !attachments.isEmpty {
            s += "\n\nThe person attached these files; open and read them (images too) before you answer:"
            for a in attachments { s += "\n\(attachedPrefix)\(a) (full path: \(root.appending(path: a).path))" }
        }
        return s
    }

    /// Whether a reply asks back rather than answers, so the iPhone can show it as a question (GlyphChat's
    /// `ask`). The Mac decides, because it has the reply and what it wants to save; the phone never guesses.
    /// One short question and nothing to save is an ask; a paragraph that happens to end in a question mark
    /// is not.
    static func kind(_ reply: String, saves: [String]) -> String {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return saves.isEmpty && t.hasSuffix("?") && !t.contains("\n\n") ? "ask" : "answer"
    }

    static let attachedPrefix = "ATTACHED: "

    /// The files attached to a stored user turn (vault-relative paths).
    static func attachments(in stored: String) -> [String] {
        stored.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(attachedPrefix) else { return nil }
            let rest = line.dropFirst(attachedPrefix.count)
            return String(rest.components(separatedBy: " (full path:").first ?? String(rest))
        }
    }

    /// A user turn as stored: what was typed, and what was read with it.
    static func split(_ stored: String) -> (text: String, excerpts: [SourceExcerpt]) {
        guard let r = stored.range(of: marker) else { return (stored, []) }
        let text = String(stored[..<r.lowerBound])
        var out: [SourceExcerpt] = []
        var current: SourceExcerpt?
        for line in stored[r.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let head = header(line) {
                if let c = current { out.append(c) }
                current = head
            } else if line.hasPrefix("To save something to the vault") {
                break
            } else if current != nil {
                current!.text += (current!.text.isEmpty ? "" : "\n") + line
            }
        }
        if let c = current { out.append(c) }
        return (text, out.map { var e = $0; e.text = e.text.trimmingCharacters(in: .whitespacesAndNewlines); return e })
    }

    /// "[2] Glyph Time, hours by project · data/apps/time/sessions"
    static func header(_ line: String) -> SourceExcerpt? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), let n = Int(line[line.index(after: line.startIndex)..<close]),
              let dot = line.range(of: " · ", options: .backwards) else { return nil }
        let title = line[line.index(close, offsetBy: 2)..<dot.lowerBound]
        let path = String(line[dot.upperBound...])
        return SourceExcerpt(n: n, source: source(of: path), title: String(title), path: path, text: "")
    }

    static func source(of path: String) -> SourceID {
        SourceID.allCases.first { $0 != .vault && path.hasPrefix($0.folder) } ?? .vault
    }

    /// The reply without its SAVE lines, and those lines.
    static func saves(in reply: String) -> (text: String, saves: [String]) {
        var keep: [String] = [], saves: [String] = []
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let bare = t.hasPrefix("- ") ? String(t.dropFirst(2)) : t
            if bare.uppercased().hasPrefix("SAVE:") {
                let item = bare.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { saves.append(item) }
            } else { keep.append(String(line)) }
        }
        return (keep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), saves)
    }

    /// The citation numbers a reply uses ("[1]", "[2, 3]").
    static func cited(in reply: String) -> Set<Int> {
        var out: Set<Int> = []
        var i = reply.startIndex
        while let open = reply[i...].firstIndex(of: "[") {
            guard let close = reply[open...].firstIndex(of: "]") else { break }
            for part in reply[reply.index(after: open)..<close].split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)) { out.insert(n) }
            }
            i = reply.index(after: close)
        }
        return out
    }

    /// What the engine filed for a save: its receipt (`prevail tell --json`).
    struct Told: Decodable, Equatable, Hashable {
        var id: String
        var kind: String
        var text: String
        var domain: String
        var `where`: String
        var file: String?
    }
    struct TellReply: Decodable { var ok: Bool?; var told: Told?; var reply: String? }

    /// Saves one item through the engine. The chief of staff (General) lets the engine find the owner.
    static func save(_ item: String, agent: String) async throws -> Told {
        var args = ["tell", item, "--surface", "desktop"]
        if agent != AppModel.chiefID { args += ["--domain", agent] }
        let r = try await Engine.json(args, as: TellReply.self)
        guard let t = r.told else { throw EngineError(message: "Glyph Engine didn't say where it filed that.") }
        return t
    }

    static func undo(_ told: Told) async throws {
        _ = try await Engine.run(["tell", "undo", told.id, "--json"])
    }
}
