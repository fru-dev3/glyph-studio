import Foundation
import os

let studioLog = Logger(subsystem: "dev.fru.studio", category: "app")

/// What the engine said when a command failed: `{ok:false,error,code}` on stdout, or stderr's tail.
struct EngineError: LocalizedError {
    var message: String
    var code: String?
    var errorDescription: String? { message }
}

/// The Glyph Engine (`prevail`), spawned once per command. Studio keeps it apart from Glyph:
/// its own config folder (so the engine never falls back to the owner's real vault) and its own
/// vault. `--vault` goes both before and after the verb, because the engine honours it in
/// different positions for different verbs.
///
/// Test mode: with STUDIO_FIXTURES set, a verb whose fixture exists (`<verb words joined by ->.json`,
/// `chat.ndjson` for streams) is answered from the file instead of the engine, and every call is
/// appended to `<fixtures>/calls.log`, so UI tests are deterministic and can assert what was asked.
enum Engine {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The engine inside Glyph Bot.app; STUDIO_ENGINE overrides; then the installed Glyph Bot, then the old Glyph Studio.
    static var binary: URL {
        if let path = env["STUDIO_ENGINE"] { return URL(filePath: path) }
        let own = Bundle.main.bundleURL.appending(path: "Contents/MacOS/prevail")
        if FileManager.default.isExecutableFile(atPath: own.path) { return own }
        let installed = URL(filePath: "/Applications/Glyph Bot.app/Contents/MacOS/prevail")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        return URL(filePath: "/Applications/Glyph Studio.app/Contents/MacOS/prevail")  // the old Prevail desktop
    }

    static var fixtures: URL? { env["STUDIO_FIXTURES"].map { URL(filePath: $0) } }

    /// Runs `prevail --vault V <args> --json --vault V` and decodes what it prints.
    static func json<T: Decodable>(_ args: [String], stdin: Data? = nil, as type: T.Type = T.self) async throws -> T {
        let out = try await run(args.contains("--json") ? args : args + ["--json"], stdin: stdin)
        do { return try JSONDecoder().decode(T.self, from: out) } catch {
            studioLog.error("engine: \(args.joined(separator: " "), privacy: .public) decode failed: \(error.localizedDescription, privacy: .public)")
            throw EngineError(message: "The engine answered \(args.prefix(2).joined(separator: " ")) in a shape Glyph Bot doesn't read.")
        }
    }

