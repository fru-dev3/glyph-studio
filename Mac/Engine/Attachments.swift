import Foundation

/// Files you attach to a message (photos, documents, a pasted image): saved as plain files in your
/// vault next to the agent's domain, `data/domains/<agent>/source/attachments/<yyyy-MM-dd>/`, and
/// named in the message so the agent opens them. The engine has no verb for a file, so this is the one
/// place Studio writes into your vault itself: new files only, only in that folder, never an overwrite.
/// (Threads live in `memory/threads/`, which the engine owns; attachments stay out of it.)
enum Attachments {
    static let maxBytes = 20_000_000

    struct Saved: Hashable { var path: String; var name: String } // path relative to the vault

    static func folder(_ agent: String, root: URL = Vault.root, day: Date = AppClock.now) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return root.appending(path: "data/domains/\(safe(agent))/source/attachments/\(f.string(from: day))")
    }

    static func save(_ data: Data, name: String, agent: String, root: URL = Vault.root, now: Date = AppClock.now) throws -> Saved {
        guard !data.isEmpty, data.count <= maxBytes else { throw EngineError(message: "That file is too big to attach (20 MB at most).") }
        let dir = folder(agent, root: root, day: now)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = DateFormatter(); t.locale = Locale(identifier: "en_US_POSIX"); t.dateFormat = "HHmmss"
        var base = "\(t.string(from: now))-\(safe(name))"
        var url = dir.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
            base = "\(stem)-\(n).\(ext)"; url = dir.appending(path: base); n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return Saved(path: Vault.relative(url, root: root), name: name)
    }

    /// A file name without paths or odd characters ("Screen Shot 1.png" stays readable).
    static func safe(_ s: String) -> String {
        let last = (s as NSString).lastPathComponent
        let cleaned = last.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0) ? Character($0) : "-" }
        let out = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return out.isEmpty ? "file" : String(out.prefix(80))
    }

    /// Only files Studio attached can be read back over the iPhone link.
    static func isAttachment(_ rel: String) -> Bool {
        rel.range(of: #"^data/domains/[\w.-]+/source/attachments/\d{4}-\d{2}-\d{2}/[^/]+$"#, options: .regularExpression) != nil && !rel.contains("..")
    }

    /// The name you gave it, without the time Studio put in front ("091500-receipt.png" shows "receipt.png").
    static func shownName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.range(of: #"^\d{6}-"#, options: .regularExpression).map { String(last[$0.upperBound...]) } ?? last
    }

    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains((path as NSString).pathExtension.lowercased())
    }
}
