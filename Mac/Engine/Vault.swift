import Foundation

/// The vault Studio works on. Two modes:
/// - demo: Studio's own copy of the made-up demo vault in Application Support (tests and screenshots);
///   the engine gets its own config folder there and the owner's real vault is refused.
/// - yours (the default when one is set up): the vault in ~/.prevail/config.json (vaultPath), the one every Glyph app uses. Studio only
///   reads its files; every write goes through Glyph Engine (`prevail chat`, `prevail tell`), whose
///   ledgers keep a receipt of each one.
/// STUDIO_VAULT (tests) pins a folder and implies demo rules.
enum Vault {
    enum Mode: String { case demo, yours }

    static var mode: Mode {
        // An explicit mode wins, so a test can pin a throwaway vault path (STUDIO_VAULT) and still run
        // under your-vault rules: that is the only mode where `prepare` does not re-seed the demo, and
        // so the only one where the owner's invariant (take the vault away and nothing works) can be proved.
        if let m = Engine.env["STUDIO_VAULT_MODE"].flatMap(Mode.init(rawValue:)) { return m }
        if Engine.env["STUDIO_VAULT"] != nil { return .demo }
        let s = try? String(contentsOf: StudioPaths.support.appending(path: "vault-mode.txt"), encoding: .utf8)
        if let m = s.flatMap({ Mode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return m }
        // Unchosen: your vault when one is set up (Studio is for it), the demo otherwise. Unit tests always demo.
        if Engine.env["XCTestConfigurationFilePath"] != nil || Engine.env["STUDIO_SCRIPT"] != nil { return .demo }
        return StudioPaths.realVault != nil ? .yours : .demo
    }

    /// Switches modes. Choosing yours needs a vault in ~/.prevail/config.json.
    static func set(mode: Mode) throws {
        if mode == .yours, StudioPaths.realVault == nil {
            throw EngineError(message: "No vault is set up yet. Glyph Bot reads the vault path from ~/.prevail/config.json.")
        }
        try FileManager.default.createDirectory(at: StudioPaths.support, withIntermediateDirectories: true)
        try mode.rawValue.write(to: StudioPaths.support.appending(path: "vault-mode.txt"), atomically: true, encoding: .utf8)
    }

    static var isDemo: Bool { mode == .demo }

    static var root: URL {
        if let path = Engine.env["STUDIO_VAULT"] { return URL(filePath: path) }
        if mode == .yours, let real = StudioPaths.realVault { return real }
        return StudioPaths.support.appending(path: "Vault")
    }

    /// Studio's own hand writes into vault files (teammate drafts, board edits) happen only in the demo
    /// vault. In yours, writes go through Glyph Engine so each one leaves a receipt.
    static var handWritable: Bool { isDemo }

    /// Copies the bundled demo vault into place when there is none yet (demo mode only).
    static func prepare() throws {
        guard isDemo else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appending(path: "data").path) else { return }
        guard let bundled = Bundle.main.url(forResource: "DemoVault", withExtension: nil) else { return }
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.copyItem(at: bundled, to: root)
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: root.appending(path: "data").path) }
    static var encrypted: Bool { FileManager.default.fileExists(atPath: root.appending(path: ".prevail-encrypted").path) }

    static var build: URL { root.appending(path: "build") }
    static func domain(_ slug: String) -> URL { root.appending(path: "data/domains/\(slug)") }

    /// A domain's task board: `memory/tasks.md` on a v4 domain, else `_tasks.md` (VAULT.md).
    static func tasksFile(_ slug: String) -> URL {
        let dir = domain(slug)
        let v4 = dir.appending(path: "memory/tasks.md")
        return FileManager.default.fileExists(atPath: v4.path) || !FileManager.default.fileExists(atPath: dir.appending(path: "_tasks.md").path)
            && FileManager.default.fileExists(atPath: dir.appending(path: "memory").path) ? v4 : dir.appending(path: "_tasks.md")
    }

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// A path inside the vault, as shown to people ("data/apps/time/sessions/2026-10.laptop.jsonl").
    static func relative(_ url: URL, root: URL = Vault.root) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }
}
