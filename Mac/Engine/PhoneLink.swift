import Foundation
import Network

/// The iPhone's way in: Glyph Bot on the iPhone chats through this Mac over Tailscale, and only
/// through a Mac that is running Studio. A small HTTP server on port 7073 that answers only callers
/// with a Tailscale address (100.64.0.0/10) or this Mac itself; the traffic is inside Tailscale's
/// WireGuard tunnel. It runs only on your vault (the demo vault stays on the Mac) and only once turned
/// on in Settings, unless a test sets STUDIO_PHONE_PORT.
///
///   GET  /health                       {ok, vault, name}
///   GET  /agents                       [{id, name, last, time, needsYou, color, symbol}]
///   GET  /thread?agent=<id>            [{role, text, reads, saves, kind}]   the newest thread, last 40 turns
///   POST /chat   {agent, text, sources?}  NDJSON: reads, step*, delta*, done {text, saves, kind, thread} | error
///   POST /save   {agent, text}         the engine's receipt {id, kind, text, domain, where, file}
///   POST /undo   {id}                  {ok}
///   GET  /profile?agent=<id>           {soul: {excerpt, text}, memory: {excerpt, text}}  the agent's ideal state and memory, readable
@MainActor
final class PhoneLink {
    static let shared = PhoneLink()
    static let defaultPort: UInt16 = 7073
    private var listener: NWListener?
    private(set) var port: UInt16 = PhoneLink.defaultPort
    private(set) var problem: String?
    var running: Bool { listener != nil }

    static var wanted: Bool {
        if Engine.env["STUDIO_PHONE_PORT"] != nil { return true }
        guard !Vault.isDemo else { return false }
        let s = try? String(contentsOf: StudioPaths.support.appending(path: "phone-link.txt"), encoding: .utf8)
        return s?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" // off until you turn it on (Settings > iPhone)
    }

    static func set(on: Bool) {
        try? FileManager.default.createDirectory(at: StudioPaths.support, withIntermediateDirectories: true)
        try? (on ? "1" : "0").write(to: StudioPaths.support.appending(path: "phone-link.txt"), atomically: true, encoding: .utf8)
        Task { @MainActor in shared.sync() }
    }

    /// Starts or stops to match the setting.
    func sync() {
        if Self.wanted { start() } else { stop() }
    }

    func start() {
        guard listener == nil else { return }
        port = Engine.env["STUDIO_PHONE_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        do {
            // Bound to this Mac's Tailscale address, so the home network can't even connect; a test binds loopback.
            let params = NWParameters.tcp
            guard let host = Engine.env["STUDIO_PHONE_PORT"] != nil ? "127.0.0.1" : Self.tailscaleAddress() else {
                problem = "Tailscale isn't connected on this Mac."
                return
            }
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { c in Task { @MainActor in PhoneLink.accept(c) } }
            l.stateUpdateHandler = { s in
                Task { @MainActor in
                    if case .failed(let e) = s { PhoneLink.shared.problem = "The iPhone link stopped: \(e.localizedDescription)"; PhoneLink.shared.stop() }
                    if case .ready = s { print("phone link ready \(PhoneLink.shared.port)"); fflush(stdout) }
                }
            }
            l.start(queue: .main)
            listener = l
            problem = nil
        } catch { problem = "The iPhone link didn't start: \(error.localizedDescription)" }
    }

    func stop() { listener?.cancel(); listener = nil }