    /// Runs a command and returns stdout; a non-zero exit becomes an EngineError.
    /// Output goes to temp files, not pipes, so a chatty command can't fill a pipe and hang.
    static func run(_ args: [String], stdin: Data? = nil) async throws -> Data {
        record(args, stdin: stdin)
        if let fx = fixture(for: args) { return fx }
        let dir = FileManager.default.temporaryDirectory.appending(path: "studio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appending(path: "out"), errURL = dir.appending(path: "err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = try process(args)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do {
                    try p.run()
                    if let stdin {
                        input.fileHandleForWriting.write(stdin)
                        try? input.fileHandleForWriting.close()
                    }
                } catch { c.resume(throwing: EngineError(message: "The engine didn't start: \(error.localizedDescription)")) }
            }
        } onCancel: { p.terminate() }
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        guard status == 0 else {
            if let e = try? JSONDecoder().decode(Failure.self, from: out), let message = e.error { throw EngineError(message: message, code: e.code) }
            let err = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
            throw EngineError(message: err.split(separator: "\n").suffix(3).joined(separator: "\n").nonEmpty ?? "The engine stopped (exit \(status)).")
        }
        return out
    }

    /// A long command whose stdout is NDJSON (chat, playbook runs): one line per element.
    /// Cancelling the consuming task stops the engine.
    static func lines(_ args: [String], stdin: Data? = nil) -> AsyncThrowingStream<String, Error> {
        record(args, stdin: stdin)
        if let fx = fixture(for: args, stream: true) {
            let lines = String(decoding: fx, as: UTF8.self).split(separator: "\n").map(String.init)
            let delay = Double(env["STUDIO_STREAM_DELAY_MS"] ?? "40") ?? 40
            return AsyncThrowingStream { c in
                let t = Task {
                    for l in lines where !l.isEmpty {
                        try? await Task.sleep(for: .milliseconds(delay))
                        if Task.isCancelled { break }
                        c.yield(l)
                    }
                    c.finish()
                }
                c.onTermination = { _ in t.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            let p: Process
            do { p = try process(args) } catch { continuation.finish(throwing: error); return }
            let out = Pipe(), err = Pipe(), input = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = stdin == nil ? FileHandle.nullDevice : input
            let errTail = Tail()
            err.fileHandleForReading.readabilityHandler = { errTail.add($0.availableData) }
            let reader = Task.detached {
                do {
                    for try await line in out.fileHandleForReading.bytes.lines where !line.isEmpty { continuation.yield(line) }
                } catch {}
                p.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 || p.terminationReason == .uncaughtSignal { continuation.finish() } else {
                    continuation.finish(throwing: EngineError(message: errTail.text.nonEmpty ?? "The engine stopped (exit \(p.terminationStatus))."))
                }
            }
            continuation.onTermination = { _ in
                if p.isRunning { p.terminate() }
                reader.cancel()
            }
            do {
                try p.run()
                if let stdin {
                    input.fileHandleForWriting.write(stdin)
                    try? input.fileHandleForWriting.close()
                }
            } catch { continuation.finish(throwing: EngineError(message: "The engine didn't start: \(error.localizedDescription)")) }
        }
    }

    // MARK: fixtures and the call log

    /// `chief show --json` reads `chief-show.json`; a stream reads `<verb>.ndjson`.
    static func fixtureName(_ args: [String], stream: Bool = false) -> String {
        let words = args.prefix { !$0.hasPrefix("-") }.prefix(2)
        return words.joined(separator: "-") + (stream ? ".ndjson" : ".json")
    }

    private static func fixture(for args: [String], stream: Bool = false) -> Data? {
        guard let fixtures else { return nil }
        return try? Data(contentsOf: fixtures.appending(path: fixtureName(args, stream: stream)))
    }

    private static let logLock = NSLock()
    private static func record(_ args: [String], stdin: Data?) {
        guard let fixtures else { return }
        var line = args.joined(separator: " ")
        if let stdin, let s = String(data: stdin, encoding: .utf8) { line += " <<< " + s.replacingOccurrences(of: "\n", with: " ") }
        logLock.withLock {
            let url = fixtures.appending(path: "calls.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
            else { try? Data((line + "\n").utf8).write(to: url) }
        }
    }

    // MARK: the spawn contract

    private static func process(_ args: [String]) throws -> Process {
        if Vault.isDemo {
            try StudioPaths.guardOwnVault()
            try StudioPaths.ensureEngineConfig()
        }
        let p = Process()
        p.executableURL = binary
        let vault = Vault.root.path
        p.arguments = ["--vault", vault] + args + ["--vault", vault]
        p.environment = environment
        p.currentDirectoryURL = Vault.root
        return p
    }

    static let searchPath = ["~/.local/bin", "~/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .map { NSString(string: $0).expandingTildeInPath }

    /// The parent's env minus anything secret-looking, a PATH that finds the model CLIs, the privacy
    /// flags (always explicit) and, for the demo vault, Studio's own engine config folder. On your
    /// vault the engine reads ~/.prevail as the installed Glyph Studio does, and gets the provider keys
    /// kept on disk in ~/.ai/env when local-only is off.
    static var environment: [String: String] {
        var e = env.filter { !isSecret($0.key) && !$0.key.hasPrefix("STUDIO_") }
        e["PATH"] = (searchPath + (e["PATH"]?.split(separator: ":").map(String.init) ?? [])).uniqued().joined(separator: ":")
        if Vault.isDemo { e["PREVAIL_CONFIG_DIR"] = StudioPaths.engineConfig.path } else { e.removeValue(forKey: "PREVAIL_CONFIG_DIR") }
        e["PREVAIL_VAULT_ROOT"] = Vault.root.path
        e["PREVAIL_VAULT_LOCK"] = Privacy.vaultLock ? "1" : "0"
        if Privacy.bunker { e["PREVAIL_BUNKER"] = "1" } else {
            e.removeValue(forKey: "PREVAIL_BUNKER")
            if !Vault.isDemo { for (k, v) in Keys.providerEnv() { e[k] = v } }
        }
        e.removeValue(forKey: "PREVAIL_HOME")
        if let home = env["STUDIO_ENGINE_HOME"] { e["HOME"] = home } // tests: the engine can't even find ~/.prevail
        return e
    }

    static func isSecret(_ key: String) -> Bool {
        let k = key.uppercased()
        return ["API_KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "PRIVATE_KEY"].contains { k.contains($0) }
    }

    private struct Failure: Decodable { var error: String?; var code: String? }

    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.withLock { data.append(d); if data.count > 8000 { data = data.suffix(4000) } } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: "\n") } }
    }
}

