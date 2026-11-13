import Foundation
import FoundationModels
import GlyphVault

// The family's app agents (Fru, 2026-10-30: "the main driver agent should know how to delegate it to these
// individual agents that will take action for it in their own individual context"). Each agent is an app's
// own: its instructions, its character, and its tools (Apple's Foundation Models `Tool`: a name, a
// description, typed arguments, the function that does it). A driver (Glyph Native) plans jobs and gives each
// to its agent, which works in a session of its own with only its tools. Tools write what the app itself
// writes (GlyphVault's AppLines) through the hub the apps already send to.

/// One job for one agent: "time", "wake me up in 2 hours". `name`, `kind` and `tag` are what the planner
/// already heard (Well's "Rice and beans" and "food", CRM's "Ken", Jot's "dream").
public struct Job: Equatable, Sendable {
    public var agent: String
    public var instruction: String
    public var name: String = ""
    public var kind: String = ""
    public var tag: String = ""
    public init(agent: String, instruction: String, name: String = "", kind: String = "", tag: String = "") {
        self.agent = agent; self.instruction = instruction; self.name = name; self.kind = kind; self.tag = tag
    }
}

/// What a tool did, for its card: the line (what the model is told), the thing itself in a few words (`title`,
/// what the card shows), how to take it back, the app to open. `waiting` is a Glyph Time request id: the card
/// stays "Waiting for Time" until Time answers on it. `review`: nothing applied yet, it waits for Fru's yes in
/// the app (a CRM suggestion, a merge, a question about which one).
public struct Done: Identifiable, Equatable, Sendable {
    public enum Undo: Equatable, Sendable {
        case wellDelete(id: String), crmReject(id: String, file: String)
        /// A Glyph Wealth entry taken back: its own delete line, as the app writes one.
        case wealthDelete(id: String)
        /// Glyph Life takes one of its own lines back with a delete line (the line stays in the file).
        case lifeDelete(id: String)
        /// Glyph Travel's own delete line (the lines stay in the file).
        case travelDelete(id: String)
        /// Jot's memo moved into an archived-<date> folder beside it (never deleted).
        case jotArchive(stem: String)
        /// A note's filing taken back: its line out of the place's linked-notes.md, the place out of its links.
        case jotUnfile(note: String, place: String)
        /// A file put back as it was, only while it still holds what the agent wrote (Omega, CRM pages).
        case restore(app: String, path: String, before: String?, after: String)
        /// A page the agent made, its folder moved to data/apps/crm/undone/ (kept, out of CRM).
        case crmUnmake(folder: String, to: String)
    }
    public let id = UUID()
    public var agent: String
    public var line: String
    public var title: String
    public var ok: Bool
    public var review = false
    public var undo: Undo?
    public var link: URL?
    public var waiting: String?
    /// A question for Fru ("Which Ken?"): the card offers each page and a new one (`Hub.answer`).
    public var ask: CRMAsk?
    public init(agent: String, line: String, title: String? = nil, ok: Bool, review: Bool = false, undo: Undo? = nil, link: URL? = nil, waiting: String? = nil) {
        self.agent = agent; self.line = line; self.title = title ?? line; self.ok = ok; self.review = review; self.undo = undo; self.link = link; self.waiting = waiting
    }
}

/// What the tools did during one job (a model may call a tool more than once).
public actor Ledger {
    public private(set) var done: [Done] = []
    public init() {}
    public func add(_ d: Done) { done.append(d) }
}

/// An app's agent: who it is (its face is a colour and a seed, drawn by the app), what it is told, its tools,
/// and what it does with a job when there is no model (the Simulator, older phones, tests).
public struct GlyphAgent: Sendable {
    public let id: String
    public let name: String
    public let color: String   // hex, the character's tile
    public let instructions: String
    public let tools: @Sendable (Hub, Ledger) -> [any Tool]
    public let fallback: @Sendable (Job, Hub) async -> Done

    public static let all: [GlyphAgent] = [.time, .jot, .well, .crm, .omega, .connect, .wealth, .life, .travel]
    public static func named(_ id: String) -> GlyphAgent? { all.first { $0.id == id } }

    /// The job in a session of its own with only this agent's tools; without the model, or when it called
    /// none, the fallback does it.
    public func run(_ job: Job, hub: Hub, model: Bool) async -> [Done] {
        let ledger = Ledger()
        if model {
            let heard = job.name.isEmpty ? "" : " (\(job.kind.isEmpty ? "name" : job.kind): \(job.name))"
            let told = instructions(with: await hub.preferences())   // the preferences in its scopes (Preferences.swift)
            _ = try? await LanguageModelSession(tools: toolkit(hub, ledger), instructions: told).respond(to: "Job: \(job.instruction)\(heard)")
            let got = await ledger.done
            if !got.isEmpty { return got }
        }
        return [await fallback(job, hub)]
    }
}

/// Where the tools write: the hub's inbox, as this phone ("Glyph Native, iPhone 15 Pro"; Well's file name
/// part "iphone-15-pro", the same as Glyph Well's on this phone so Well pulls the lines in).
public struct Hub: Sendable {
    public var base: URL?
    public var model: String      // "iPhone 15 Pro"
    public var app: String        // "Glyph Native"
    public var timeQueue: URL
    public var now: @Sendable () -> Date = { .now }
    /// On a Mac (`glyphcore-report run`): the vault itself. The hub's routes are done here on its files
    /// (MacHub.swift), so the same tools write the same lines with no hub in between.
    public var vault: URL?
    /// The month files' host part when it isn't an iPhone's ("laptop-local" on a Mac).
    public var hostName: String?

