import Foundation
import FoundationModels
import GlyphVault

/// Apple's on-device model (Apple Intelligence): whether it can run on this Mac.
public enum OnDeviceModel {
    public enum Status: Equatable, Sendable {
        case available, appleIntelligenceOff, modelNotReady, deviceNotEligible, unavailable
    }

    public static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceOff
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable: .unavailable
        }
    }
}

/// Why notes could not be written. The message is ready to show.
public enum AIError: LocalizedError, Equatable, Sendable {
    case unavailable(OnDeviceModel.Status)
    case emptyTranscript
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(.appleIntelligenceOff): "Turn on Apple Intelligence in System Settings to write summaries on this Mac."
        case .unavailable(.modelNotReady): "Apple's on-device model is still downloading. Try again in a few minutes."
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model."
        case .unavailable: "Apple's on-device model isn't available right now."
        case .emptyTranscript: "This conversation has no transcript to summarize yet."
        case .failed(let message): message
        }
    }

    static func check() throws {
        let status = OnDeviceModel.status
        if status != .available { throw AIError.unavailable(status) }
    }
}

@Generable
struct GeneratedNotes {
    @Guide(description: "A 2 to 4 sentence overview of the conversation")
    var summary: String
    @Guide(description: "Each concrete decision that was made, as a short sentence. Empty when none.", .maximumCount(10))
    var decisions: [String]
    @Guide(description: "Each task a speaker said they or someone else will do, as a short instruction. Only tasks the transcript states, never ones it only suggests. Empty when none.", .maximumCount(15))
    var actions: [GeneratedAction]
}

@Generable
struct GeneratedAction {
    @Guide(description: "The task, short, starting with a verb")
    var text: String
    @Guide(description: "The person who owns it, only when the conversation says so")
    var owner: String?
    @Guide(description: "The due date as YYYY-MM-DD, only when the conversation states one")
    var due: String?
}

/// Writes notes (summary, decisions, action items with owner and due date) from a
/// transcript with Apple's on-device model. The model reads about 4,096 tokens at a
/// time, so a long call is noted part by part (about 7,000 characters each) and the
/// notes are summarized.
///
/// ```swift
/// let notes = try await Summarizer().summarize(id, in: vault)   // also writes notes.md
/// ```
public struct Summarizer: Sendable {
    static let partCharacters = 7_000

    public init() {}

    /// Summarizes a conversation's transcript and writes its `notes.md`.
    @discardableResult
    public func summarize(_ id: String, in vault: Vault) async throws -> Notes {
        let meta = try vault.conversation(id)
        let notes = try await summarize(vault.transcript(id), title: meta.title, date: String(meta.created.prefix(10)), people: meta.people)
        try vault.writeNotes(notes, for: id)
        return notes
    }

