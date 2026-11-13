import Foundation
import GlyphVault

/// Glyph Core Intelligence's answer to one chat turn (the hub's POST /understand, alias /intelligence).
/// `answer`: `reply` is the text (up to about 1200 characters, paragraphs kept). `ask`: the app asks back with
/// `question`, and the next turn carries it in `history`. `act`: `jobs`, each a GlyphAI tool of an app's agent
/// with its JSON arguments (`handoff`: another app's agent than the surface's); `reply` is a short line.
/// `none`: nothing to do (`reply` may say so).
public struct ChatPlan: Decodable, Equatable, Sendable {
    public struct Job: Decodable, Equatable, Sendable {
        public var agent: String
        public var tool: String
        /// The tool's arguments as JSON text, as `glyphcore-report run` takes them.
        public var arguments: String
        public var quote: String
        public var instruction: String
        public var handoff: Bool
        /// What the thing is, in their own words ("Take a walk"), never a title from context; empty when none.
        public var title: String
        /// For a timed thing, the clock time it lands on ("3:32 PM"), worked out by the hub; else empty.
        public var at: String
        /// One line on what is being done, in which app: "Asking Time to set an alarm for 3:32 PM: Take a walk".
        public var doing: String
        public init(agent: String, tool: String, arguments: String = "{}", quote: String = "", instruction: String = "", handoff: Bool = false,
                    title: String = "", at: String = "", doing: String = "") {
            self.agent = agent; self.tool = tool; self.arguments = arguments; self.quote = quote; self.instruction = instruction; self.handoff = handoff
            self.title = title; self.at = at; self.doing = doing
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            agent = try c.decode(String.self, forKey: .agent)
            tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
            let args = try c.decodeIfPresent(JSONValue.self, forKey: .arguments) ?? .object([:])
            arguments = String(decoding: (try? JSONEncoder().encode(args)) ?? Data("{}".utf8), as: UTF8.self)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
            handoff = try c.decodeIfPresent(Bool.self, forKey: .handoff) ?? false
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
            doing = try c.decodeIfPresent(String.self, forKey: .doing) ?? ""
        }
        enum CodingKeys: String, CodingKey { case agent, tool, arguments, quote, instruction, handoff, title, at, doing }
    }
    public var kind: String
    public var reply: String
    public var question: String
    public var jobs: [Job]
    /// `act` only, optional: one proactive offer once the jobs are done ("Want me to log the walk in Well when you're back?").
    public var suggest: String

    public init(kind: String, reply: String = "", question: String = "", jobs: [Job] = [], suggest: String = "") {
        self.kind = kind; self.reply = reply; self.question = question; self.jobs = jobs; self.suggest = suggest
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        jobs = try c.decodeIfPresent([Job].self, forKey: .jobs) ?? []
        suggest = try c.decodeIfPresent(String.self, forKey: .suggest) ?? ""
    }
    enum CodingKeys: String, CodingKey { case kind, reply, question, jobs, suggest }

    /// Time's armed answer as the confirmed card: "Alarm set · 3:32 PM · Take a walk". The time is Time's own
    /// (from its answer, "Alarm: Take a walk, today at 3:32 PM"), the hub's `at` only when Time's has none.
    public static func confirmed(_ answer: String, job: Job) -> String {
        let kind = job.tool == "request_reminder" ? "Reminder" : job.tool == "start_timer" ? "Timer" : "Alarm"
        var when = job.at
        if let r = answer.range(of: #"\d{1,2}:\d{2}\s?[AP]M"#, options: .regularExpression) {
            when = (answer.lowercased().contains("tomorrow") ? "tomorrow " : "") + answer[r]
        }
        var title = job.title
        if title.isEmpty, let c = answer.range(of: ": ") { title = String(answer[c.upperBound...].prefix { $0 != "," }) }
        return ([kind + " set"] + [when, title].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    /// What one job did: its cards (a tool may make more than one).
    public struct Result: Sendable {
        public var job: Job
        public var done: [Done]
    }
}

/// Any JSON value, so a job's arguments pass through as they came.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension Hub {
    /// One chat turn to Glyph Core Intelligence: `surface` is the app ("time", "well", "jot", "crm", "omega",
    /// "studio", "native"), `history` the turns before (the last 6 are sent), `period` "today" or "week" when the
    /// app has one. Nil when the hub or Claude can't be reached (503): return nil from `respond` and GlyphChat says so and keeps the words.
    public func understand(surface: String, text: String, history: [ChatTurn] = [], period: String? = nil, preferences: String? = nil,
                           now: Date = .now, timeZone: TimeZone = .current) async -> ChatPlan? {
        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = ["surface": surface, "text": text, "now": f.string(from: now), "tz": timeZone.identifier,
                                   "history": history.suffix(6).map { ["role": $0.mine ? "user" : "app", "text": $0.text] }]
        var prefs = preferences ?? ""
        if preferences == nil { prefs = await preferenceText(for: surface) }
        if !prefs.isEmpty { body["preferences"] = prefs }
        if let period { body["period"] = period }
        guard let (code, data) = await send("POST", "understand", body: json(body)), code == 200 else { return nil }
        return try? JSONDecoder().decode(ChatPlan.self, from: data)
    }

    /// Each job's tool called on its agent with its arguments (as `glyphcore-report run` does), in order. A job
    /// whose tool fails or is unknown comes back as one card that says so.
    public func perform(_ plan: ChatPlan) async -> [ChatPlan.Result] {
        var out: [ChatPlan.Result] = []
        for j in plan.jobs {
            let what = j.quote.isEmpty ? j.instruction : j.quote
            guard let agent = GlyphAgent.named(j.agent) else {
                out.append(.init(job: j, done: [Done(agent: j.agent, line: "No app for that: \(what)", title: what, ok: false)])); continue
            }
            do { out.append(.init(job: j, done: try await agent.call(j.tool, json: j.arguments, hub: self))) }
            catch { out.append(.init(job: j, done: [Done(agent: j.agent, line: "Couldn't do that: \(what)", title: what, ok: false)])) }
        }
        return out
    }
}