    public init(base: URL?, model: String, app: String = "Glyph Native", timeQueue: URL = TimeRequest.queue) {
        self.base = base; self.model = model; self.app = app; self.timeQueue = timeQueue
    }
    public var device: String { "\(app), \(model)" }
    public var host: String {
        if let hostName { return hostName }
        let slug = model.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
        return slug.hasPrefix("iphone") ? slug : "iphone-" + slug
    }

    /// Status and body, or nil when the hub can't be reached.
    public func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, type: String = "application/json",
                     headers: [String: String] = [:]) async -> (Int, Data)? {
        if let vault { return MacHub(vault: vault).handle(method, path, query: query, body: body, headers: headers) }
        guard let base, var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method; r.httpBody = body; r.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
        return (h.statusCode, d)
    }

    /// A write that must land: sent now, or kept on this phone and sent by `flush()` (the hub away, no signal).
    /// Every write here is the same bytes again on a resend, so twice is once. nil: kept for later.
    func put(_ path: String, query: [String: String] = [:], body: Data, type: String = "application/json") async -> Int? {
        let code = await send("PUT", path, query: query, body: body, type: type)?.0
        if code == nil { Outbox.keep(.init(path: path, query: query, body: body, type: type)) }
        return code
    }

    /// Sends what was kept. Call on launch and before each turn.
    public func flush() async {
        for p in Outbox.taken() {
            let code = p.path == "crm/propose" ? await appendProposal(String(decoding: p.body, as: UTF8.self), file: p.query["path"] ?? "", keep: false)
                : await send("PUT", p.path, query: p.query, body: p.body, type: p.type)?.0
            if code == nil { Outbox.keep(p) }   // 409 on a CRM note means it is there already: done
        }
    }

    /// Takes one card back with the app's own line.
    public func undo(_ u: Done.Undo) async -> Bool {
        switch u {
        case .wellDelete(let id):
            return await put("well/\(WellLine.file(now(), host: host))", body: Data(WellLine.delete(id: id, host: host, device: device, now: now()).utf8),
                             type: "application/x-ndjson") == 204
        case .wealthDelete(let id):
            return await put("wealth/\(WealthLine.file(now(), host: host))", body: Data(WealthLine.delete(id: id, host: host, device: device, now: now()).utf8),
                             type: "application/x-ndjson") == 204
        case .crmReject(let id, let file):
            guard let got = await send("GET", "crm/file", query: ["path": file]), got.0 == 200 else { return false }
            let base = String(decoding: got.1, as: UTF8.self)
            guard let text = CRMProposalLine.rejecting(id, in: base) else { return true }
            return await send("PUT", "crm/file", query: ["path": file], body: json(["text": text, "base": base]))?.0 == 204
        case .jotArchive(let stem):
            return await send("PUT", "memo-undo/\(stem)")?.0 == 204
        case .jotUnfile(let note, let place):
            return await send("PUT", "jot/unfile", body: json(["note": note, "place": place]))?.0 == 204
        case .restore(let app, let path, let before, let after):
            // Connect has no file to put back: the same route again with the values it had (`after`).
            if app == "connect" { return await connectUndo(after) }
            return app == "omega" ? await omegaPut(path, before ?? "", base: after) == 204
                : await send("PUT", "crm/file", query: ["path": path], body: json(["text": before ?? "", "base": after]))?.0 == 204
        case .travelDelete(let id):
            return await put("travel/\(TravelLine.file(now(), host: host))",
                             body: Data(TravelLine.delete(id: id, host: host, device: device, now: now()).utf8),
                             type: "application/x-ndjson") == 204
        case .crmUnmake(let folder, let to):
            return await send("PUT", "crm/move", body: json(["from": folder, "to": to]))?.0 == 204
        case .lifeDelete(let id):
            return await put("life/\(LifeLine.file(now(), host: host))", body: Data(LifeLine.delete(id: id, host: host, device: device, now: now()).utf8),
                             type: "application/x-ndjson") == 204
        }
    }

    func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    func kept(_ agent: String, _ what: String) -> Done {
        Done(agent: agent, line: "Kept on this iPhone, sends when the hub is back: \(what)", title: what, ok: true)
    }

    func unreachable(_ agent: String, _ what: String) -> Done {
        Done(agent: agent, line: "Can't reach the hub: \(what)", title: what, ok: false)
    }
}

/// Writes waiting for the hub, kept in this app's defaults.
enum Outbox {
    struct Pending: Codable { var path: String; var query: [String: String]; var body: Data; var type: String }
    static let key = "glyphAgentOutbox"
    static let lock = NSLock()
    static func keep(_ p: Pending) {
        lock.lock(); defer { lock.unlock() }
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        all.append(p)
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }
    static func taken() -> [Pending] {
        lock.lock(); defer { lock.unlock() }
        let all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        UserDefaults.standard.removeObject(forKey: key)
        return all
    }
}
