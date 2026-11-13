import Foundation
import FoundationModels
import GlyphVault

/// Glyph Connect's agent: the external systems the other agents can reach, and the switch beside each
/// one. It writes the registry's own bytes (GlyphVault `AppRegistry`, `data/apps/<id>/manifest.json`)
/// through the hub's /connect routes.
///
/// Its tools are deliberately one-sided, because an agent that can widen its own reach has the whole
/// thing backwards:
/// - asking what can be reached is a read, always allowed;
/// - taking reach away (a tool blocked, an app switched off) is done on his word, with Undo;
/// - **granting** reach is a suggestion only, waiting for Fru's yes on the app's page in Connect;
/// - connecting something new, signing in and revoking a token are not tools at all. They need a
///   human at a browser, and a revoked token has no undo.
extension GlyphAgent {
    public static let connect = GlyphAgent(
        id: "connect", name: "Connect", color: "006644",
        instructions: """
        You are Glyph Connect's agent. You look after the outside systems the other agents can reach: Gmail, \
        Calendar, Drive, GitHub, MCP servers. To say what can be reached right now, or whether one thing is \
        healthy, call connection_health. To take reach away, which you may always do when asked: block_tool for \
        one tool, turn_off_app for the whole app. To give reach, call suggest_allow; it never grants anything \
        itself, it waits for his yes in Connect. You cannot connect anything new, sign in, or disconnect an \
        account: say that those are done by hand in Glyph Connect.
        """,
        tools: { hub, ledger in [ConnectHealth(hub: hub, ledger: ledger), ConnectBlockTool(hub: hub, ledger: ledger),
                                 ConnectTurnOffApp(hub: hub, ledger: ledger), ConnectSuggestAllow(hub: hub, ledger: ledger)] },
        fallback: { job, hub in await hub.connectionHealth(about: job.name) })
}

public struct ConnectHealth: Tool {
    public let name = "connection_health"
    public let description = "What the agents can reach right now, and whether each connection is healthy."
    @Generable public struct Arguments {
        @Guide(description: "One app to look at, like Gmail. Empty for all of them.") public var app: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.connectionHealth(about: a.app); await ledger.add(d); return d.line
    }
}

public struct ConnectBlockTool: Tool {
    public let name = "block_tool"
    public let description = "Stop one tool of one app being called. Takes reach away, never gives it."
    @Generable public struct Arguments {
        @Guide(description: "The app, like Gmail.") public var app: String
        @Guide(description: "The tool, like send_message. Use all for every tool, or writes for every write tool.") public var tool: String
        @Guide(description: "Where to stop it", .anyOf(["everywhere", "sync", "chat"])) public var where_: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.setReach(app: a.app, tool: a.tool, scope: a.where_, allow: false); await ledger.add(d); return d.line
    }
}

public struct ConnectTurnOffApp: Tool {
    public let name = "turn_off_app"
    public let description = "Switch one app off, so no agent may reach it at all."
    @Generable public struct Arguments {
        @Guide(description: "The app, like Gmail.") public var app: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.turnOffApp(a.app); await ledger.add(d); return d.line
    }
}

public struct ConnectSuggestAllow: Tool {
    public let name = "suggest_allow"
    public let description = "Suggest letting a tool be called again. Grants nothing: it waits for his yes in Glyph Connect."
    @Generable public struct Arguments {
        @Guide(description: "The app, like Gmail.") public var app: String
        @Guide(description: "The tool, like send_message.") public var tool: String
        @Guide(description: "Where", .anyOf(["sync", "chat"])) public var where_: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = Done(agent: "connect",
                     line: "Not done. Allowing \(a.tool) in \(a.where_) waits for your yes in Connect: open \(a.app) and turn it on there.",
                     title: "\(a.app): allow \(a.tool)", ok: true, review: true,
                     link: URL(string: "glyph-connect://app/\(a.app.lowercased())"))
        await ledger.add(d); return d.line
    }
}

extension Hub {
    /// `GET /connect`: the five counts and, when `about` names one, that app's own line.
    public func connectionHealth(about app: String = "") async -> Done {
        guard let (code, data) = await send("GET", "connect"), code == 200, let got = JSON.parse(String(decoding: data, as: UTF8.self)) else {
            return unreachable("connect", app.isEmpty ? "connection health" : app)
        }
        let apps = got["apps"]?.asArray ?? []
        if !app.isEmpty {
            guard let one = Self.match(app, in: apps) else {
                return Done(agent: "connect", line: "Nothing called \(app) is in your registry.", title: app, ok: false)
            }
            let title = one["title"]?.asString ?? app
            return Done(agent: "connect", line: Self.sentence(one), title: title, ok: true,
                        link: URL(string: "glyph-connect://app/\(one["id"]?.asString ?? "")"))
        }
        let counts = got["counts"]
        func n(_ k: String) -> Int { counts?[k]?.asInt ?? 0 }
        let line = "Your agents can reach \(n("open") + n("needsYou") + n("failing")) of \(apps.count). "
            + "Open \(n("open")), needs you \(n("needsYou")), failing \(n("failing")), off \(n("off"))."
        return Done(agent: "connect", line: line, title: "\(n("open")) open", ok: true, link: URL(string: "glyph-connect://"))
    }

