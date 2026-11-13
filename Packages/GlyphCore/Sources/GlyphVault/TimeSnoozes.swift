import Foundation

/// What happened when an alarm rang: one line per Snooze tap and one when it was stopped, written by
/// the phone that rang, naming the alarm by its `id` (and its label, for people reading the file).
///
///     {"event":"snooze","host":"iphone-16-pro","id":"7F3A...","label":"Gym","ts":"2026-10-28T06:30:12-05:00"}
///     {"event":"dismiss","host":"iphone-16-pro","id":"7F3A...","label":"Gym","ts":"2026-10-28T06:48:02-05:00"}
///
/// A day the alarm rang is a day with either line for it. Late is the dismiss's time past the alarm's
/// time of day.
public struct SnoozeDay: Equatable, Sendable {
    public var day: Date
    public var rang: Bool
    public var snoozes: Int
}

extension TimeLog {
    /// Snooze taps on the alarm `id` in [from, to).
    public static func snoozes(_ events: [TimeEvent], id: String, from: Date, to: Date) -> Int {
        events.filter { $0.event == "snooze" && $0.id == id && $0.ts >= from && $0.ts < to }.count
    }

    /// The last `days` days, today included, oldest first: whether the alarm rang and how often it was snoozed.
    public static func snoozeDays(_ events: [TimeEvent], id: String, days: Int = 14, now: Date = .now, calendar cal: Calendar = .current) -> [SnoozeDay] {
        let today = cal.startOfDay(for: now)
        var out = (0..<days).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .map { SnoozeDay(day: $0, rang: false, snoozes: 0) }
        for e in events where e.id == id && (e.event == "snooze" || e.event == "dismiss") {
            guard let i = out.firstIndex(where: { $0.day == cal.startOfDay(for: e.ts) }) else { continue }
            out[i].rang = true
            if e.event == "snooze" { out[i].snoozes += 1 }
        }
        return out
    }

    /// One quiet line when there is a pattern in the last four weeks, else nil:
    /// "You snooze the 6:30 alarm most Mondays" (snoozed on 3 or more of that weekday, over half its
    /// rings), "You snooze the 6:30 alarm most days", or "6:30 alarm: avg 2 snoozes, 9 min late"
    /// (snoozed on 2 or more days).
    // ponytail: plain counts over 28 days; weigh recent weeks more if the line feels stale.
    public static func snoozeInsight(_ events: [TimeEvent], now: Date = .now, calendar cal: Calendar = .current) -> String? {
        let since = cal.date(byAdding: .day, value: -28, to: cal.startOfDay(for: now)) ?? now
        let answers = events.filter { ($0.event == "snooze" || $0.event == "dismiss") && $0.ts >= since && $0.ts <= now && $0.id != nil }
        // The alarm's time of day, from its newest alarm line.
        var times: [String: Date] = [:]
        for e in events.sorted(by: { $0.ts < $1.ts }) where e.event == "alarm" { if let id = e.id, let at = e.at { times[id] = at } }
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX"); hm.timeZone = cal.timeZone; hm.dateFormat = "h:mm"
        let weekdays = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

        struct Day { var snoozes = 0; var dismissed: Date? }
        var best: (score: (Int, Int), line: String)?
        for (id, lines) in Dictionary(grouping: answers, by: { $0.id! }) {
            guard let at = times[id] else { continue }
            let name = "the \(hm.string(from: at)) alarm"
            var days: [Date: Day] = [:]
            for e in lines {
                let d = cal.startOfDay(for: e.ts)
                if e.event == "snooze" { days[d, default: Day()].snoozes += 1 } else { days[d, default: Day()].dismissed = e.ts }
            }
            let snoozed = days.filter { $0.value.snoozes > 0 }
            let total = snoozed.values.reduce(0) { $0 + $1.snoozes }
            guard snoozed.count >= 2 else { continue }
            var line: String
            if snoozed.count * 2 > days.count && snoozed.count >= 3 {
                line = "You snooze \(name) most days"
            } else {
                // The weekday snoozed most often, more taps breaking a tie.
                let byDay = Dictionary(grouping: snoozed, by: { cal.component(.weekday, from: $0.key) })
                let top = byDay.max { a, b in (a.value.count, a.value.reduce(0) { $0 + $1.value.snoozes }) < (b.value.count, b.value.reduce(0) { $0 + $1.value.snoozes }) }
                let rings = top.map { w in days.keys.filter { cal.component(.weekday, from: $0) == w.key }.count } ?? 0
                if let top, top.value.count >= 3, top.value.count * 2 > rings {
                    line = "You snooze \(name) most \(weekdays[top.key - 1])"
                } else {
                    let avg = Int((Double(total) / Double(snoozed.count)).rounded())
                    line = "\(hm.string(from: at)) alarm: avg \(avg) \(avg == 1 ? "snooze" : "snoozes")"
                    let lates: [Double] = snoozed.compactMap { d, v in
                        guard let off = v.dismissed else { return nil }
                        let c = cal.dateComponents([.hour, .minute], from: at)
                        guard let due = cal.date(bySettingHour: c.hour!, minute: c.minute!, second: 0, of: d) else { return nil }
                        return off.timeIntervalSince(due) / 60
                    }.filter { $0 >= 0 }
                    if !lates.isEmpty { line += ", \(Int((lates.reduce(0, +) / Double(lates.count)).rounded())) min late" }
                }
            }
            let score = (snoozed.count, total)
            if best == nil || score > best!.score { best = (score, line) }
        }
        return best?.line
    }

    /// For `routines suggest`: an alarm snoozed on 3 or more days of the last four weeks, stopped 5 or
    /// more minutes late on average, offered at the time it is really stopped (to the quarter hour),
    /// so it can ring later. Scored by the days it was snoozed.
    static func snoozeIdeas(_ events: [TimeEvent], now: Date, calendar cal: Calendar) -> [(score: Int, s: RoutineSuggestion)] {
        let since = cal.date(byAdding: .day, value: -28, to: cal.startOfDay(for: now)) ?? now
        let alarms = reminders(events).filter { $0.event == "alarm" && $0.on != false }
        return alarms.compactMap { a in
            guard let id = a.id, let at = a.at else { return nil }
            let mine = events.filter { $0.id == id && $0.ts >= since && $0.ts < now }
            let snoozedDays = Set(mine.filter { $0.event == "snooze" }.map { cal.startOfDay(for: $0.ts) })
            guard snoozedDays.count >= 3 else { return nil }
            let c = cal.dateComponents([.hour, .minute], from: at)
            let lates = mine.filter { $0.event == "dismiss" && snoozedDays.contains(cal.startOfDay(for: $0.ts)) }.compactMap { d -> Double? in
                guard let due = cal.date(bySettingHour: c.hour!, minute: c.minute!, second: 0, of: d.ts) else { return nil }
                return d.ts.timeIntervalSince(due) / 60
            }.filter { $0 >= 0 }
            guard !lates.isEmpty else { return nil }
            let late = Int((lates.reduce(0, +) / Double(lates.count)).rounded())
            guard late >= 5 else { return nil }
            let m = (c.hour! * 60 + c.minute! + late + 7) / 15 * 15
            let time = cal.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: cal.startOfDay(for: now))
            let s = RoutineSuggestion(id: "s-snooze-" + RoutineSuggest.key(id), title: a.label ?? "Alarm", days: a.days ?? [], time: time,
                                      why: "Snoozed \(snoozedDays.count) of 28 days, \(late) min late", source: "snooze")
            return (snoozedDays.count, s)
        }
    }
}
