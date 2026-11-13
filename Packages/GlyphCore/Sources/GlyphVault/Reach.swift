import Foundation

/// What an agent can reach, in five words and nothing between them. Glyph Connect's whole UI keys off
/// this: the dot, the grouping, the order, the counts. It lives here, not in the app, so the Mac app,
/// the iPhone and the agent all say the same word about the same app.
public enum ReachState: String, Sendable, CaseIterable {
    /// Fru turned it off. Nothing may reach it. Outranks everything, including a broken token: an app
    /// he switched off must never nag him.
    case off
    /// It would work, but the sign-in is gone. There is one step, and it takes 30 seconds.
    case needsYou
    /// Signed in, but the last sync broke, or it is overdue. May need a look at the error.
    case failing
    /// Reachable and healthy.
    case open
    /// In the registry, but nothing reaches it. Most of them.
    case notConnected

    /// What the UI writes beside the dot. A colour alone fails at a glance and in a screenshot.
    public var words: String {
        switch self {
        case .off: "off"
        case .needsYou: "needs you"
        case .failing: "failing"
        case .open: "open"
        case .notConnected: "not connected"
        }
    }

    /// The order the Connections list groups by: what he came for, first.
    public static let grouped: [ReachState] = [.needsYou, .failing, .open, .off, .notConnected]
    /// Something an agent can reach right now.
    public var reachable: Bool { self == .open || self == .needsYou || self == .failing }
}

/// What one connector definition says about itself, as the Glyph Bot engine reports it
/// (`prevail connectors list --json`). Only the fields the state needs; nil when there is no
/// connector for that app at all, which is the usual case.
public struct ConnectorHealth: Equatable, Sendable {
    public var id: String
    public var status: String          // not-configured, expired, ok
    public var configured: Bool
    public var enabled: Bool
    public var lastError: String?
    public var lastSuccess: Date?
    public var nextDue: Date?
    public var authEnvVars: [String]
    public var integration: String
    public var schedule: String?       // "daily at 06:30"

    public init(id: String, status: String, configured: Bool, enabled: Bool = true, lastError: String? = nil, lastSuccess: Date? = nil,
                nextDue: Date? = nil, authEnvVars: [String] = [], integration: String = "", schedule: String? = nil) {
        self.id = id; self.status = status; self.configured = configured; self.enabled = enabled; self.lastError = lastError
        self.lastSuccess = lastSuccess; self.nextDue = nextDue; self.authEnvVars = authEnvVars; self.integration = integration
        self.schedule = schedule
    }

    /// An error about signing in, as against an error about the sync itself. The two get different
    /// states because only the first has a 30-second fix.
    public var authProblem: Bool {
        guard let e = lastError?.lowercased() else { return status == "expired" }
        return status == "expired" || e.contains("auth") || e.contains("token") || e.contains("missing env")
            || e.contains("unauthorized") || e.contains("401") || e.contains("403") || e.contains("credential")
    }
}

/// Which MCP servers this machine's runtimes have actually connected. Per machine on purpose: a
/// connector can be open on one Mac and absent on another, and pretending there is one answer makes
/// the app wrong on the machine Fru is not sitting at.
public struct RuntimeReach: Equatable, Sendable {
    /// Server names a runtime has signed into at least once ("claude.ai Gmail").
    public var connected: Set<String> = []
    /// Server names the runtime has flagged as needing signing in again.
    public var needsAuth: Set<String> = []
    /// Locally configured servers, by name ("prevail").
    public var local: Set<String> = []
    /// Which runtime this came from, for the sentence the app shows.
    public var runtime = "claude"
    public init() {}

    public var summary: String {
        "\(runtime): \(connected.count) connected, \(needsAuth.count) need signing in, \(local.count) local"
    }
}

public enum Runtimes {
    /// Claude Code's own config on this machine. Read only, and only these three keys.
    public static func claude(home: URL = URL(filePath: NSHomeDirectory())) -> RuntimeReach {
        var r = RuntimeReach()
        r.runtime = "Claude"
        guard let text = try? String(contentsOf: home.appending(path: ".claude.json"), encoding: .utf8),
              let o = JSON.parse(text) else { return r }
        r.connected = Set(o["claudeAiMcpEverConnected"]?.strings ?? [])
        r.needsAuth = Set(o["mcpNeedsAuthNoticed"]?.strings ?? [])
        r.local = Set((o["mcpServers"]?.asPairs ?? []).map(\.0))
        return r
    }

    /// Codex's config. Its servers are TOML table headers (`[mcp_servers.<name>]`), so this reads the
    /// headers rather than parsing TOML: nothing else in the file is needed.
    public static func codex(home: URL = URL(filePath: NSHomeDirectory())) -> RuntimeReach {
        var r = RuntimeReach()
        r.runtime = "Codex"
        guard let text = try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8) else { return r }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[mcp_servers."), t.hasSuffix("]") else { continue }
            let rest = t.dropFirst("[mcp_servers.".count).dropLast()
            guard !rest.contains(".") else { continue }   // a per-tool table, not a server
            r.local.insert(String(rest))
        }
        return r
    }

    /// One app's state, and why, in plain words. Precedence is the table in Connect/docs/design.md:
    /// off, needs you, failing, open, not connected. First match wins.
    ///
    /// `connector` is nil when nothing asked the engine (the agent's `GET /connect` does not shell out
    /// to it); the state is then decided on the registry and the runtimes alone, which is strictly less
    /// information and never a different answer for the same facts.
    public static func state(_ app: AppEntry, runtimes: [RuntimeReach], connector: ConnectorHealth?, now: Date = .now) -> (ReachState, String) {
        if !app.enabled { return (.off, "You switched this off.") }

        let server = app.mirrorServer
        let flagged = server.map { s in runtimes.contains { $0.needsAuth.contains(s) } } ?? false
        if flagged, let which = runtimes.first(where: { $0.needsAuth.contains(server!) }) {
            return (.needsYou, "\(which.runtime) says this one needs signing in again.")
        }
        if let c = connector, c.authProblem {
            if !c.authEnvVars.isEmpty, c.lastError?.contains("missing env") == true {
                let n = c.authEnvVars.count
                return (.needsYou, "\(n) \(n == 1 ? "key is" : "keys are") missing, so the sync has not run.")
            }
            return (.needsYou, c.status == "expired" ? "The sign-in has expired." : (c.lastError ?? "The sign-in needs doing again."))
        }
        if let c = connector {
            if let e = c.lastError, !e.isEmpty { return (.failing, "The last sync failed.") }
            if let due = c.nextDue, due < now.addingTimeInterval(-86400) {
                return (.failing, "Overdue since \(stamp(due)).")
            }
        }

        if let s = server, runtimes.contains(where: { $0.connected.contains(s) }) {
            let which = runtimes.first { $0.connected.contains(s) }?.runtime ?? "A runtime"
            return (.open, "\(which) has had this connected since you signed in.")
        }
        if runtimes.contains(where: { $0.local.contains(app.id) }) {
            return (.open, "A local server on this machine.")
        }
        if let c = connector, c.configured, c.lastError == nil {
            return (.open, c.lastSuccess == nil ? "Set up, and it has not failed." : "Last synced \(stamp(c.lastSuccess!)).")
        }
        if connector == nil, app.mirrorServer == nil, app.tools.isEmpty {
            return (.notConnected, "No connector and no tools: a folder of notes, not a connection.")
        }
        return (.notConnected, connector == nil ? "Nothing on this machine reaches this." : "Not set up yet.")
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d)
    }
}