    /// One app's health as a sentence, from `GET /connect`'s own fields.
    static func sentence(_ one: JSON) -> String {
        let title = one["title"]?.asString ?? one["id"]?.asString ?? "It"
        let state = one["state"]?.asString ?? "not connected"
        let writes = one["writeTools"]?.asInt ?? 0, unattended = one["unattendedWrites"]?.asInt ?? 0
        var out = "\(title): \(state)"
        if let why = one["why"]?.asString, !why.isEmpty { out += ". \(why)" }
        if writes > 0 { out += ". \(writes) write \(writes == 1 ? "tool" : "tools"), \(unattended) allowed to run unattended" }
        return out + "."
    }

    /// The app whose id or title the words name, ignoring case, spaces and dashes.
    static func match(_ said: String, in apps: [JSON]) -> JSON? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = key(said)
        guard !want.isEmpty else { return nil }
        return apps.first { key($0["id"]?.asString ?? "") == want || key($0["title"]?.asString ?? "") == want }
            ?? apps.first { key($0["title"]?.asString ?? "").contains(want) }
    }

    /// A tool, every tool, or every write tool, allowed or not, in sync, in chat or both.
    public func setReach(app: String, tool: String, scope: String, allow: Bool) async -> Done {
        guard let (code, data) = await send("GET", "connect"), code == 200,
              let got = JSON.parse(String(decoding: data, as: UTF8.self)), let one = Self.match(app, in: got["apps"]?.asArray ?? []) else {
            return unreachable("connect", "\(app) \(tool)")
        }
        let id = one["id"]?.asString ?? app, title = one["title"]?.asString ?? app
        var body: [String: Any] = ["app": id, "tool": tool]
        if scope != "chat" { body["sync"] = allow }
        if scope != "sync" { body["chat"] = allow }
        guard let put = await send("PUT", "connect/tool", body: json(body)) else { return kept("connect", "\(title) \(tool)") }
        guard put.0 == 204 else {
            return Done(agent: "connect", line: "Connect didn't take it (\(put.0)): \(title) \(tool)", title: tool, ok: false)
        }
        let what = tool == "all" ? "every tool" : tool == "writes" ? "every write tool" : tool
        let where_ = scope == "everywhere" ? "" : " in \(scope)"
        return Done(agent: "connect", line: "\(title): \(what)\(where_) can\(allow ? "" : " no longer") be called.",
                    title: "\(title) \(what)", ok: true,
                    undo: .restore(app: "connect", path: id, before: nil, after: String(decoding: json(["app": id, "tool": tool,
                        "sync": scope != "chat" ? !allow : NSNull(), "chat": scope != "sync" ? !allow : NSNull()]), as: UTF8.self)),
                    link: URL(string: "glyph-connect://app/\(id)"))
    }

    /// the owner's switch, off. On is not a tool: it waits for his yes in the app.
    public func turnOffApp(_ app: String) async -> Done {
        guard let (code, data) = await send("GET", "connect"), code == 200,
              let got = JSON.parse(String(decoding: data, as: UTF8.self)), let one = Self.match(app, in: got["apps"]?.asArray ?? []) else {
            return unreachable("connect", app)
        }
        let id = one["id"]?.asString ?? app, title = one["title"]?.asString ?? app
        guard let put = await send("PUT", "connect/app", body: json(["app": id, "enabled": false])) else { return kept("connect", title) }
        guard put.0 == 204 else { return Done(agent: "connect", line: "Connect didn't take it (\(put.0)): \(title)", title: title, ok: false) }
        return Done(agent: "connect", line: "No agent can reach \(title) now.", title: title, ok: true,
                    undo: .restore(app: "connect", path: id, before: nil, after: String(decoding: json(["app": id, "enabled": true]), as: UTF8.self)),
                    link: URL(string: "glyph-connect://app/\(id)"))
    }

    /// Takes a Connect card back: the same route again with the values it had before (`after` carries them).
    func connectUndo(_ change: String) async -> Bool {
        guard let o = JSON.parse(change), let id = o["app"]?.asString else { return false }
        if let on = o["enabled"]?.asBool {
            return await send("PUT", "connect/app", body: json(["app": id, "enabled": on]))?.0 == 204
        }
        var body: [String: Any] = ["app": id, "tool": o["tool"]?.asString ?? ""]
        if let s = o["sync"]?.asBool { body["sync"] = s }
        if let c = o["chat"]?.asBool { body["chat"] = c }
        return await send("PUT", "connect/tool", body: json(body))?.0 == 204
    }
}
