import Foundation

/// A write the vault refused. The message is ready to show.
public struct VaultError: LocalizedError, Equatable, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }

    static let notConversation = VaultError("Not a conversation.")
    static let nameNeeded = VaultError("A name is needed.")
}

// Writes mirror Memosa's store.rs. Every file goes down through a temp file, fsync and a
// rename, so a reader (or Memosa, or git) never sees half a file. Nothing is cached:
// each write reads what is on disk first.
extension Vault {
    /// Makes the vault folder and its `.memosa/index` if missing.
    public func ensure() throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".memosa/index"), withIntermediateDirectories: true)
    }

    /// A new conversation folder `<folder>/YYYY-MM-DD-kebab-title` (`-2`, `-3` when taken)
    /// with its `meta.json`. Returns the new meta; its `id` is the path.
    @discardableResult
    public func createConversation(in folder: String, title: String, created: Date = .now, device: String? = ThisDevice.name) throws -> Conversation {
        let stamp = Vault.iso(created)
        let id = Vault.join(folder, uniqueSlug(in: folder, title: title, created: stamp))
        try FileManager.default.createDirectory(at: url(id), withIntermediateDirectories: true)
        var meta = Conversation(id: id, title: title, created: stamp)
        meta.device = device
        try write(meta)
        return meta
    }

    /// Writes `meta.json` at the conversation's `id`.
    public func write(_ meta: Conversation) throws {
        try Vault.atomicWrite(url(meta.id).appending(path: "meta.json"), meta.json.pretty)
        // notes.md says the same tags and entities in its front matter, so the Markdown alone
        // tells where a recording is filed. Its other lines stay.
        let notes = url(meta.id).appending(path: "notes.md")
        if let md = try? String(contentsOf: notes, encoding: .utf8), let fixed = Vault.frontMatter(md, set: [
            "people": meta.people, "tags": meta.tags, "entities": meta.links,
        ]), fixed != md {
            try Vault.atomicWrite(notes, fixed)
        }
    }

    /// `md` with these front matter lists set in place (a missing one added before the closing
    /// `---`; an empty `entities` left out). Nil when `md` has no front matter.
    static func frontMatter(_ md: String, set lists: [String: [String]]) -> String? {
        guard md.hasPrefix("---\n"), let end = md.dropFirst(4).range(of: "\n---") else { return nil }
        var head = md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for key in lists.keys.sorted() {
            let values = lists[key] ?? []
            let line = "\(key): [\(values.joined(separator: ", "))]"
            if let i = head.firstIndex(where: { $0.hasPrefix(key + ":") }) {
                if values.isEmpty && key == "entities" { head.remove(at: i) } else { head[i] = line }
            } else if !(values.isEmpty && key == "entities") {
                head.append(line)
            }
        }
        return "---\n" + head.joined(separator: "\n") + md[end.lowerBound...]
    }

    /// Writes `transcript.json` and the derived `transcript.txt`, and stamps `updated`.
    public func writeTranscript(_ transcript: Transcript, for id: String) throws {
        let dir = url(id)
        try Vault.atomicWrite(dir.appending(path: "transcript.json"), transcript.json.pretty)
        try Vault.atomicWrite(dir.appending(path: "transcript.txt"), transcript.plainText)
        try touch(id)
    }

    /// Writes `notes.md` (front matter from meta.json) and stamps `updated`.
    public func writeNotes(_ notes: Notes, for id: String) throws {
        let meta = try conversation(id)
        let md = notes.rendered(title: meta.title, date: String(meta.created.prefix(10)), people: meta.people, tags: meta.tags, entities: meta.links)
        try Vault.atomicWrite(url(id).appending(path: "notes.md"), md)
        try touch(id)
    }

    /// Checks or unchecks the action item whose line contains `text`, rewriting only that
    /// line. Returns false when no such item exists.
    @discardableResult
    public func setTask(_ id: String, text: String, done: Bool) throws -> Bool {
        let file = url(id).appending(path: "notes.md")
        guard let md = Notes.toggling(try String(contentsOf: file, encoding: .utf8), text: text, done: done) else { return false }
        try Vault.atomicWrite(file, md)
        return true
    }

    /// Makes a folder (and its parents). The vault root itself is refused.
    public func createFolder(_ path: String) throws {
        let dir = url(path)
        guard dir.standardizedFileURL != root.standardizedFileURL else { throw VaultError("Give the folder a name.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Moves a conversation into `folder` ("" is the vault root). Returns its new id.
    @discardableResult
    public func move(_ id: String, to folder: String) throws -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let newId = Vault.join(Vault.clean(folder), name)
        if newId == Vault.clean(id) { return newId }
        let dest = url(newId)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw VaultError("That folder already has a conversation with this name.")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(id), to: dest)
        var meta = try conversation(newId)
        meta.id = newId
        try write(meta)
        return newId
    }

    /// Retitles a conversation and re-slugs its folder. Only a case change keeps the
    /// folder. Returns the new id.
    @discardableResult
    public func rename(_ id: String, title: String) throws -> String {
        let id = Vault.clean(id)
        let folder = Vault.parent(id)
        let created = try conversation(id).created
        let newId = Vault.join(folder, Vault.slug(title, created: created)) == id
            ? id : Vault.join(folder, uniqueSlug(in: folder, title: title, created: created))
        if newId != id { try FileManager.default.moveItem(at: url(id), to: url(newId)) }
        var meta = try conversation(newId)
        meta.id = newId
        meta.title = title
        try write(meta)
        return newId
    }

    /// Moves a conversation to `.memosa/trash/` inside the vault (never deletes). The
    /// trashed folder is named after its path, `Work__Acme__2026-10-20-sync`, `-2` when taken.
    public func trash(_ id: String) throws {
        let src = url(id)
        guard src.standardizedFileURL != root.standardizedFileURL,
              FileManager.default.fileExists(atPath: src.appending(path: "meta.json").path) else { throw VaultError.notConversation }
        let bin = root.appending(path: ".memosa/trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let base = Vault.clean(id).replacingOccurrences(of: "/", with: "__")
        var dest = bin.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = bin.appending(path: "\(base)-\(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: src, to: dest)
    }

    // MARK: helpers

    func touch(_ id: String) throws {
        guard var meta = try? conversation(id) else { return }
        meta.updated = Vault.iso(now())
        try write(meta)
    }

    func uniqueSlug(in folder: String, title: String, created: String) -> String {
        let base = Vault.slug(title, created: created)
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: url(Vault.join(folder, candidate)).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// `YYYY-MM-DD-kebab-title` from an ISO stamp: letters and digits lower-cased, every
    /// other run of characters one `-`. A title with neither is just the date.
    static func slug(_ title: String, created: String) -> String {
        let date = created.count >= 10 ? String(created.prefix(10)) : "undated"
        var kebab = ""
        var dash = false
        for u in title.unicodeScalars {
            if u.properties.isAlphabetic || u.properties.numericType != nil {
                kebab += String(u).lowercased()
                dash = false
            } else if !dash {
                kebab += "-"
                dash = true
            }
        }
        let trimmed = kebab.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? date : "\(date)-\(trimmed)"
    }

    /// UTC ISO 8601 to the second, `2026-10-25T09:00:00Z`.
    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).timeZone(separator: .omitted))
    }

    /// A vault path without empty, `.` or `..` parts.
    static func clean(_ rel: String) -> String {
        rel.split(whereSeparator: { $0 == "/" || $0 == "\\" }).filter { $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    static func join(_ folder: String, _ name: String) -> String {
        let f = clean(folder)
        return f.isEmpty ? name : f + "/" + name
    }

    static func parent(_ id: String) -> String {
        guard let i = id.lastIndex(of: "/") else { return "" }
        return String(id[..<i])
    }

    static func atomicWrite(_ file: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw VaultError("Can't write \(file.lastPathComponent).") }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // rename(2) replaces the target in one step; FileManager's move refuses an existing file.
        guard Foundation.rename(tmp.path, file.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }
}
