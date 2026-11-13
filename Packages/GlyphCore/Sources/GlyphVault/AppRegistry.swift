import Foundation

/// The vault's app registry: `data/apps/<folder>/manifest.json`, one folder per external system
/// Fru's agents might reach. It already existed before Glyph Connect (Glyph Bot's engine
/// scaffolds it, `prevail connectors` runs it); Connect is a window onto it and the only app that
/// edits which tools may be called.
///
/// A write touches six keys and nothing else: `enabled`, `domains`, `lifecycle`, `autonomy`, and
/// per tool `sync_allowed` and `chat_default`. Everything else in the file keeps its bytes, which
/// is why this goes through `JSON` (order-preserving, two-space, trailing newline) and never
/// through JSONSerialization.

/// One tool a connected app exposes to agents, with the two permissions the registry keeps.
public struct AppTool: Equatable, Sendable, Identifiable {
    public var name: String
    /// The MCP name an agent would call ("mcp__claude_ai_Gmail__send_message").
    public var fullName: String
    /// "read" or "write" as the registry labels it; anything else is treated as a write.
    public var kind: String
    /// May a scheduled, unattended sync call this?
    public var syncAllowed: Bool
    /// May an agent call this while Fru is in the conversation?
    public var chatDefault: Bool
    public var id: String { name }
    /// A tool that changes something outside the vault. Unknown kinds count as writes: the safe guess.
    public var writes: Bool { kind != "read" }

    public init(name: String, fullName: String = "", kind: String = "write", syncAllowed: Bool = false, chatDefault: Bool = true) {
        self.name = name; self.fullName = fullName; self.kind = kind; self.syncAllowed = syncAllowed; self.chatDefault = chatDefault
    }
}

/// One app folder in the registry, as Connect reads it.
public struct AppEntry: Equatable, Sendable, Identifiable {
    public var id: String
    /// The folder on disk, which is not always the id ("American Express", "Chase").
    public var folder: String
    public var title: String
    public var integration: String       // mcp, mcp-remote, api, oauth, cli, browser, manual
    public var domains: [String]
    public var tools: [AppTool]
    /// `enabled: false` is the owner's switch: nothing may reach it. Absent means on.
    public var enabled: Bool
    public var autonomy: String?         // "read-only" when the registry says so
    public var lifecycle: String?        // "in use", "unused", "trial"
    public var summary: String?          // `description` or `connection`, a plain sentence
    public var account: String?          // the account label, when one is named
    public var mirrorRuntime: String?    // "claude", "codex": whose MCP list it was mirrored from
    public var mirrorServer: String?     // "claude.ai Gmail", the runtime's own name for it
    public var mirrorURL: String?
    /// When the tool list was last read from the runtime, in milliseconds.
    public var toolsCheckedAt: Double?

    public var writeTools: [AppTool] { tools.filter(\.writes) }
    public var readTools: [AppTool] { tools.filter { !$0.writes } }
    /// Write tools a scheduled sync may call with nobody watching: the number that matters most.
    public var unattendedWrites: Int { tools.filter { $0.writes && $0.syncAllowed }.count }

    public init(id: String, folder: String, title: String, integration: String, domains: [String] = [], tools: [AppTool] = [],
                enabled: Bool = true, autonomy: String? = nil, lifecycle: String? = nil, summary: String? = nil, account: String? = nil,
                mirrorRuntime: String? = nil, mirrorServer: String? = nil, mirrorURL: String? = nil, toolsCheckedAt: Double? = nil) {
        self.id = id; self.folder = folder; self.title = title; self.integration = integration; self.domains = domains
        self.tools = tools; self.enabled = enabled; self.autonomy = autonomy; self.lifecycle = lifecycle; self.summary = summary
        self.account = account; self.mirrorRuntime = mirrorRuntime; self.mirrorServer = mirrorServer; self.mirrorURL = mirrorURL
        self.toolsCheckedAt = toolsCheckedAt
    }
}