/// Where Studio keeps its own things. Never the owner's real vault or ~/.prevail.
enum StudioPaths {
    static var support: URL {
        if let p = Engine.env["STUDIO_SUPPORT"] { return URL(filePath: p) }
        return URL.homeDirectory.appending(path: "Library/Application Support/dev.fru.studio")
    }
    static var engineConfig: URL { support.appending(path: "engine") }

    /// The owner's real vault (from Glyph's config), which Studio must never use.
    static var realVault: URL? {
        let config = URL.homeDirectory.appending(path: ".prevail/config.json")
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["vaultPath"] as? String, !p.isEmpty else { return nil }
        return URL(filePath: NSString(string: p).expandingTildeInPath).standardizedFileURL
    }

    /// Refuses to start the engine on the owner's real vault or anything inside it.
    static func guardOwnVault(_ vault: URL = Vault.root, real: URL? = realVault) throws {
        guard let real else { return }
        let v = vault.standardizedFileURL.resolvingSymlinksInPath().path, r = real.resolvingSymlinksInPath().path
        if v == r || v.hasPrefix(r + "/") { throw EngineError(message: "Glyph Bot won't open the Glyph vault. It keeps to its own.") }
    }

    /// The engine falls back to config.json's vaultPath when a verb ignores --vault, so point it at Studio's vault.
    static func ensureEngineConfig() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: engineConfig, withIntermediateDirectories: true)
        let config = engineConfig.appending(path: "config.json")
        let want = ["vaultPath": Vault.root.path]
        if let data = try? Data(contentsOf: config), let have = try? JSONSerialization.jsonObject(with: data) as? [String: String], have == want { return }
        try JSONSerialization.data(withJSONObject: want).write(to: config, options: .atomic)
    }
}

/// The privacy switches, kept in Glyph Bot's own folder. Agents stay inside the vault unless
/// turned off; local-only (Bunker) is off by default so chat can use the model CLIs on this Mac.
///
/// They used to be written into the retired Tauri Prevail desktop's folder (`sh.prevail.desktop`),
/// because that app was Glyph Studio at the time. It is archived now (the owner, 2026-10-31), so nothing may
/// write there any more. A switch that has never been set here is still READ from there once, so a
/// choice the owner made in the old app carries over instead of snapping back to this code's default: his
/// vault lock is off, and the default here is on, so a plain repoint would have silently confined the
/// agents to the vault without him asking for it.
enum Privacy {
    /// Read-only, and only until the same switch is set here. Never written.
    static let retired = URL.homeDirectory.appending(path: "Library/Application Support/sh.prevail.desktop")
    static var folder: URL { StudioPaths.support }
    static var bunker: Bool { flag(Vault.isDemo ? "bunker.txt" : "bunker-mode.txt", default: false) }
    static var vaultLock: Bool { flag("vault-lock.txt", default: true) }
    /// Studio's own: agents propose what to save; nothing is written until you say Save.
    static var draftOnly: Bool { flag("draft-only.txt", default: true, in: StudioPaths.support) }
    static func set(bunker on: Bool) { write(Vault.isDemo ? "bunker.txt" : "bunker-mode.txt", on) }
    static func set(vaultLock on: Bool) { write("vault-lock.txt", on) }
    static func set(draftOnly on: Bool) { write("draft-only.txt", on, in: StudioPaths.support) }

