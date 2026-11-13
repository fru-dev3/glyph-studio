import Foundation

/// Routines in Glyph Time: lines in the same month files as the timer (`TimeLog`), folded by id,
/// the last line winning, as alarms are.
///
///     {"event":"routine","id":"R1","label":"Walk","days":[1,2,3,4,5],"at":"2026-10-31T07:00:00-05:00",...}
///     {"event":"routine","id":"R2","label":"Drink water","rule":"x8",...}       8 times a day
///     {"event":"routine","id":"R3","label":"Gym","rule":"w3",...}               3 times a week, any days
///     {"event":"routine","id":"R1","on":false,...}                              paused (the whole line again)
///     {"event":"routine","id":"R1","answer":"archive",...}                      off the list, never deleted
///     {"event":"done","id":"R1","device":"iPhone 17 Pro","ts":...}              checked off
///     {"event":"done","id":"R1","answer":"undo","ts":...}                       takes back that day's last check
///
/// No `days` is every day; `at` (optional) is the time of day it is for. Suggestions are lines too,
/// written by `glyphcore-report routines suggest` into `<month>.routines.jsonl`; the phone answers
/// one with the same id and `answer` "add" or "dismiss", and it is never offered again:
///
///     {"event":"routine-suggestion","id":"s-gym","label":"Gym","days":[1,3,5],"reason":"Mon Wed Fri, 4 of 4 weeks","source":"garmin",...}
public struct Routine: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 1 Monday ... 7 Sunday; empty is every day.
    public var days: [Int] = []
    /// The time of day it is for, if one was said.
    public var time: Date?
    /// Times a day it counts as done ("x8"); 1 unless said.
    public var perDay = 1
    /// Times a week, on any days ("w3"); nil for a daily kind.
    public var perWeek: Int?
    public var on = true
    public var archived = false
    /// When each check-off was made, oldest first.
    public var checks: [Date] = []

    public init(id: String, title: String, days: [Int] = [], time: Date? = nil, perDay: Int = 1, perWeek: Int? = nil) {
        self.id = id; self.title = title; self.days = days; self.time = time; self.perDay = perDay; self.perWeek = perWeek
    }

    /// "x8", "w3" or nil: how `rule` carries the count.
    public var rule: String? { perWeek.map { "w\($0)" } ?? (perDay > 1 ? "x\(perDay)" : nil) }

    /// 1 Monday ... 7 Sunday for a date.
    public static func weekday(_ d: Date, _ cal: Calendar = .current) -> Int { (cal.component(.weekday, from: d) + 5) % 7 + 1 }

    /// Check-offs on `day`.
    public func done(on day: Date, _ cal: Calendar = .current) -> Int { checks.filter { cal.isDate($0, inSameDayAs: day) }.count }

    /// Check-offs in the Monday-started week of `day`.
    public func doneThisWeek(_ day: Date, _ cal: Calendar = .current) -> Int {
        var c = cal; c.firstWeekday = 2
        guard let week = c.dateInterval(of: .weekOfYear, for: day) else { return 0 }
        return checks.filter { week.contains($0) }.count
    }

    /// What `day` asks of it: perDay on its days, 1 on any day for a weekly one until the week is met, else 0.
    public func target(on day: Date, _ cal: Calendar = .current) -> Int {
        guard on, !archived else { return 0 }
        if let w = perWeek { return done(on: day, cal) > 0 || doneThisWeek(day, cal) < w ? 1 : 0 }
        return days.isEmpty || days.contains(Self.weekday(day, cal)) ? perDay : 0
    }

    /// Met for `day`: its count reached (a weekly one: checked that day).
    public func met(on day: Date, _ cal: Calendar = .current) -> Bool {
        let t = target(on: day, cal)
        return t > 0 && done(on: day, cal) >= t
    }

    /// "Weekdays 7:00 AM", "8 a day", "3 a week", "Mon, Wed, Fri": the row's second line.
    public func cadence(_ cal: Calendar = .current) -> String {
        var parts: [String] = []
        if let w = perWeek { parts.append("\(w) a week") }
        else {
            if !days.isEmpty || perDay == 1 { parts.append(Self.daysText(days)) }
            if perDay > 1 { parts.append("\(perDay) a day") }
        }
        if let t = time {
            var f = Date.FormatStyle().hour().minute(); f.timeZone = cal.timeZone
            parts.append(t.formatted(f))
        }
        return parts.joined(separator: " ")
    }

    /// "Every day", "Weekdays", "Weekends", "Mon, Wed, Fri".
    public static func daysText(_ days: [Int]) -> String {
        let d = Set(days)
        if d.isEmpty || d.count == 7 { return "Every day" }
        if d == [1, 2, 3, 4, 5] { return "Weekdays" }
        if d == [6, 7] { return "Weekends" }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return d.sorted().map { names[$0 - 1] }.joined(separator: ", ")
    }
}