    /// This Mac's IPv4 address on the tailnet (100.64.0.0/10), from its network interfaces.
    nonisolated static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if allowed(ip), ip != "127.0.0.1" { return ip }
        }
        return nil
    }

    // MARK: who may call

    /// Tailscale's CGNAT range or this Mac. Everything else is closed without an answer.
    nonisolated static func allowed(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host
        if h == "127.0.0.1" || h == "::1" { return true }
        let v4 = h.hasPrefix("::ffff:") ? String(h.dropFirst(7)) : h
        let p = v4.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 { return p[0] == 100 && (64...127).contains(p[1]) }
        return h.lowercased().hasPrefix("fd7a:115c:a1e0:") // Tailscale's IPv6 range
    }

    private static func accept(_ c: NWConnection) {
        guard case .hostPort(let host, _) = c.endpoint, allowed("\(host)") else { c.cancel(); return }
        c.start(queue: .main)
        Request.read(c) { req in
            guard let req else { c.cancel(); return }
            Task { @MainActor in await route(req, c) }
        }
    }

    // MARK: routes

    private static func route(_ r: Request, _ c: NWConnection) async {
        let model = AppModel.shared
        switch (r.method, r.path) {
        case ("GET", "/health"):
            send(c, json: ["ok": true, "vault": Vault.mode.rawValue, "name": "Glyph Bot"])
        case ("GET", "/agents"):
            if model.team.isEmpty { await model.refresh() }
            let asks = TeamState.shared.asks
            let rows: [[String: Any]] = model.team.map { t in
                ["id": t.id, "name": t.name, "last": t.last, "time": t.time,
                 "needsYou": t.id == AppModel.chiefID ? !asks.isEmpty : asks.contains { $0.domain == t.id },
                 "color": String(format: "%06X", t.look.color), "symbol": t.look.glyph]
            }
            send(c, json: rows)
        case ("GET", "/thread"):
            let agent = r.query["agent"] ?? AppModel.chiefID
            send(c, json: thread(agent))
        case ("POST", "/chat"):
            await chat(r, c)
        case ("GET", "/profile"):
            send(c, json: profile(r.query["agent"] ?? AppModel.chiefID))
        case ("GET", "/file"):
            // Only files attached through Studio, for the phone's thumbnails.
            guard let rel = r.query["path"], Attachments.isAttachment(rel),
                  let data = try? Data(contentsOf: Vault.root.appending(path: rel)) else { return send(c, status: 404, json: ["error": "not found"]) }
            head(c, status: 200, type: Attachments.isImage(rel) ? "image/\((rel as NSString).pathExtension.lowercased())" : "application/octet-stream", length: data.count)
            c.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        case ("POST", "/save"):
            guard let agent = r.body["agent"] as? String, let text = (r.body["text"] as? String)?.nonEmpty else { return send(c, status: 400, json: ["error": "agent and text"]) }
            do {
                let t = try await Turn.save(text, agent: agent)
                send(c, json: ["id": t.id, "kind": t.kind, "text": t.text, "domain": t.domain, "where": t.where, "file": t.file ?? ""])
            } catch { send(c, status: 500, json: ["error": error.localizedDescription]) }
        case ("POST", "/undo"):
            guard let id = r.body["id"] as? String else { return send(c, status: 400, json: ["error": "id"]) }
            do { try await Turn.undo(Turn.Told(id: id, kind: "", text: "", domain: "", where: "")); send(c, json: ["ok": true]) }
            catch { send(c, status: 500, json: ["error": error.localizedDescription]) }
        default:
            send(c, status: 404, json: ["error": "not found"])
        }
    }

    static func thread(_ agent: String) -> [[String: Any]] {
        guard let file = Threads.newest(agent), let text = Vault.read(file) else { return [] }
        var pending: [SourceExcerpt] = []
        return Threads.turns(text).suffix(40).map { t in
            if t.role == "user" {
                let (said, reads) = Turn.split(t.text)
                pending = reads
                return ["role": "user", "text": said, "attachments": Turn.attachments(in: t.text)]
            }
            let (reply, saves) = Turn.saves(in: t.text)
            defer { pending = [] }
            return ["role": "assistant", "text": reply, "reads": pending.map(excerpt), "saves": saves, "kind": Turn.kind(reply, saves: saves)]
        }
    }

    /// An agent's Soul (its ideal state: purpose, trade-offs, what to avoid) and Memory (memory/memory.md),
    /// each as readable text and a one-line excerpt, for the phone's profile cards.
    static func profile(_ agent: String) -> [String: Any] {
        func card(_ rel: String) -> [String: String] {
            let text = readable(Vault.read(Vault.domain(agent).appending(path: rel)) ?? "")
            return ["excerpt": Preview.first(in: text) ?? "", "text": text]
        }
        return ["soul": card("ideal-state.md"), "memory": card("memory/memory.md")]
    }

    /// A vault note as a person reads it: no frontmatter, no title line, no notes the system wrote for
    /// itself ("_Consolidated 2026-07-04. Prior state..._"), no em dashes.
    static func readable(_ raw: String) -> String {
        var lines = Markdown.body(raw).components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[i].hasPrefix("# ") { lines.remove(at: i) }
        lines.removeAll { l in
            let t = l.trimmingCharacters(in: .whitespaces), lower = t.lowercased()
            let note = t.hasPrefix("_") || t.hasPrefix("*") && !t.hasPrefix("* ") || t.hasPrefix("> _")
            return note && Preview.housekeeping.contains { lower.contains($0) }
        }
        return Preview.undash(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excerpt(_ e: SourceExcerpt) -> [String: Any] {
        ["n": e.n, "source": e.source.rawValue, "title": e.title, "path": e.path, "text": String(e.text.prefix(600))]
    }

    /// One chat turn for the phone, streamed back as it happens.
    private static func chat(_ r: Request, _ c: NWConnection) async {
        guard let agent = (r.body["agent"] as? String)?.nonEmpty, let text = (r.body["text"] as? String)?.nonEmpty else {
            return send(c, status: 400, json: ["error": "agent and text"])
        }
        let chosen = (r.body["sources"] as? [String]).map { Set($0.compactMap(SourceID.init(rawValue:))) } ?? Sources.relevant(text, agent: agent)
        let reads = Sources.excerpts(for: text, agent: agent, using: chosen)
        // Files from the phone: [{"name": "...", "data": "<base64>"}], saved in the vault first.
        var attached: [String] = []
        for f in (r.body["files"] as? [[String: Any]]) ?? [] {
            guard let name = f["name"] as? String, let b64 = f["data"] as? String, let data = Data(base64Encoded: b64) else { continue }
            if let saved = try? Attachments.save(data, name: name, agent: agent) { attached.append(saved.path) }
        }
        head(c, status: 200, type: "application/x-ndjson")
        if !attached.isEmpty { line(c, ["type": "attached", "paths": attached]) }
        line(c, ["type": "reads", "reads": reads.map(excerpt)])
        var args = ["chat", "--domain", agent, "--json"]
        if let file = Threads.newest(agent) { args += ["--session", file.deletingPathExtension().lastPathComponent] }
        // A heartbeat while the engine is quiet, so the phone knows the Mac is on it (a turn can wait
        // minutes, e.g. on a macOS permission prompt; on 2026-10-28 one waited 37 minutes on "access
        // files in your Documents folder" and the phone gave up). The turn goes on if the phone leaves.
        var last = Date.now
        let started = Date.now
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, Date.now.timeIntervalSince(last) >= 9 else { continue }
                line(c, ["type": "working", "seconds": Int(Date.now.timeIntervalSince(started)), "hint": Turn.slowHint(Date.now.timeIntervalSince(last))])
            }
        }
        let o = await ChatSession.consume(Engine.lines(args, stdin: Data(Turn.message(text, excerpts: reads, attachments: attached).utf8)),
                                          step: { s in last = .now; line(c, ["type": "step", "text": s]) },
                                          partial: { p in last = .now; line(c, ["type": "delta", "text": Turn.saves(in: p).text]) })
        beat.cancel()
        if let f = o.failure { line(c, ["type": "error", "error": f]) } else {
            let (reply, saves) = Turn.saves(in: o.reply)
            line(c, ["type": "done", "text": reply, "saves": saves, "kind": Turn.kind(reply, saves: saves), "thread": o.thread ?? ""])
        }
        c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: HTTP, as little as works

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: [String: Any]

        static func read(_ c: NWConnection, buffer: Data = Data(), done: @escaping @Sendable (Request?) -> Void) {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, end, error in
                var buf = buffer
                if let data { buf.append(data) }
                guard buf.count < 30_000_000 else { return done(nil) } // a 20 MB file, base64
                if let r = parse(buf) { return done(r) }
                if end || error != nil { return done(nil) }
                read(c, buffer: buf, done: done)
            }
        }

        /// Nil until the headers and the whole body are in.
        static func parse(_ data: Data) -> Request? {
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
            let first = head.first?.split(separator: " ").map(String.init) ?? []
            guard first.count >= 2 else { return nil }
            let length = head.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = data[split.upperBound...]
            guard body.count >= length else { return nil }
            let comps = URLComponents(string: first[1])
            let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let obj = length > 0 ? (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] : nil
            return Request(method: first[0], path: comps?.path ?? first[1], query: query, body: obj ?? [:])
        }
    }

    private static func head(_ c: NWConnection, status: Int, type: String, length: Int? = nil) {
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let length { h += "Content-Length: \(length)\r\n" }
        c.send(content: Data((h + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private static func line(_ c: NWConnection, _ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        c.send(content: d, completion: .contentProcessed { _ in })
    }

    private static func send(_ c: NWConnection, status: Int = 200, json: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        head(c, status: status, type: "application/json", length: body.count)
        c.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
