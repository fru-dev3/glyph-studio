import Foundation
import GlyphAI
import GlyphVault

/// `glyphcore-report connect <METHOD> <path> [json body] [--vault <v>]`: the hub's /connect routes on
/// this machine's vault, so the hub's inbox can serve Glyph Connect on the
/// iPhone without a second copy of the state machine in Python. The routes themselves are GlyphAI's
/// `MacHub`, the same code the Mac agents use.
///
///   glyphcore-report connect GET connect
///   glyphcore-report connect PUT connect/tool '{"app":"gmail","tool":"send_message","chat":false}'
///   glyphcore-report connect PUT connect/app '{"app":"gmail","enabled":false}'
enum ConnectCommand {
    static func run(_ args: [String]) async -> Int32 {
        var rest = args
        var vault = ProcessInfo.processInfo.environment["GLYPH_VAULT"]
        if let i = rest.firstIndex(of: "--vault"), i + 1 < rest.count {
            vault = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
        guard rest.count >= 2 else {
            FileHandle.standardError.write(Data("usage: glyphcore-report connect <METHOD> <path> [json] [--vault <v>]\n".utf8))
            return 1
        }
        guard let vault, !vault.isEmpty else {
            FileHandle.standardError.write(Data("connect: no vault (set GLYPH_VAULT or pass --vault)\n".utf8))
            return 1
        }
        let method = rest[0].uppercased()
        let path = rest[1]
        guard path == "connect" || path.hasPrefix("connect/") else {
            FileHandle.standardError.write(Data("connect: only the /connect routes\n".utf8))
            return 1
        }
        let body = rest.count > 2 ? Data(rest[2].utf8) : nil
        // `Hub` with `vault` set does the routes on the vault's own files (GlyphAI MacHub), the
        // same path the Mac agents take. Public API, so this stays outside GlyphAI.
        var hub = Hub(base: nil, model: "Mac", app: "Glyph Connect")
        hub.vault = URL(filePath: vault)
        guard let (code, data) = await hub.send(method, path, body: body) else { return 1 }
        if !data.isEmpty { print(String(decoding: data, as: UTF8.self)) }
        // The status is the exit code's meaning: 0 for 200 and 204, else the status itself.
        if code == 200 || code == 204 { return 0 }
        FileHandle.standardError.write(Data("connect: \(code)\n".utf8))
        return Int32(code / 100)
    }
}
