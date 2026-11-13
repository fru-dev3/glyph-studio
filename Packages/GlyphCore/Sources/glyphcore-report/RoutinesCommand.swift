import Foundation
import GlyphVault

/// `glyphcore-report routines suggest [--vault <path>] [--dry-run]`: ideas for Glyph Time routines from the
/// vault's Garmin, Well and Time data (GlyphVault `RoutineSuggest`), written as lines into
/// data/apps/time/sessions/<month>.routines.jsonl for the phone to Add or Dismiss. --dry-run prints only.
enum RoutinesCommand {
    static func run(_ a: [String]) -> Int32 {
        guard a.first == "suggest" else {
            FileHandle.standardError.write(Data("usage: glyphcore-report routines suggest [--vault <path>] [--dry-run]\n".utf8))
            return 1
        }
        let path = a.firstIndex(of: "--vault").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        guard let vault = path.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? Filing.configuredVault(),
              FileManager.default.fileExists(atPath: vault.appending(path: "data").path) else {
            return AgentsCommand.fail("no vault: pass --vault <path> or set GLYPH_VAULT")
        }
        let write = !a.contains("--dry-run")
        do {
            let ideas = try RoutineSuggest.run(vault: vault, write: write)
            let f = Date.FormatStyle().hour().minute()
            print(FileCommand.text(["written": write, "suggestions": ideas.map { s -> [String: Any] in
                ["id": s.id, "title": s.title, "cadence": s.rule.map { "\($0.dropFirst()) a week" } ?? Routine.daysText(s.days),
                 "time": s.time.map { $0.formatted(f) } ?? "", "why": s.why, "source": s.source]
            }]))
            return 0
        } catch { return AgentsCommand.fail("\(error)") }
    }
}
