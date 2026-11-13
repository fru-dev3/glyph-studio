import Foundation
import GlyphAI
import GlyphVault

/// `glyphcore-report file`: one document into the vault, the drop folder, a backfill, accept or undo.
/// The vault is `--vault`, else `GLYPH_VAULT` in the environment. Prints one JSON object with --json.
enum FileCommand {
    static let usage = """
        usage: glyphcore-report file <path> [--from <sender>] [--subject <s>] [--date <YYYY-MM-DD>] [--account <a>]
                                    [--source <who>] [--domain <d>] [--entity <id>] [--type <t>] [--dry-run] [--json]
               glyphcore-report file --inbox [--json]
               glyphcore-report file --backfill <vault folder> [--in-place] [--report <vault path>] [--limit N]
               glyphcore-report file --accept <id> [--domain <d>] [--subject <s>] [--type <t>] [--json]
               glyphcore-report file --undo <id>
               glyphcore-report file --expiring          (remake the Expiring list from the sidecars)
               glyphcore-report file <path> --text      (the words it reads, OCR included)
        common: [--vault <path>] [--no-model]
        exit: 0 filed or duplicate, 2 review, 1 error

        """

    static func run(_ a: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let has = { (flag: String) in a.contains(flag) }
        guard let vault = value("--vault").map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? Filing.configuredVault() else {
            FileHandle.standardError.write(Data("no vault: pass --vault <path> or set GLYPH_VAULT\n".utf8))
            return 1
        }
        let filer = Filer(vault: vault, useModel: !has("--no-model"))
        let json = has("--json")

        if has("--text"), let path = a.first(where: { !$0.hasPrefix("--") }) {  // the words the filer reads, for checking it
            guard let read = try? await filer.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return 1 }
            print(read.text)
            return 0
        }
        if has("--expiring") {  // remake records/memory/expiring.md from the sidecars already on disk
            do { try filer.filing.writeExpiring() } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
            let rows = filer.filing.expiring(), gaps = filer.filing.lapsed()
            print("expiring: \(rows.count) in the next 12 months, \(gaps.count) lapsed with nothing newer filed"
                  + " -> data/domains/records/memory/expiring.md")
            return 0
        }
        if let folder = value("--backfill") {
            let md = await filer.backfill(folder, inPlace: has("--in-place"), report: value("--report"), limit: value("--limit").flatMap(Int.init) ?? .max) { i, n in
                if i % 25 == 0 || i == n { FileHandle.standardError.write(Data("\(i)/\(n)\n".utf8)) }
            }
            if value("--report") == nil { print(md) } else { print("report: \(value("--report")!)") }
            return 0
        }
        if let id = value("--undo") {
            let ok = (try? filer.filing.undo(id)) ?? false
            print(ok ? "moved \(id) back to review" : "no filed document \(id)")
            return ok ? 0 : 1
        }
        if let id = value("--accept") {
            return show(await filer.accept(id, domain: value("--domain"), type: value("--type"), subject: value("--subject")), json: json)
        }
        if has("--inbox") {
            let results = await filer.inbox()
            if json { print(text(["results": results.map(\.json)])) } else { results.forEach { print(line($0)) } }
            return results.map(\.exitCode).max() ?? 0
        }
        let flagsWithValues: Set = ["--from", "--subject", "--date", "--account", "--source", "--domain", "--entity", "--type", "--vault", "--report", "--limit"]
        var path: String?
        var i = 0
        while i < a.count {
            if flagsWithValues.contains(a[i]) { i += 2; continue }
            if !a[i].hasPrefix("--") && path == nil { path = a[i] }
            i += 1
        }
        guard let path else { FileHandle.standardError.write(Data(usage.utf8)); return 1 }
        let sender = value("--from")
        let source = value("--source") ?? (sender != nil ? "email" : "drop")
        let from = [source, value("--account").map { "account \($0)" }, sender, value("--subject"), value("--date")].compactMap { $0 }.joined(separator: ", ")
        let req = Filer.Request(path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), source: source, from: from, sender: sender,
                                domain: value("--domain"), entity: value("--entity"), type: value("--type"), dryRun: has("--dry-run"))
        return show(await filer.file(req), json: json)
    }

    static func show(_ r: Filer.Result, json: Bool) -> Int32 {
        print(json ? text(r.json) : line(r))
        return r.exitCode
    }

    static func line(_ r: Filer.Result) -> String {
        switch r.status {
        case "filed": "\(r.dryRun ? "would file" : "filed") \(r.path ?? "")" + (r.actions.isEmpty ? "" : " (" + r.actions.map(\.kind).joined(separator: ", ") + ")")
        case "duplicate": "already filed: \(r.duplicateOf ?? "")"
        case "review": "waits for review: \(r.reviewReason ?? "")" + (r.path.map { " (would go to \($0))" } ?? "")
        default: "error: \(r.error ?? "unknown")"
        }
    }

    static func text(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
