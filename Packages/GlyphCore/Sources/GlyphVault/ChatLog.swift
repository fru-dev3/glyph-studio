import Foundation

/// A chat's record: one append-only JSON-lines file per chat, `<folder>/<id>.jsonl`, in the app's
/// Documents and, once sent, in the vault's `data/apps/<app>/chats/`. The first line says which
/// chat it is; every later line is one line of the chat. A line that changes (a reply that finishes,
/// an Undo) is written again with the same `n`, and the last one wins, so the file is never rewritten.
///
///     {"app":"time","device":"iPhone 17 Pro","id":"2026-10-30-091204-a1b2","started":"2026-10-30T09:12:04-05:00","ts":"2026-10-30T09:12:04-05:00"}
///     {"mine":true,"n":0,"text":"Remind me Wednesdays at 9","ts":"2026-10-30T09:12:04-05:00"}
///     {"mine":false,"n":1,"short":"Wednesdays · 9:00 AM","status":"done","text":"Reminder: every Wednesday at 9:00 AM","ts":"2026-10-30T09:12:05-05:00"}
///
/// Status: done, asking, failed, undone, review (waits for a yes in its app), working. `who` is the
/// agent a line came from (Glyph Native's cards). Archiving never deletes: the file moves into
/// `archived-<YYYY-MM-DD>/` beside it, on the phone and in the vault.
public struct ChatLine: Codable, Equatable, Sendable, Identifiable {
    public var n: Int
    public var mine: Bool
    public var text: String
    public var short: String?
    public var status: String?
    public var who: String?
    public var ts: Date
    public var id: Int { n }

    public init(n: Int, mine: Bool, text: String, short: String? = nil, status: String? = nil, who: String? = nil, ts: Date = .now) {
        self.n = n; self.mine = mine; self.text = text; self.short = short; self.status = status; self.who = who; self.ts = ts
    }
}

/// One past chat, folded from its file.
public struct Chat: Identifiable, Equatable, Sendable {
    public var id: String
    public var app: String
    public var started: Date
    public var device: String?
    public var lines: [ChatLine]
    /// The first thing said: the chat's name in the history list.
    public var title: String { lines.first { $0.mine }?.text ?? lines.first?.text ?? "" }
}

public struct ChatLog: Sendable {
    public let folder: URL
    public let app: String

    public init(folder: URL, app: String) { self.folder = folder; self.app = app }

