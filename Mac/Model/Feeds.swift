import Foundation

/// The engine's read verbs Studio needs, as Decodable shapes taken from what the installed engine
/// prints (`prevail --vault <root> <verb> --json </dev/null`). Only the fields Studio uses; every
/// one optional unless the verb always prints it, so a new or missing field never breaks a page.
enum Feeds {
    // MARK: alignment --json

    struct Alignment: Decodable, Sendable {
        var ts: Double?
        var method: String? // model | signal
        var overall: Int
        var pillars: [Pillar]
        var actions: [String]?

        struct Pillar: Decodable, Sendable {
            var pillar: String
            var score: Int
            var trend: String? // up | flat | down
            var rationale: String?
            var domains: [String]?
        }
    }

    /// The default (model) method reuses the engine's cached report and calls a model at most once a
    /// day; `signal` asks for the cheap readiness proxy only.
    static func alignment(signal: Bool = false) async throws -> Alignment {
        try await Engine.json(["alignment"] + (signal ? ["--signal"] : []))
    }

    // MARK: waiting

    struct Waiting: Decodable, Sendable {
        var total: Int
        var items: [Item]

        struct Item: Decodable, Sendable {
            var id: String
            var kind: String? // task | loop | ...
            var domain: String?
            var summary: String?
            var since: Double? // ms
        }
    }

    static func waiting() async throws -> Waiting { try await Engine.json(["waiting"]) }

    // MARK: recommendations --json

    struct Recommendations: Decodable, Sendable {
        var recommendations: [Item]

        struct Item: Decodable, Sendable, Identifiable {
            var id: String
            var title: String
            var detail: String?
            var category: String?
            var source: String?
            var leverage: Double?
            var instruction: String?
            var metric: Metric?
            var task: TaskRef?

            struct Metric: Decodable, Sendable { var value: Double?; var unit: String? }
            struct TaskRef: Decodable, Sendable { var domain: String?; var text: String? }
        }
    }

    static func recommendations() async throws -> Recommendations { try await Engine.json(["recommendations"]) }

    // MARK: connectors list --json (vault and community connectors)

    struct Connector: Decodable, Sendable {
        var id: String
        var title: String?
        var integration: String? // api | browser | manual | mcp | mcp-remote
        var status: String?      // connected | configured | not-configured | expired | error
        var configured: Bool?
        var enabled: Bool?
        var domains: [String]?
        var lastSuccessTs: Double? // ms
        var lastError: String?
        var firstFetchOk: Bool?
    }

    static func connectors() async throws -> [Connector] { try await Engine.json(["connectors", "list"]) }

    // MARK: apps list --json (the harness apps mirror)

    struct Apps: Decodable, Sendable {
        var apps: [App]

        struct App: Decodable, Sendable {
            var id: String
            var name: String?
            var runtime: String?     // claude | codex | ...
            var server: String?
            var transport: String?   // remote | stdio
            var status: String?      // connected | needs_auth
            var integration: String? // null, or mcp-remote for a knowledge source
            var domains: [String]?
            var last_sync: Double?   // ms
            var last_error: String?
        }
    }

    static func apps() async throws -> Apps { try await Engine.json(["apps", "list"]) }

    // MARK: harness-connections --json

    struct HarnessConnections: Decodable, Sendable {
        var connections: [Connection]
        var notes: [String]?

        struct Connection: Decodable, Sendable {
            var id: String
            var harness: String   // claude | codex | gemini
            var name: String
            var transport: String?
            var source: String?   // account | local-config
            var health: String?   // healthy | degraded | nil (not checked)
            var url: String?
        }
    }

    static func harnessConnections() async throws -> HarnessConnections { try await Engine.json(["harness-connections"]) }

    // MARK: sources list --json (knowledge sources)

    struct KnowledgeSource: Decodable, Sendable {
        var id: String
        var name: String?
        var kind: String?   // mcp | web | folder | database
        var integration: String?
        var status: String? // ready | ...
        var found: String?
        var last_checked: Double? // ms
        var scope: Scope?

        struct Scope: Decodable, Sendable {
            var briefings: Bool?
            var general: Bool?
            var domains: [String]?
            var projects: [String]?
        }
    }

    static func knowledgeSources() async throws -> [KnowledgeSource] { try await Engine.json(["sources", "list"]) }

    // MARK: today show --json

    struct Today: Decodable, Sendable {
        var date: String?
        var generated: Double?
        var items: [Item]
        var alsoDue: [Item]?
        var fallingBehind: FallingBehind?
        var decisionDue: DecisionDue?
        var yourDay: YourDay?

        struct Item: Decodable, Sendable {
            var key: String
            var kind: String?
            var title: String
            var domain: String?
            var due: String?
            var why: String?
            var score: Double?
            var unlinked: Bool?
            var thread: [String]?
        }
        struct FallingBehind: Decodable, Sendable { var key: String?; var kind: String?; var text: String?; var count: Int? }
        struct DecisionDue: Decodable, Sendable { var question: String?; var due: String?; var domain: String?; var slug: String? }
        struct YourDay: Decodable, Sendable { var connected: Bool?; var note: String? }
    }

    static func today() async throws -> Today { try await Engine.json(["today", "show"]) }
}
