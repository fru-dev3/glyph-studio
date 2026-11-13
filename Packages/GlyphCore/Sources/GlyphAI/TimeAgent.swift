import Foundation
import FoundationModels
import GlyphVault

/// Glyph Time's agent. Time owns alarms (AlarmKit, its list, Undo, cancel), and iOS lets no other app arm
/// one, so the tools leave a request in Time's queue (GlyphVault `TimeRequest`); the driver then opens
/// `glyph-time://arm`, Time arms it, answers on the request's id and comes back. Time also sweeps the queue
/// on every launch. Nothing shows as set until Time answers.
extension GlyphAgent {
    public static let time = GlyphAgent(
        id: "time", name: "Time", color: "007A5E",
        instructions: "You are Glyph Time's agent. For a wake-up or alarm call request_alarm, for a reminder request_reminder, for a timer start_timer; to stop, pause or resume the running timer stop_timer, pause_timer, resume_timer. Use the person's own words for when.",
        tools: { hub, ledger in [RequestAlarm(hub: hub, ledger: ledger), RequestReminder(hub: hub, ledger: ledger), StartTimer(hub: hub, ledger: ledger),
                                    TimerCommand(name: "stop_timer", words: "stop the timer", hub: hub, ledger: ledger),
                                    TimerCommand(name: "pause_timer", words: "pause the timer", hub: hub, ledger: ledger),
                                    TimerCommand(name: "resume_timer", words: "resume the timer", hub: hub, ledger: ledger)] },
        fallback: { job, hub in hub.requestTime(kind: "alarm", command: job.instruction) })

    /// Opens Time to arm what was asked, and come back.
    public static let armLink = armLink(back: URL(string: "glyph-native://time"))
    /// Opens Time to arm what was asked, then back to `back` (the app that asked).
    public static func armLink(back: URL?) -> URL {
        var c = URLComponents(string: "glyph-time://arm")!
        if let back { c.queryItems = [URLQueryItem(name: "return", value: back.absoluteString)] }
        return c.url!
    }
}

public struct RequestAlarm: Tool {
    public let name = "request_alarm"
    public let description = "Ask Glyph Time for an alarm or wake-up."
    @Generable public struct Arguments {
        @Guide(description: "When, as said: in 2 hours, at 6:30 am, tomorrow at 7.") public var when: String
        @Guide(description: "A label, or empty.") public var label: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = hub.requestTime(kind: "alarm", command: "wake me up \(a.when)" + (a.label.isEmpty || a.label.lowercased().contains("wake") ? "" : " for \(a.label)")); await ledger.add(d); return d.line
    }
}

public struct RequestReminder: Tool {
    public let name = "request_reminder"
    public let description = "Ask Glyph Time for a reminder."
    @Generable public struct Arguments {
        @Guide(description: "When, as said: at 3 pm, every Wednesday at 9.") public var when: String
        @Guide(description: "What to be reminded of.") public var what: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = hub.requestTime(kind: "reminder", command: "remind me \(a.when) to \(a.what)"); await ledger.add(d); return d.line
    }
}

public struct StartTimer: Tool {
    public let name = "start_timer"
    public let description = "Ask Glyph Time to start a timer."
    @Generable public struct Arguments {
        @Guide(description: "How long, as said: 25 minutes. Empty for a running clock.") public var duration: String
        @Guide(description: "What it is for, or empty.") public var label: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let words = (a.label.isEmpty ? "timer" : a.label) + (a.duration.isEmpty ? "" : " for \(a.duration)")
        let d = hub.requestTime(kind: "timer", command: words); await ledger.add(d); return d.line
    }
}

/// Stop, pause or resume the running timer: no arguments; Time does it as it does the spoken command.
public struct TimerCommand: Tool {
    public let name: String
    public var description: String { "Ask Glyph Time to \(words)." }
    @Generable public struct Arguments {
        @Guide(description: "A label, or empty.") public var label: String?
    }
    let words: String
    let hub: Hub, ledger: Ledger
    public init(name: String, words: String, hub: Hub, ledger: Ledger) { self.name = name; self.words = words; self.hub = hub; self.ledger = ledger }
    public func call(arguments a: Arguments) async throws -> String {
        let d = hub.requestTime(kind: "timer", command: words); await ledger.add(d); return d.line
    }
}

extension Hub {
    public func requestTime(kind: String, command: String) -> Done {
        let id = UUID().uuidString
        TimeRequest.append(TimeRequest(id: id, event: "request", kind: kind, command: command, now: now()), to: timeQueue)
        return Done(agent: "time", line: command, ok: true, link: GlyphAgent.armLink, waiting: id)
    }
}
