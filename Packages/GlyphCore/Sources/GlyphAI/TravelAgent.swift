import Foundation
import FoundationModels
import GlyphVault

/// Glyph Travel's agent: trips and what they are made of, as Travel's own lines in this device's
/// month file (Glyph Travel pulls them in and lists them). Anything with a time on it is Glyph
/// Time's: the planner hands that over as a `time` job, and this agent has no reminder tool.
extension GlyphAgent {
    public static let travel = GlyphAgent(
        id: "travel", name: "Travel", color: "1E6F5C",
        instructions: """
        You are Glyph Travel's agent. A trip they are taking or thinking about goes in with add_trip, \
        named in 1 to 4 of their own words. One thing on one day of a trip (a flight, where they are \
        staying, a booking, something to do) goes in with add_plan. Anything else worth keeping about a \
        trip goes in with travel_note. Never set an alarm or a reminder: Glyph Time owns those. Never \
        say anything is booked, held or paid.
        """,
        tools: { hub, ledger in [AddTrip(hub: hub, ledger: ledger), AddPlan(hub: hub, ledger: ledger),
                                 TravelNote(hub: hub, ledger: ledger)] },
        fallback: { job, hub in await hub.addTrip(name: job.name.isEmpty ? job.instruction : job.name,
                                                  place: "", when: "", why: job.instruction) })
}

public struct AddTrip: Tool {
    public let name = "add_trip"
    public let description = "Add a trip to Glyph Travel: somewhere they are going or thinking about going."
    @Generable public struct Arguments {
        @Guide(description: "1 to 4 words naming the trip, like Peru, Coast Range.") public var name: String
        @Guide(description: "Where, as said. Empty when not said.") public var place: String
        @Guide(description: "When, as said: March 19 to March 31, in July, next weekend. Empty when not said.") public var when: String
        @Guide(description: "Why they are going, in their words. Empty when not said.") public var why: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addTrip(name: a.name, place: a.place, when: a.when, why: a.why)
        await ledger.add(d); return d.line
    }
}

public struct AddPlan: Tool {
    public let name = "add_plan"
    public let description = "Add one thing on one day of a trip: a flight, where they are staying, a booking, something to do."
    @Generable public struct Arguments {
        @Guide(description: "1 to 6 words for the thing, like Flight to Westbay, Harbour Rooms.") public var what: String
        @Guide(description: "Which trip, by its name as they said it. Empty for the next one.") public var trip: String
        @Guide(description: "The day, as said: March 19, tomorrow, the 3rd. Empty when not said.") public var day: String
        @Guide(description: "A confirmation or booking number, exactly as said. Empty when none.") public var reference: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addTravelPlan(what: a.what, trip: a.trip, day: a.day, reference: a.reference)
        await ledger.add(d); return d.line
    }
}

public struct TravelNote: Tool {
    public let name = "travel_note"
    public let description = "Keep something about a trip in Glyph Travel, in their own words."
    @Generable public struct Arguments {
        @Guide(description: "What to keep, as said.") public var text: String
        @Guide(description: "Which trip, by its name as they said it. Empty for the next one.") public var trip: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.travelNote(a.text, trip: a.trip); await ledger.add(d); return d.line
    }
}

extension Hub {
    /// A trip, as Glyph Travel's own line. Undo is Travel's delete line.
    public func addTrip(name: String, place: String, when: String, why: String) async -> Done {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty ? trimmed : Self.cap(trimmed)
        guard !words.isEmpty else { return Done(agent: "travel", line: "No trip heard", title: "No trip heard", ok: false) }
        let id = UUID().uuidString
        let line = TravelLine.trip(id: id, name: words, place: place, when: when, why: why, host: host, device: device, now: now())
        return await write(line, id: id, said: words, how: "Trip in Travel")
    }

    /// One thing on one day. Travel works out which trip and which day from the words.
    public func addTravelPlan(what: String, trip: String, day: String, reference: String) async -> Done {
        let trimmed = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty ? trimmed : Self.cap(trimmed)
        guard !words.isEmpty else { return Done(agent: "travel", line: "Nothing to add", title: "Nothing to add", ok: false) }
        let id = UUID().uuidString
        let line = TravelLine.plan(id: id, name: words, trip: trip, day: day, reference: reference,
                                   host: host, device: device, now: now())
        return await write(line, id: id, said: words, how: "Added in Travel")
    }

    public func travelNote(_ text: String, trip: String) async -> Done {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return Done(agent: "travel", line: "Nothing heard", title: "Nothing heard", ok: false) }
        let id = UUID().uuidString
        let line = TravelLine.note(id: id, text: words, trip: trip, host: host, device: device, now: now())
        return await write(line, id: id, said: String(words.prefix(60)), how: "Noted in Travel")
    }

    func write(_ line: String, id: String, said: String, how: String) async -> Done {
        let code = await put("travel/\(TravelLine.file(now(), host: host))", body: Data(line.utf8), type: "application/x-ndjson")
        if code == nil { return kept("travel", said) }
        guard code == 204 else {
            return Done(agent: "travel", line: "Travel didn't take it (\(code!)): \(said)", title: said, ok: false)
        }
        return Done(agent: "travel", line: "\(how): \(said)", title: said, ok: true,
                    undo: .travelDelete(id: id), link: URL(string: "glyph-travel://trips"))
    }
}
