import Foundation
import Testing
@testable import GlyphVault

/// Snooze and dismiss lines (TimeSnoozes.swift): counts, the 14-day strip, the one-line insight.
/// A fixed now: Friday 2026-10-30 6 PM, Chicago. Made-up names.
@Suite struct SnoozeTests {
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }()
    static let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18))!
    let h = "phone-1"

    func on(_ back: Int, _ hour: Int, _ minute: Int) -> Date {
        let d = Self.cal.date(byAdding: .day, value: -back, to: Self.cal.startOfDay(for: Self.now))!
        return Self.cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
    }
    var alarm: TimeEvent { TimeEvent("alarm", at: on(40, 21, 0), host: h, at: on(-1, 6, 30), label: "Gym", id: "a1", days: [1, 2, 3, 4, 5], snooze: true) }

    /// Rings on weekdays for four weeks: Mondays snoozed twice, off at 6:48; Thursdays once; else off at 6:31.
    var month: [TimeEvent] {
        var out = [alarm]
        for back in 1...28 {
            let w = Self.cal.component(.weekday, from: on(back, 6, 30)) // 1 Sunday
            guard (2...6).contains(w) else { continue }
            let snoozes = w == 2 ? 2 : w == 5 ? 1 : 0
            for k in 0..<snoozes { out.append(TimeEvent("snooze", at: on(back, 6, 30 + 9 * k), host: h, label: "Gym", id: "a1")) }
            out.append(TimeEvent("dismiss", at: on(back, 6, snoozes == 0 ? 31 : 30 + 9 * snoozes), host: h, label: "Gym", id: "a1"))
        }
        return out
    }

    @Test func linesRoundTrip() {
        let s = TimeEvent("snooze", at: on(1, 6, 30), host: h, label: "Gym", id: "a1")
        let text = String(decoding: TimeLog.line(s), as: UTF8.self)
        #expect(text.contains("\"event\":\"snooze\"") && text.contains("\"id\":\"a1\""))
        #expect(TimeLog.events(in: TimeLog.line(s)) == [s])
    }

    @Test func countsAWeek() {
        let week = Self.now.addingTimeInterval(-7 * 86_400)
        #expect(TimeLog.snoozes(month, id: "a1", from: week, to: Self.now) == 3) // one Monday, one Thursday
        #expect(TimeLog.snoozes(month, id: "other", from: week, to: Self.now) == 0)
    }

    @Test func stripOfFourteenDays() {
        let days = TimeLog.snoozeDays(month, id: "a1", now: Self.now, calendar: Self.cal)
        #expect(days.count == 14)
        #expect(days.last!.day == Self.cal.startOfDay(for: Self.now) && !days.last!.rang) // today: not rung yet
        #expect(days.filter(\.rang).count == 9)
        #expect(days.map(\.snoozes).reduce(0, +) == 6)
        #expect(days.first { Self.cal.component(.weekday, from: $0.day) == 2 }!.snoozes == 2)
    }

    @Test func insightNamesTheWeekday() {
        #expect(TimeLog.snoozeInsight(month, now: Self.now, calendar: Self.cal) == "You snooze the 6:30 alarm most Mondays")
    }

    @Test func insightAveragesWithoutAWeekday() {
        // Two snoozed days, different weekdays: no weekday pattern, an average.
        let lines = [alarm,
                     TimeEvent("snooze", at: on(2, 6, 30), host: h, id: "a1"), TimeEvent("snooze", at: on(2, 6, 39), host: h, id: "a1"),
                     TimeEvent("dismiss", at: on(2, 6, 48), host: h, id: "a1"),
                     TimeEvent("snooze", at: on(3, 6, 30), host: h, id: "a1"), TimeEvent("dismiss", at: on(3, 6, 39), host: h, id: "a1")]
        + (4...9).map { TimeEvent("dismiss", at: on($0, 6, 31), host: h, id: "a1") }
        #expect(TimeLog.snoozeInsight(lines, now: Self.now, calendar: Self.cal) == "6:30 alarm: avg 2 snoozes, 14 min late")
    }

    @Test func noInsightWithoutAPattern() {
        #expect(TimeLog.snoozeInsight([alarm], now: Self.now, calendar: Self.cal) == nil)
        let once = [alarm, TimeEvent("snooze", at: on(1, 6, 30), host: h, id: "a1")]
        #expect(TimeLog.snoozeInsight(once, now: Self.now, calendar: Self.cal) == nil)
    }

    @Test func suggestsALaterAlarm() {
        let ideas = RoutineSuggest.suggest([], events: month, now: Self.now, cal: Self.cal)
        let idea = ideas.first { $0.source == "snooze" }
        #expect(idea?.title == "Gym" && idea?.days == [1, 2, 3, 4, 5])
        #expect(idea?.why == "Snoozed 8 of 28 days, 14 min late")
        #expect(idea.flatMap { $0.time }.map { Self.cal.dateComponents([.hour, .minute], from: $0) } == DateComponents(hour: 6, minute: 45))
        // Offered once: not again.
        let offered = month + [idea!.line(host: RoutineSuggest.host, at: Self.now)]
        #expect(!RoutineSuggest.suggest([], events: offered, now: Self.now, cal: Self.cal).contains { $0.source == "snooze" })
    }
}
