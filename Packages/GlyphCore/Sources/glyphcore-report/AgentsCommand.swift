import Foundation
import GlyphAI
import GlyphVault
import SystemConfiguration

/// `glyphcore-report agents` and `run`: the app agents' tools on a Mac, for shells and the engine's MCP tools.
/// `run` writes into the vault (`--vault`, else `GLYPH_VAULT`) the lines the apps write; prints JSON.
enum AgentsCommand {
    static let usage = """
        usage: glyphcore-report agents                                every agent, its tools and their JSON arguments
               glyphcore-report run <agent> <tool> '<json args>' [--vault <path>]
               glyphcore-report undo '<a result's undo object>' [--vault <path>]   takes that write back
        example: glyphcore-report run well log_entry '{"text":"Rice and beans","kind":"food","minutesAgo":0}'
        exit: 0 done or waiting, 1 error or a tool that failed

        """

    static func agents() -> Int32 {
        do { print(FileCommand.text(["agents": try GlyphAgent.catalog()])); return 0 }
        catch { return fail("\(error)") }
    }

    static func run(_ a: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let words = a.enumerated().filter { $0.offset == 0 || a[$0.offset - 1] != "--vault" }.map(\.element).filter { $0 != "--vault" }
        if words.first == "undo" {
            guard words.count == 2, let o = (try? JSONSerialization.jsonObject(with: Data(words[1].utf8))) as? [String: Any],
                  let undo = Done.Undo(card: o) else { return fail("undo takes a result's undo object as JSON") }
            guard let vault = value("--vault").map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? Filing.configuredVault() else {
                return fail("no vault: pass --vault <path> or set GLYPH_VAULT")
            }
            let ok = await macHub(vault).undo(undo)
            print(FileCommand.text(["undo": o, "ok": ok]))
            return ok ? 0 : 1
        }
        guard words.count >= 2 else { FileHandle.standardError.write(Data(usage.utf8)); return 1 }
        guard let agent = GlyphAgent.named(words[0]) else { return fail("no agent \(words[0]); agents: \(GlyphAgent.all.map(\.id).joined(separator: ", "))") }
        guard let vault = value("--vault").map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? Filing.configuredVault() else {
            return fail("no vault: pass --vault <path> or set GLYPH_VAULT")
        }
        guard FileManager.default.fileExists(atPath: vault.appending(path: "data").path) else { return fail("not a vault (no data/): \(vault.path)") }
        let hub = macHub(vault)
        do {
            let done = try await agent.call(words[1], json: words.count > 2 ? words[2] : "{}", hub: hub)
            print(FileCommand.text(["agent": agent.id, "tool": words[1], "results": done.map(\.card)]))
            return done.allSatisfy(\.ok) && !done.isEmpty ? 0 : 1
        } catch { return fail("\(error)") }
    }

    /// This Mac as a writer: Glyph Well's host naming (its month files), its computer name as the device.
    static func macHub(_ vault: URL) -> Hub {
        let host = ((SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac") + ".local").lowercased().replacingOccurrences(of: ".", with: "-")
        let requests = vault.appending(path: "data/apps/time/requests.\(host).jsonl")
        try? FileManager.default.createDirectory(at: requests.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hub = Hub(base: nil, model: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac", app: "Glyph agents", timeQueue: requests)
        hub.vault = vault
        hub.hostName = host
        return hub
    }

    static func fail(_ why: String) -> Int32 {
        print(FileCommand.text(["error": why]))
        return 1
    }
}
