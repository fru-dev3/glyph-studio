import Foundation
import Observation

/// One thing that brings data in: a connector, a harness app, a harness connection or a knowledge source.
struct Feed: Equatable, Sendable, Identifiable {
    /// How the data arrives.
    enum Path: String, Sendable {
        case harness    // an app connected in a harness (Claude, Codex, Gemini), mirrored by the engine
        case mcp        // an MCP server the engine reads itself
        case api        // a direct pull: an API connector or a web source
        case exportDrop // files the user drops: a folder or database source, an export connector
        case browser    // read in the browser, the way the user showed it (taught)
        case manual     // the user types or pastes it
    }
    enum Status: String, Sendable { case live, pending, needsAuth, error, off }
    enum Freshness: String, Sendable { case fresh, stale, old, never }

    var id: String   // "<origin>:<id>"
    var name: String
    var path: Path
    var status: Status
    var last: Date?
    var freshness: Freshness
    var domains: [String]
}

/// A measure and the feed that answers it, if any.
struct MeasureFeed: Equatable, Sendable {
    var measure: String
    /// The outcome it measures; nil for a domain metric (ideal-state "Metrics you track").
    var outcome: String?
    var feed: Feed?
    /// No live feed answers it.
    var blind: Bool { feed?.status != .live }
}

struct DomainSources: Equatable, Sendable {
    var domain: String
    var feeds: [Feed]
    var measures: [MeasureFeed]
    var blind: [MeasureFeed] { measures.filter(\.blind) }
}

/// Per domain, the feeds that bring data in and which measures they answer. A measure names its
/// feed with `~from:<feed id>` (`measure: runs per week ~from:garmin`), or by mentioning a feed's
/// id or name; anything no live feed answers is blind.
@MainActor @Observable
final class SourcesModel {
    var byDomain: [String: DomainSources] = [:]
    /// Feeds that name no domain (most harness connections).
    var unassigned: [Feed] = []
    var problem: String?

    func refresh(contracts: [DomainContract]) async {
        async let c = Feeds.connectors()
        async let a = Feeds.apps()
        async let h = Feeds.harnessConnections()
        async let s = Feeds.knowledgeSources()
        do {
            let feeds = try await Self.feeds(connectors: c, apps: a, harness: h, sources: s)
            (byDomain, unassigned) = Self.join(feeds, contracts)
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    // MARK: pure parts (tested)

    nonisolated static func feeds(connectors: [Feeds.Connector], apps: Feeds.Apps, harness: Feeds.HarnessConnections,
                                  sources: [Feeds.KnowledgeSource], now: Date = .now) -> [Feed] {
        let date = { (ms: Double?) in ms.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil } }
        var out: [Feed] = []
        for c in connectors where c.enabled != false {
            let path: Feed.Path = switch c.integration {
            case "mcp", "mcp-remote": .mcp
            case "api", "web": .api
            case "browser": .browser
            case "export", "file", "folder", "drop": .exportDrop
            default: .manual
            }
            let status: Feed.Status = switch c.status {
            case "connected": .live
            case "configured": c.firstFetchOk == true ? .live : .pending
            case "expired": .needsAuth
            case "error": .error
            default: .off
            }
            out.append(feed("connector:\(c.id)", c.title ?? c.id, path, status, date(c.lastSuccessTs), c.domains ?? [], now))
        }
        var mirrored = Set<String>()
        for app in apps.apps {
            let status: Feed.Status = switch app.status {
            case "connected": .live
            case "needs_auth": .needsAuth
            default: .error
            }
            let name = app.name ?? app.id
            mirrored.insert("\(app.runtime ?? "")|\(name.lowercased())")
            out.append(feed("app:\(app.id)", name, app.integration == "mcp-remote" ? .mcp : .harness, status, date(app.last_sync), app.domains ?? [], now))
        }
        // A connection the apps mirror already carries (same harness, same name) is that app.
        for c in harness.connections where !mirrored.contains("\(c.harness)|\(c.name.lowercased())") {
            let status: Feed.Status = switch c.health {
            case "healthy": .live
            case "degraded": .error
            default: .pending
            }
            out.append(feed("harness:\(c.harness):\(c.id):\(c.name)", c.name, .harness, status, nil, [], now))
        }
        for s in sources {
            let path: Feed.Path = switch s.kind {
            case "mcp": .mcp
            case "folder", "database": .exportDrop
            default: .api
            }
            var domains = s.scope?.domains ?? []
            if s.scope?.general == true { domains.append("general") }
            out.append(feed("source:\(s.id)", s.name ?? s.id, path, s.status == "ready" ? .live : .error, date(s.last_checked), domains, now))
        }
        return out
    }

    nonisolated static func freshness(_ last: Date?, now: Date) -> Feed.Freshness {
        guard let last else { return .never }
        let days = now.timeIntervalSince(last) / 86_400
        return days <= 2 ? .fresh : days <= 14 ? .stale : .old
    }

    nonisolated static func join(_ feeds: [Feed], _ contracts: [DomainContract]) -> ([String: DomainSources], [Feed]) {
        var by: [String: DomainSources] = [:]
        for c in contracts {
            let mine = feeds.filter { $0.domains.contains(c.slug) }
            let measures = c.metrics.map { MeasureFeed(measure: $0, outcome: nil, feed: match($0, mine, feeds)) }
                + c.outcomes.filter { $0.status != "done" && $0.status != "archived" }
                .flatMap { o in o.measures.map { MeasureFeed(measure: $0, outcome: o.id, feed: match($0, mine, feeds)) } }
            by[c.slug] = DomainSources(domain: c.slug, feeds: mine, measures: measures)
        }
        return (by, feeds.filter(\.domains.isEmpty))
    }

    /// `~from:<id>` first (any feed), then a mention of a feed's id or name, the domain's own first;
    /// a live feed wins over one that is not.
    nonisolated static func match(_ measure: String, _ mine: [Feed], _ all: [Feed]) -> Feed? {
        let text = measure.lowercased()
        let bare = { (f: Feed) in String(f.id.split(separator: ":").dropFirst().first ?? "").lowercased() }
        if let from = text.split(separator: " ").first(where: { $0.hasPrefix("~from:") })?.dropFirst(6) {
            let hits = all.filter { bare($0) == from || $0.id.lowercased() == from || $0.name.lowercased() == from }
            return hits.first { $0.status == .live } ?? hits.first
        }
        let mentions = { (f: Feed) -> Bool in
            let id = bare(f), name = f.name.lowercased()
            return (id.count >= 3 && text.contains(id)) || (name.count >= 3 && text.contains(name))
        }
        let hits = mine.filter(mentions)
        return hits.first { $0.status == .live } ?? hits.first
    }

    nonisolated private static func feed(_ id: String, _ name: String, _ path: Feed.Path, _ status: Feed.Status,
                                          _ last: Date?, _ domains: [String], _ now: Date) -> Feed {
        Feed(id: id, name: name, path: path, status: status, last: last, freshness: freshness(last, now: now), domains: domains)
    }
}
