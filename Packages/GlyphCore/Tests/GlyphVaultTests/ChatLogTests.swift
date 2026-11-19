import Foundation
import Testing
@testable import GlyphVault

private func log() -> ChatLog {
    ChatLog(folder: FileManager.default.temporaryDirectory.appending(path: "glyph-chats-\(UUID().uuidString)"), app: "time")
}

@Test func chatWritesAndReloads() throws {
    let log = log(), t = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ChatLog.newID(at: t)
    #expect(id.count == 22)
    try log.start(id, device: "iPhone 17 Pro", at: t)
    try log.append(ChatLine(n: 0, mine: true, text: "Remind me to call Ken at 3", ts: t), to: id)
    try log.append(ChatLine(n: 1, mine: false, text: "Working on it", status: "working", ts: t), to: id)
    try log.append(ChatLine(n: 1, mine: false, text: "Reminder: call Ken, today at 3:00 PM", short: "Call Ken · 3:00 PM", status: "done", ts: t.addingTimeInterval(1)), to: id)
    let c = try #require(log.chat(id))
    #expect(c.device == "iPhone 17 Pro" && c.app == "time" && c.started == t)
    #expect(c.lines.count == 2, "a line written again replaces itself")
    #expect(c.lines[1].status == "done" && c.lines[1].short == "Call Ken · 3:00 PM" && c.lines[1].ts == t, "the last one wins, its first time kept")
    #expect(c.title == "Remind me to call Ken at 3")
    let text = try String(contentsOf: log.url(id), encoding: .utf8)
    #expect(text.split(separator: "\n").count == 4, "append only: four lines written, none rewritten")

    // An empty chat (started, nothing said) is not listed; newest first.
    let later = ChatLog.newID(at: t.addingTimeInterval(60))
    try log.start(later, device: nil, at: t.addingTimeInterval(60))
    #expect(log.chats().map(\.id) == [id])
    try log.append(ChatLine(n: 0, mine: true, text: "Wake me at 7"), to: later)
    #expect(log.chats().map(\.id) == [later, id])
}

@Test func chatArchiveMovesNeverDeletes() throws {
    let log = log(), t = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ChatLog.newID(at: t)
    try log.start(id, device: nil, at: t)
    try log.append(ChatLine(n: 0, mine: true, text: "Focus on Acme for 25 minutes", ts: t), to: id)
    try log.archive(id, at: t)
    #expect(log.chats().isEmpty && log.chat(id) == nil)
    let moved = log.folder.appending(path: "archived-\(ChatLog.day(t))/\(id).jsonl")
    #expect(FileManager.default.fileExists(atPath: moved.path), "moved beside the chats, kept whole")
    #expect(ChatLog.fold(id, try Data(contentsOf: moved), app: "time")?.lines.count == 1)
}

@Test func chatSyncIsIdempotent() async throws {
    let log = log(), t = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ChatLog.newID(at: t)
    try log.start(id, device: nil, at: t)
    try log.append(ChatLine(n: 0, mine: true, text: "Wake me at 7", ts: t), to: id)

    var sent: [(String, Data)] = []
    var hubUp = false
    let put: (String, Data) async -> Int? = { p, d in guard hubUp else { return nil }; sent.append((p, d)); return 204 }

    #expect(await log.send(put) == false, "hub away: kept waiting")
    hubUp = true
    #expect(await log.send(put) == true)
    #expect(sent.map(\.0) == ["chats/time/\(id).jsonl"])
    #expect(sent[0].1 == (try Data(contentsOf: log.url(id))), "the whole file")
    #expect(await log.send(put) == true && sent.count == 1, "nothing new: nothing sent again")

    try log.append(ChatLine(n: 1, mine: false, text: "Alarm: 7:00 AM", status: "done", ts: t), to: id)
    try log.archive(id, at: t)
    #expect(await log.send(put) == true)
    #expect(sent.map(\.0) == ["chats/time/\(id).jsonl", "chats/time/\(id).jsonl", "chats-archive/time/\(id).jsonl"],
            "the new line goes first (from the archive folder), then the move")
    #expect(await log.send(put) == true && sent.count == 3)
}

@Test func chatSaveWritesEachChangeOnce() throws {
    let log = log(), id = ChatLog.newID()
    var lines = [ChatLine(n: 0, mine: true, text: "Wake me at 7")]
    try log.save(lines, to: id, device: "iPhone 17 Pro")
    try log.save(lines, to: id, device: "iPhone 17 Pro")
    lines.append(ChatLine(n: 1, mine: false, text: "Alarm: 7:00 AM", short: "7:00 AM", status: "done"))
    try log.save(lines, to: id, device: "iPhone 17 Pro")
    lines[1].status = "undone"
    try log.save(lines, to: id, device: "iPhone 17 Pro")
    try log.save(lines, to: id, device: "iPhone 17 Pro")
    #expect(try String(contentsOf: log.url(id), encoding: .utf8).split(separator: "\n").count == 4, "start, mine, reply, its undo")
    #expect(log.chat(id)?.lines.map(\.status) == [nil, "undone"] && log.chat(id)?.device == "iPhone 17 Pro")
    try log.save([], to: ChatLog.newID(), device: nil)
    #expect(log.chats().count == 1, "an empty screen writes nothing")
}

@Test func aChatCanBeGivenAName() throws {
    let log = log(), id = ChatLog.newID()
    try log.save([ChatLine(n: 0, mine: true, text: "What did I say about the Cameroon trip")], to: id, device: nil)
    #expect(log.chat(id)?.name == nil)
    #expect(log.chat(id)?.title == "What did I say about the Cameroon trip", "until it is named, the first thing said")

    try log.rename(id, to: "Cameroon trip")
    #expect(log.chat(id)?.name == "Cameroon trip")
    #expect(log.chat(id)?.title == "Cameroon trip", "the name wins over the first thing said")
    #expect(log.chat(id)?.said == "What did I say about the Cameroon trip", "and what was said is still there")

    try log.rename(id, to: "  Cameroon  ")
    #expect(log.chat(id)?.title == "Cameroon", "renaming again wins, and the name is trimmed")
    try log.rename(id, to: "")
    #expect(log.chat(id)?.title == "What did I say about the Cameroon trip", "an empty name hands it back to what was said")

    // The point of writing a name as a line: the file is only ever appended to, so the vault takes
    // a rename exactly as it takes a reply, and nothing already written is touched.
    let lines = try String(contentsOf: log.url(id), encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 5, "start, what was said, and one line per naming")
    #expect(lines[1].contains("What did I say"), "the first line said is where it always was")

    // A name given to a chat with nothing said in it still folds: rename starts the file.
    let empty = ChatLog.newID()
    try log.rename(empty, to: "Later")
    #expect(log.chat(empty)?.name == "Later")
    #expect(log.chats().map(\.id) == [id], "but a chat with nothing said in it is not a past chat")
}