/// One line of `data/apps/<id>/_log/access.jsonl`: a tool an agent actually called. Read only;
/// Connect never appends here (the runtimes and the engine write it).
public struct AccessLine: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var app: String
    public var at: Date
    public var tool: String
    public var access: String       // read, write
    public var outcome: String      // ran, blocked_by_egress_guard, failed
    public var domain: String
    public var summary: String
    public var writes: Bool { access != "read" }
    /// An attempt something stopped: the most interesting line in the file.
    public var blocked: Bool { outcome != "ran" }
}

public enum AppRegistry {
    public static func folder(vault: URL) -> URL { vault.appending(path: "data/apps") }

    /// Every app folder with a manifest, by title. Folders that start with `_` are the registry's
    /// own (`_log`, `_archive`) and are not apps.
    public static func read(vault: URL) -> [AppEntry] {
        let root = folder(vault: vault)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .compactMap { entry(vault: vault, folder: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// One app by its folder name.
    public static func entry(vault: URL, folder name: String) -> AppEntry? {
        let file = folder(vault: vault).appending(path: name).appending(path: "manifest.json")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let m = JSON.parse(text) else { return nil }
        return entry(m, folder: name)
    }

    /// One app by its id, which is not always its folder name.
    public static func entry(vault: URL, id: String) -> AppEntry? {
        read(vault: vault).first { $0.id == id }
    }

    /// A parsed manifest as an entry. Anything missing falls back to something honest, never to a guess.
    public static func entry(_ m: JSON, folder name: String) -> AppEntry {
        let id = m["id"]?.asString ?? name
        let tools = (m["tools"]?.asArray ?? []).compactMap { t -> AppTool? in
            guard let n = t["name"]?.asString else { return nil }
            return AppTool(name: n, fullName: t["full_name"]?.asString ?? "", kind: t["kind"]?.asString ?? "write",
                           syncAllowed: t["sync_allowed"]?.asBool ?? false, chatDefault: t["chat_default"]?.asBool ?? true)
        }
        return AppEntry(
            id: id, folder: name,
            title: m["title"]?.asString ?? m["name"]?.asString ?? id,
            integration: m["integration"]?.asString ?? "manual",
            domains: m["domains"]?.strings ?? [], tools: tools,
            enabled: m["enabled"]?.asBool ?? true,
            autonomy: m["autonomy"]?.asString, lifecycle: m["lifecycle"]?.asString,
            summary: m["connection"]?.asString ?? m["description"]?.asString ?? m["summary"]?.asString,
            account: m["account"]?["label"]?.asString,
            mirrorRuntime: m["mirror"]?["runtime"]?.asString ?? m["runtime"]?.asString,
            mirrorServer: m["mirror"]?["server"]?.asString,
            mirrorURL: m["mirror"]?["url"]?.asString,
            toolsCheckedAt: m["tools_checked_at"]?.asDouble)
    }

    // MARK: Writing, six keys only
    //
    // A write splices over the one value's bytes (JSONEdit) rather than reprinting the file. The
    // registry is written in three dialects (members one per line, short arrays inline, and
    // Foundation's `"key" : value` with sorted keys), so any single printer would churn the other
    // two. Splicing keeps whatever a file already is.

    public enum WriteError: Error { case noSuchApp(String), unreadable(String) }

    /// Reads the manifest's text, hands it to `change`, writes it back when it changed. Everything
    /// `change` does not splice keeps its bytes, its order and its spacing.
    public static func edit(vault: URL, id: String, _ change: (String) -> String) throws {
        guard let app = entry(vault: vault, id: id) else { throw WriteError.noSuchApp(id) }
        let url = folder(vault: vault).appending(path: app.folder).appending(path: "manifest.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw WriteError.unreadable(id) }
        let out = change(text)
        guard out != text else { return }
        try Data(out.utf8).write(to: url, options: .atomic)
    }

    /// the owner's switch. Off writes `enabled: false`; on takes the key off again, so an app he never
    /// touched goes back to exactly the bytes it always had.
    public static func setEnabled(vault: URL, id: String, _ on: Bool) throws {
        try edit(vault: vault, id: id) { JSONEdit.set($0, key: "enabled", to: on ? nil : "false") }
    }

    /// One tool's two permissions. Pass nil to leave one of them as it is.
    public static func setTool(vault: URL, id: String, tool: String, sync: Bool? = nil, chat: Bool? = nil) throws {
        try edit(vault: vault, id: id) { text in
            var out = text
            if let sync { out = JSONEdit.setInTool(out, tool: tool, key: "sync_allowed", to: sync ? "true" : "false") }
            if let chat { out = JSONEdit.setInTool(out, tool: tool, key: "chat_default", to: chat ? "true" : "false") }
            return out
        }
    }

    /// Every tool of one kind at once ("no write tool may run unattended"), the gesture that matters
    /// most. One splice at a time, re-reading the shapes each time, because a splice moves the rest.
    public static func setTools(vault: URL, id: String, writes: Bool?, sync: Bool? = nil, chat: Bool? = nil) throws {
        try edit(vault: vault, id: id) { text in
            var out = text
            for t in JSONEdit.toolNames(text) {
                let isWrite = t.kind != "read"
                guard writes == nil || writes == isWrite else { continue }
                if let sync { out = JSONEdit.setInTool(out, tool: t.name, key: "sync_allowed", to: sync ? "true" : "false") }
                if let chat { out = JSONEdit.setInTool(out, tool: t.name, key: "chat_default", to: chat ? "true" : "false") }
            }
            return out
        }
    }

    public static func setDomains(vault: URL, id: String, _ domains: [String]) throws {
        // Written the way this file writes its arrays: inline when its own was, else one per line.
        try edit(vault: vault, id: id) { text in
            let inline = (JSONEdit.shape(text)?.member("domains")).map { !text[$0.valueRange].contains("\n") } ?? true
            let items = domains.map { "\"" + $0 + "\"" }
            guard !items.isEmpty else { return JSONEdit.set(text, key: "domains", to: "[]") }
            if inline { return JSONEdit.set(text, key: "domains", to: "[" + items.joined(separator: ", ") + "]") }
            let indent = JSONEdit.shape(text)?.indent ?? "  "
            let inner = items.map { indent + indent + $0 }.joined(separator: ",\n")
            return JSONEdit.set(text, key: "domains", to: "[\n" + inner + "\n" + indent + "]")
        }
    }

    // MARK: What agents actually did

    /// The last `limit` lines of one app's access log, newest first. Empty when there is no log.
    public static func access(vault: URL, folder name: String, app: String, limit: Int = 10) -> [AccessLine] {
        let file = folder(vault: vault).appending(path: name).appending(path: "_log/access.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").compactMap { line -> AccessLine? in
            guard let o = JSON.parse(String(line)), let ms = o["ts"]?.asDouble else { return nil }
            return AccessLine(app: app, at: Date(timeIntervalSince1970: ms / 1000),
                              tool: o["tool"]?.asString ?? "?", access: o["access"]?.asString ?? "write",
                              outcome: o["outcome"]?.asString ?? "ran", domain: o["domain"]?.asString ?? "",
                              summary: o["summary"]?.asString ?? "")
        }
        return lines.sorted { $0.at > $1.at }.prefix(limit).map { $0 }
    }

    /// Every app's access log together, newest first: the Activity screen.
    public static func allAccess(vault: URL, apps: [AppEntry], limit: Int = 200) -> [AccessLine] {
        apps.flatMap { access(vault: vault, folder: $0.folder, app: $0.title, limit: limit) }
            .sorted { $0.at > $1.at }.prefix(limit).map { $0 }
    }
}