    private static func flag(_ name: String, default def: Bool, in dir: URL? = nil) -> Bool {
        func read(_ u: URL) -> String? { try? String(contentsOf: u.appending(path: name), encoding: .utf8) }
        return decide(own: read(dir ?? folder), retired: read(retired), isDemo: Vault.isDemo, default: def)
    }

    /// Which value a switch takes, as a decision on its own so it can be tested without the disk.
    /// Set here wins; never set here carries what the retired app had; the demo vault never inherits.
    static func decide(own: String?, retired: String?, isDemo: Bool, default def: Bool) -> Bool {
        func on(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
        if let own { return on(own) }
        if !isDemo, let retired { return on(retired) }
        return def
    }
    private static func write(_ name: String, _ on: Bool, in dir: URL? = nil) {
        let d = dir ?? folder
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? (on ? "1" : "0").write(to: d.appending(path: name), atomically: true, encoding: .utf8)
    }
}

/// Provider keys for the engine's direct providers, read from the key files already on disk in
/// ~/.ai/env (never 1Password, never printed). Only the names the engine knows are passed, renamed to
/// its PREVAIL_*_KEY variables. The model CLIs (Claude, Codex) need none: they bring their own sign-in.
enum Keys {
    static let folder = URL.homeDirectory.appending(path: ".ai/env")
    static let names: [(file: String, engine: String, label: String)] = [
        ("ANTHROPIC_API_KEY", "PREVAIL_ANTHROPIC_KEY", "Anthropic"), ("OPENAI_API_KEY", "PREVAIL_OPENAI_KEY", "OpenAI"),
        ("OPENROUTER_API_KEY", "PREVAIL_OPENROUTER_KEY", "OpenRouter"), ("GEMINI_API_KEY", "PREVAIL_GOOGLE_KEY", "Google AI"),
        ("XAI_API_KEY", "PREVAIL_XAI_KEY", "xAI"), ("DEEPSEEK_API_KEY", "PREVAIL_DEEPSEEK_KEY", "DeepSeek"),
    ]

    /// KEY=value lines of every .env file in the folder; the first file to name a key wins.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            if !v.isEmpty, out[k] == nil { out[k] = v }
        }
        return out
    }

    static func onDisk(_ dir: URL = folder) -> [String: String] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".env") }.sorted { a, b in a.contains("resolved") && !b.contains("resolved") || (a.contains("resolved") == b.contains("resolved") && a < b) }
        var out: [String: String] = [:]
        for f in files { for (k, v) in parse(Vault.read(dir.appending(path: f)) ?? "") where out[k] == nil { out[k] = v } }
        return out
    }

    static func providerEnv(_ dir: URL = folder) -> [String: String] {
        let found = onDisk(dir)
        return Dictionary(uniqueKeysWithValues: names.compactMap { n in found[n.file].map { (n.engine, $0) } })
    }

    /// The providers with a key on disk, by name only.
    static func available(_ dir: URL = folder) -> [String] {
        let found = onDisk(dir)
        return names.filter { found[$0.file] != nil }.map(\.label)
    }
}

extension String {
    var nonEmpty: String? { let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
