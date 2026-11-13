import Foundation
import FoundationModels
import GlyphVault

/// Glyph Well's agent: food and drink, symptoms, mood, sleep, as Well's own `log` lines in this phone's month
/// file (Glyph Well on this phone pulls them in and lists them).
extension GlyphAgent {
    public static let well = GlyphAgent(
        // Office green, the app's own accent. It was a crimson rose, which on a green app read
        // as alien and sat a shade away from the one red this family keeps for a running mic.
        // An agent's face is its app's face; Well's is a leaf on green.
        id: "well", name: "Well", color: "008000",
        instructions: "You are Glyph Well's agent. Log each food or drink, symptom, mood or sleep in the job with log_entry, one call each, named in 1 to 4 of the person's words.",
        tools: { hub, ledger in [WellLogEntry(hub: hub, ledger: ledger)] },
        fallback: { job, hub in await hub.logWell(kind: job.kind, name: job.name.isEmpty ? job.instruction : job.name, said: job.instruction, at: hub.now()) })
}

public struct WellLogEntry: Tool {
    public let name = "log_entry"
    public let description = "Log something in Glyph Well: food or drink, a symptom, mood or sleep."
    @Generable public struct Arguments {
        @Guide(description: "1 to 4 words naming it, like Rice and beans, Headache.") public var text: String
        @Guide(description: "What kind", .anyOf(["food", "symptom", "mood", "sleep"])) public var kind: String
        @Guide(description: "When, if said: minutes before now (0 for now).", .range(0...1440)) public var minutesAgo: Int
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.logWell(kind: a.kind, name: a.text, said: a.text, at: hub.now().addingTimeInterval(-60 * Double(a.minutesAgo)))
        await ledger.add(d); return d.line
    }
}

extension Hub {
    public func logWell(kind: String, name: String, said: String, at: Date) async -> Done {
        let id = UUID().uuidString
        let name = name.prefix(1).uppercased() + name.dropFirst()
        let line = WellLine.log(id: id, kind: kind, name: name, said: said, at: at, host: host, device: device, now: now())
        let code = await put("well/\(WellLine.file(now(), host: host))", body: Data(line.utf8), type: "application/x-ndjson")
        if code == nil { return kept("well", name) }
        guard code == 204 else { return Done(agent: "well", line: "Well didn't take it (\(code!)): \(name)", title: name, ok: false) }
        return Done(agent: "well", line: "Logged in Well: \(name)", title: name, ok: true, undo: .wellDelete(id: id), link: URL(string: "glyph-well://today"))
    }
}