    /// `Documents/Chats` of this app.
    public static func documents(app: String) -> ChatLog {
        ChatLog(folder: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Chats"), app: app)
    }

    /// "2026-10-30-091204-a1b2": when it started, so names sort by time, and four letters so two never clash.
    public static func newID(at date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date) + "-" + String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(4))
    }

    private struct Entry: Codable {
        var id: String?, app: String?, started: Date?, device: String?
        var n: Int?, mine: Bool?, text: String?, short: String?, status: String?, who: String?
        var ts: Date
    }

    func url(_ id: String) -> URL { folder.appending(path: "\(id).jsonl") }

    /// Starts a chat's file with its first line.
    public func start(_ id: String, device: String?, at date: Date = .now) throws {
        try write(Entry(id: id, app: app, started: date, device: device, ts: date), to: id)
    }

    /// One line of the chat (or a line again, changed), appended; the chat is marked for sending.
    public func append(_ line: ChatLine, to id: String) throws {
        try write(Entry(n: line.n, mine: line.mine, text: line.text, short: line.short, status: line.status, who: line.who, ts: line.ts), to: id)
        mark(send: id)
    }

    /// The chat screen as it stands: starts the file if needed, then appends only the lines that are new or
    /// changed since the file last had them (the time aside), so calling it on every change writes each once.
    public func save(_ lines: [ChatLine], to id: String, device: String?) throws {
        guard !lines.isEmpty else { return }
        let had = chat(id)
        if had == nil { try start(id, device: device) }
        let old = Dictionary((had?.lines ?? []).map { ($0.n, $0) }, uniquingKeysWith: { $1 })
        for l in lines {
            if let o = old[l.n], o.mine == l.mine, o.text == l.text, o.short == l.short, o.status == l.status, o.who == l.who { continue }
            try append(l, to: id)
        }
    }

    private func write(_ e: Entry, to id: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var d = try TimeLog.encoder.encode(e); d.append(0x0A)
        let u = url(id)
        if let h = try? FileHandle(forWritingTo: u) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: d) }
        else { try d.write(to: u, options: .atomic) }
    }

    /// The chat as its file has it (each `n` once, its last line), nil if there is no such file.
    public func chat(_ id: String) -> Chat? { Self.fold(id, (try? Data(contentsOf: url(id))) ?? Data(), app: app) }

    static func fold(_ id: String, _ data: Data, app: String) -> Chat? {
        var c: Chat?, lines: [Int: ChatLine] = [:]
        for raw in data.split(separator: 0x0A) {
            guard let e = try? TimeLog.decoder.decode(Entry.self, from: Data(raw)) else { continue }
            if let started = e.started { c = Chat(id: e.id ?? id, app: e.app ?? app, started: started, device: e.device, lines: []) }
            else if let n = e.n, let mine = e.mine, let text = e.text {
                lines[n] = ChatLine(n: n, mine: mine, text: text, short: e.short, status: e.status, who: e.who, ts: lines[n]?.ts ?? e.ts)
            }
        }
        c?.lines = lines.values.sorted { $0.n < $1.n }
        return c
    }

    /// Every chat with something said in it, newest first; archived ones are not listed.
    public func chats() -> [Chat] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.compactMap { chat(String($0.dropLast(6))) }
            .filter { !$0.lines.isEmpty }.sorted { $0.started > $1.started }
    }

    /// Moves the chat into `archived-<YYYY-MM-DD>/` beside it (never deleted) and marks the move for the vault.
    public func archive(_ id: String, at date: Date = .now) throws {
        let dir = folder.appending(path: "archived-\(Self.day(date))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appending(path: "\(id).jsonl")
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) } // the same chat again: the newer copy
        try FileManager.default.moveItem(at: url(id), to: to)
        update { $0.archive.insert(id) }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: Sending to the vault

    /// What the vault hasn't taken yet, kept beside the chats (`.pending.json`), so a quit loses nothing.
    struct Pending: Codable, Equatable { var send: Set<String> = []; var archive: Set<String> = [] }
    var pendingURL: URL { folder.appending(path: ".pending.json") }
    var pending: Pending { (try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))) ?? Pending() }
    private func update(_ change: (inout Pending) -> Void) {
        var p = pending; change(&p)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(p).write(to: pendingURL, options: .atomic)
    }
    private func mark(send id: String) { if !pending.send.contains(id) { update { $0.send.insert(id) } } }

    /// Sends every chat the vault hasn't taken, whole (`PUT chats/<app>/<id>.jsonl`; the hub merges the
    /// lines, each once, so a resend is harmless), then the archive moves (`PUT chats-archive/<app>/<id>.jsonl`).
    /// `put` is the app's own route to the hub: the path and body in, the status code out, nil when unreachable.
    /// Returns true when nothing is left waiting.
    @discardableResult
    public func send(_ put: (String, Data) async -> Int?) async -> Bool {
        for id in pending.send.sorted() {
            guard let u = located(id), let data = try? Data(contentsOf: u) else { update { $0.send.remove(id) }; continue }
            if await put("chats/\(app)/\(id).jsonl", data) == 204, (try? Data(contentsOf: u)) == data { // a line written meanwhile goes next time
                update { $0.send.remove(id) }
            }
        }
        for id in pending.archive.sorted() where !pending.send.contains(id) {
            if await put("chats-archive/\(app)/\(id).jsonl", Data()) == 204 { update { $0.archive.remove(id) } }
        }
        let p = pending
        return p.send.isEmpty && p.archive.isEmpty
    }

    /// The chat's file, live or archived.
    private func located(_ id: String) -> URL? {
        if FileManager.default.fileExists(atPath: url(id).path) { return url(id) }
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("archived-") }
        return dirs.map { folder.appending(path: $0).appending(path: "\(id).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// One turn of a chat as the hub's /understand sees it (`history`): said by the person, or by the app.
public struct ChatTurn: Codable, Equatable, Sendable {
    public var mine: Bool
    public var text: String
    public init(mine: Bool, text: String) { self.mine = mine; self.text = text }
}
