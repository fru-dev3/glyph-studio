// Run: swift Packages/GlyphCore/scripts/permission-isolation-check.swift
//
// TCC answers a permission request on its own XPC queue, never on the main actor. LiveDictation
// is @MainActor, so a completion handler written anywhere inside it is main-actor code, and when
// TCC invokes it from that queue Swift's isolation check traps: dispatch_assert_queue inside
// swift_task_isCurrentExecutor, EXC_BREAKPOINT on the very first talk, before a word is said.
// That crashed every Glyph app that opens on a chat with a talk button (GlyphTime, 2026-10-31).
//
// So every permission completion handler in Dictate.swift must live in a nonisolated function
// and hop to the main actor itself before resuming its continuation. This fails if either half
// goes away. It reads the source because the crash needs real TCC on a real device: a unit test
// gets no answer from TCC, and a continuation resumed from a background queue does not trap on
// its own, so neither reproduces it. The live proof is testChatFirst on the simulator.

import Foundation

let source = URL(filePath: #filePath)
    .deletingLastPathComponent()      // scripts
    .deletingLastPathComponent()      // GlyphCore
    .appending(path: "Sources/GlyphCapture/Dictate.swift")
let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

/// A permission request that hands its answer back through a completion handler.
let callbacks = ["requestAuthorization {", "requestAccess(for:", "requestRecordPermission {"]
let found = lines.indices.filter { i in callbacks.contains { lines[i].contains($0) } && lines[i].contains("{") }

check(!found.isEmpty, "no permission callback found in Dictate.swift: has it moved, or has the check gone stale?")

for i in found {
    let at = "Dictate.swift:\(i + 1)"
    guard let declaration = lines[..<i].lastIndex(where: { $0.contains("func ") }) else {
        failures.append("\(at): a permission callback outside any function")
        continue
    }
    check(lines[declaration].contains("nonisolated"),
          "\(at): the callback sits in a main-actor function (\(lines[declaration].trimmingCharacters(in: .whitespaces))). "
          + "Build it in a nonisolated function, or TCC's queue traps on the first talk.")

    let body = lines[i..<min(i + 8, lines.count)].joined(separator: " ")
    if let resume = body.range(of: "resume(") {
        check(body[..<resume.lowerBound].contains("@MainActor"),
              "\(at): the continuation is resumed without hopping to the main actor first.")
    }
}

guard failures.isEmpty else {
    for f in failures { print("FAIL \(f)") }
    exit(1)
}
print("ok: \(found.count) permission callback(s) in Dictate.swift are nonisolated and hop to the main actor")