/// An idea for a routine, from patterns in the vault; added or dismissed by the person, never made by itself.
public struct RoutineSuggestion: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var days: [Int] = []
    public var time: Date?
    /// "w4" (times a week) or nil.
    public var rule: String?
    /// Why, in a few words: "Mon Wed Fri, 4 of 4 weeks".
    public var why: String
    /// Where it was seen: garmin, well, time.
    public var source: String

    public init(id: String, title: String, days: [Int] = [], time: Date? = nil, rule: String? = nil, why: String, source: String) {
        self.id = id; self.title = title; self.days = days; self.time = time; self.rule = rule; self.why = why; self.source = source
    }

    /// The routine it becomes on Add.
    public func routine(id: String) -> Routine {
        Routine(id: id, title: title, days: days, time: time, perDay: 1, perWeek: rule.flatMap { $0.hasPrefix("w") ? Int($0.dropFirst()) : nil })
    }

    public func line(host: String, at ts: Date = .now) -> TimeEvent {
        TimeEvent("routine-suggestion", at: ts, host: host, source: source, reason: why, at: time, label: title, id: id,
                  days: days.isEmpty ? nil : days, rule: rule)
    }
}

extension TimeLog {
    /// A routine as its line (written whole on every change, so the last line is the whole truth).
    public static func routineLine(_ r: Routine, host: String, device: String? = nil, at ts: Date = .now) -> TimeEvent {
        TimeEvent("routine", at: ts, host: host, device: device, answer: r.archived ? "archive" : nil, at: r.time, label: r.title, id: r.id,
                  days: r.days.isEmpty ? nil : r.days.sorted(), on: r.on ? nil : false, rule: r.rule)
    }

    /// Every routine (archived ones too, flagged), in the order first made, with its check-offs.
    public static func routines(_ events: [TimeEvent], cal: Calendar = .current) -> [Routine] {
        var list: [String: Routine] = [:], order: [String] = []
        let sorted = events.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
        for e in sorted where e.event == "routine" {
            guard let id = e.id, let title = e.label else { continue }
            if list[id] == nil { order.append(id) }
            var r = Routine(id: id, title: title, days: e.days ?? [], time: e.at)
            if let rule = e.rule, let n = Int(rule.dropFirst()), n > 0 {
                if rule.hasPrefix("x") { r.perDay = n } else if rule.hasPrefix("w") { r.perWeek = n }
            }
            r.on = e.on != false
            r.archived = e.answer == "archive"
            r.checks = list[id]?.checks ?? []
            list[id] = r
        }
        // Lines are stamped to the second and merged from several files: take each check once.
        var seen = Set<String>()
        for e in sorted where e.event == "done" {
            guard let id = e.id, list[id] != nil, seen.insert("\(id) \(e.ts.timeIntervalSince1970) \(e.answer ?? "")").inserted else { continue }
            if e.answer == "undo" {
                if let i = list[id]!.checks.lastIndex(where: { cal.isDate($0, inSameDayAs: e.ts) }) { list[id]!.checks.remove(at: i) }
            } else {
                list[id]!.checks.append(e.ts)
            }
        }
        return order.compactMap { list[$0] }
    }

    /// Suggestions still open: offered, and not yet added or dismissed.
    public static func routineSuggestions(_ events: [TimeEvent]) -> [RoutineSuggestion] {
        var last: [String: TimeEvent] = [:], order: [String] = []
        for e in events.sorted(by: { $0.ts < $1.ts }) where e.event == "routine-suggestion" {
            guard let id = e.id else { continue }
            if last[id] == nil { order.append(id) }
            // An answer always wins over the offer, whichever device's clock was ahead.
            if last[id]?.answer != nil, e.answer == nil { continue }
            last[id] = e
        }
        return order.compactMap { id in
            guard let e = last[id], e.answer == nil, let title = e.label else { return nil }
            return RoutineSuggestion(id: id, title: title, days: e.days ?? [], time: e.at, rule: e.rule, why: e.reason ?? "", source: e.source ?? "")
        }
    }
}