    /// Notes for a transcript. `date` (`YYYY-MM-DD`) is when it was recorded, so "Friday" can become a date.
    /// `people` are the linked people: an owner said as a first name gets their full name.
    public func summarize(_ transcript: GlyphVault.Transcript, title: String, date: String, people: [String] = []) async throws -> Notes {
        let source = transcript.plainText
        var body = source
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyTranscript }
        try AIError.check()
        do {
            for _ in 0..<3 where body.count > Summarizer.partCharacters { body = try await noteParts(body) }
            do {
                return Summarizer.notes(from: try await generate(body, title: title, date: date), heard: source, people: people)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                return Summarizer.notes(from: try await generate(noteParts(body), title: title, date: date), heard: source, people: people)
            }
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.failed("On-device AI failed: \(error.localizedDescription)")
        }
    }

    private func generate(_ body: String, title: String, date: String) async throws -> GeneratedNotes {
        let prompt = Summarizer.prompt(title: title, date: date, transcript: body)
        do {
            return try await LanguageModelSession(instructions: Summarizer.instructions).respond(to: prompt, generating: GeneratedNotes.self).content
        } catch LanguageModelSession.GenerationError.decodingFailure {
            // Seen now and then on long inputs; a fresh session usually answers.
            return try await LanguageModelSession(instructions: Summarizer.instructions).respond(to: prompt, generating: GeneratedNotes.self).content
        }
    }

    /// Short notes on each part, joined: shorter than the parts, nothing skipped.
    private func noteParts(_ text: String) async throws -> String {
        var notes: [String] = []
        for part in Summarizer.parts(text, max: Summarizer.partCharacters) { notes.append(try await note(part)) }
        return notes.joined(separator: "\n\n")
    }

    /// Notes on one part. The answer is capped, since on a repetitive part the model can
    /// write until the window is full; a part that still overflows is noted in halves.
    private func note(_ part: String) async throws -> String {
        do {
            return try await LanguageModelSession().respond(to: Summarizer.partPrompt(part), options: GenerationOptions(maximumResponseTokens: 400)).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where part.count > 1_000 {
            var halves: [String] = []
            for half in Summarizer.parts(part, max: part.count / 2 + 1) { halves.append(try await note(half)) }
            return halves.joined(separator: "\n")
        }
    }

    static let instructions = """
        You write meeting notes for the person who recorded this conversation. Use only what \
        the transcript says. Never invent people, owners, dates or tasks: an action item is only \
        something someone in the conversation said will be done. Leave a list empty rather than guess.
        """

    static func prompt(title: String, date: String, transcript: String) -> String {
        """
        Write notes on the conversation "\(title)", recorded on \(date): a 2 to 4 sentence summary, \
        every decision, and every action item with its owner and due date when the conversation \
        states them. A weekday like "Friday" means the next one after \(date).

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func partPrompt(_ part: String) -> String {
        """
        This is one part of a longer conversation transcript. Write short notes on it: the key \
        points, every decision, and every action item with its owner and date when said. Plain \
        bullet points, no preamble.

        TRANSCRIPT PART:
        \(part)
        """
    }

    /// Splits on line ends into parts of at most `max` characters; a longer line is cut
    /// into pieces, never dropped.
    static func parts(_ text: String, max: Int) -> [String] {
        var out = [""]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            repeat {
                let piece = rest.prefix(max - 1)
                rest = rest.dropFirst(piece.count)
                if !out[out.count - 1].isEmpty, out[out.count - 1].count + piece.count + 1 > max { out.append("") }
                out[out.count - 1] += piece + "\n"
            } while !rest.isEmpty
        }
        return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The model's answer as notes: blanks and repeats dropped, "none" owners and
    /// non-dates cleared. The model can invent an owner or a date, so an owner is kept
    /// only when the transcript says one of their names, and a date only when the
    /// transcript names that day. An owner who is one linked person's first name (or
    /// other short form) becomes that person's full name.
    static func notes(from g: GeneratedNotes, heard transcript: String, people: [String] = []) -> Notes {
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // The model fills an empty list with a placeholder now and then: "None.", "N/A",
        // "No other action items mentioned".
        let placeholder = { (t: String) in
            let l = t.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            return ["", "null", "none", "n/a", "na", "tbd", "unknown", "nothing"].contains(l)
                || (l.hasPrefix("no ") && l.split(separator: " ").count <= 6
                    && ["action", "task", "decision", "follow", "item", "mention"].contains { l.contains($0) })
        }
        let optional = { (s: String?) -> String? in
            guard let t = s.map(clean), !placeholder(t) else { return nil }
            return t
        }
        let said = { (owner: String) in
            owner.split(whereSeparator: { !$0.isLetter }).contains { $0.count > 1 && transcript.localizedCaseInsensitiveContains($0) }
        }
        var seen = Set<String>()
        let fresh = { (s: String) in seen.insert(s.lowercased()).inserted }
        return Notes(
            summary: clean(g.summary),
            decisions: g.decisions.map(clean).filter { !placeholder($0) && fresh($0) },
            actions: g.actions.compactMap { a in
                let text = clean(a.text)
                guard !placeholder(text), fresh("action|" + text) else { return nil }
                let due = optional(a.due).flatMap { saysDay($0, in: transcript) ? $0 : nil }
                return ActionItem(text: text, owner: optional(a.owner).flatMap { said($0) ? Entity.fullName($0, among: people) : nil }, due: due)
            })
    }

    /// Whether the transcript names the day `iso` (YYYY-MM-DD): the date itself, its
    /// weekday, its day with its month ("October 24", "24th of Oct"), or a relative day.
    // ponytail: English words only; other languages keep only dates said as YYYY-MM-DD.
    static func saysDay(_ iso: String, in transcript: String) -> Bool {
        guard iso.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, let date = try? Date(iso + "T12:00:00Z", strategy: .iso8601) else { return false }
        let text = transcript.lowercased()
        if text.contains(iso) { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.day, .month, .weekday], from: date)
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let has = { (w: String) in words.contains(w) }
        if has(names.weekdaySymbols[parts.weekday! - 1].lowercased()) { return true }
        if ["today", "tonight", "tomorrow", "eod", "eow"].contains(where: has) || text.contains("next week") || text.contains("end of the week") { return true }
        let month = names.monthSymbols[parts.month! - 1].lowercased()
        let monthSaid = has(month) || has(String(month.prefix(3)))
        let day = String(parts.day!)
        let daySaid = words.contains { $0 == day || ($0.hasPrefix(day) && ["st", "nd", "rd", "th"].contains(String($0.dropFirst(day.count)))) }
        return (monthSaid && daySaid) || text.contains("\(parts.month!)/\(day)")
    }
}

@Generable
struct GeneratedHeard {
    @Guide(description: "Full names of people who speak or are discussed")
    var people: [String]
    @Guide(description: "Companies, clients or organizations discussed")
    var companies: [String]
    @Guide(description: "Up to 3 short topic words, like pricing or hiring", .maximumCount(3))
    var topics: [String]
}

/// Suggests people, accounts and topics for a conversation and saves them on it. The
/// model is optional: without it, suggestions come from the People and Accounts notes.
public struct LinkSuggester: Sendable {
    /// Characters of transcript the model reads.
    static let characters = 6_000

    public init() {}

    @discardableResult
    public func suggest(_ id: String, in vault: Vault) async throws -> Conversation {
        let text = vault.transcript(id).plainText
        let heard = (try? await hear(text)) ?? Heard()
        return try vault.suggest(id, heard: heard)
    }

    /// Who and what the model heard. Throws when the model can't run.
    public func hear(_ transcript: String) async throws -> Heard {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Heard() }
        try AIError.check()
        let session = LanguageModelSession(instructions: "List only names that appear in the transcript. Use empty lists when there are none.")
        let g = try await session.respond(to: "Who and what is this conversation about?\n\nTRANSCRIPT:\n" + transcript.prefix(LinkSuggester.characters),
                                          generating: GeneratedHeard.self).content
        return Heard(people: g.people, companies: g.companies, topics: g.topics)
    }
}
