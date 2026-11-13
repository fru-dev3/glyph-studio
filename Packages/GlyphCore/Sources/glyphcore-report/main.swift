// Prints what GlyphCore reads from a vault as JSON, the same shape as Memosa's
// `cargo run --example vault_report`, so the two readers can be compared:
// glyphcore-report <vault> [search phrase...]
//
// And the door to document filing for shells and agents (FileCommand.swift):
// glyphcore-report file <path> [--from <sender>] [--subject s] [--date d] [--account a] [--domain d] [--json] ...
//
// And Glyph Time's routine ideas (RoutinesCommand.swift): glyphcore-report routines suggest [--vault v] [--dry-run]
//
// And the app agents' tools (AgentsCommand.swift): glyphcore-report agents | run <agent> <tool> '<json>' | undo '<json>'
import Foundation
import GlyphVault

let args = CommandLine.arguments
if args.count >= 2, args[1] == "file" { exit(await FileCommand.run(Array(args.dropFirst(2)))) }
if args.count >= 2, args[1] == "agents" { exit(AgentsCommand.agents()) }
if args.count >= 2, args[1] == "run" { exit(await AgentsCommand.run(Array(args.dropFirst(2)))) }
if args.count >= 2, args[1] == "routines" { exit(RoutinesCommand.run(Array(args.dropFirst(2)))) }
if args.count >= 2, args[1] == "connect" { exit(await ConnectCommand.run(Array(args.dropFirst(2)))) }
if args.count >= 2, args[1] == "undo" { exit(await AgentsCommand.run(Array(args.dropFirst(1)))) }
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: glyphcore-report <vault> [search phrase...]\n".utf8))
    exit(1)
}
let vault = Vault(root: URL(fileURLWithPath: args[1]))
let any = { (v: Any?) -> Any in v ?? NSNull() }
let conversations: [[String: Any]] = vault.conversations().map { c in
    let n = vault.notes(c.id)
    return [
        "id": c.id, "title": c.title, "created": c.created, "duration_sec": c.durationSec,
        "people": c.people, "accounts": c.accounts, "tags": c.tags,
        "summary": n.summary, "decisions": n.decisions.count,
        "actions": n.actions.map { ["text": $0.text, "done": $0.done, "owner": any($0.owner), "due": any($0.due)] },
        "segments": vault.transcript(c.id).segments.count,
    ]
}
let dir = vault.directory()
let report: [String: Any] = [
    "conversations": conversations,
    "entities": dir.entities.map { ["kind": $0.entity.kind.rawValue, "name": $0.entity.name, "aliases": $0.entity.aliases, "account": any($0.entity.account), "count": $0.count] },
    "tags": dir.tags.map { ["name": $0.name, "count": $0.count] },
    "searches": args.dropFirst(2).map { ["query": $0, "hits": vault.search($0)] },
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
