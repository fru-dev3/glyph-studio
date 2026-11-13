import Foundation
import Testing
@testable import GlyphVault

/// When something already happened, from how it was told (`Recall`). A fixed now: Friday
/// 2026-10-30 6 PM, Chicago. Made-up sentences.
@Suite struct RecallTests {
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }()
    static let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18))!
    func day(_ w: Recall.When?) -> String {
        guard let w else { return "none" }
        let c = Self.cal.dateComponents([.month, .day], from: w.day)
        return String(format: "%02d-%02d", c.month!, c.day!) + (w.hour.map { String(format: " %05.2f", $0) } ?? "")
    }
    func when(_ s: String) -> String { day(Recall.when(s, now: Self.now, cal: Self.cal)) }

    @Test func weekdaysAreThePastOnes() {
        #expect(when("monday") == "10-26")
        #expect(when("on thursday") == "10-29")
        #expect(when("friday") == "10-30")
        #expect(when("last friday") == "10-23")
        #expect(when("saturday") == "10-24")
    }

    @Test func daysAndParts() {
        #expect(when("yesterday morning") == "10-29 08.00")
        #expect(when("last night") == "10-29 22.00")
        #expect(when("2 days ago at 3 pm") == "10-28 15.00")
        #expect(when("three days ago") == "10-27")
        #expect(when("the day before yesterday in the evening") == "10-28 19.00")
        #expect(when("tuesday at half past 7 in the evening") == "10-27 19.50")
        #expect(when("on the 3rd") == "10-03")
        #expect(when("on december 20") == "12-20")
        #expect(Recall.when("on december 20", now: Self.now, cal: Self.cal).map { Self.cal.component(.year, from: $0.day) } == 2025)
    }

    @Test func neverTheFuture() {
        let tomorrow = Recall.when("tomorrow", now: Self.now, cal: Self.cal)
        #expect(tomorrow?.question != nil && day(tomorrow) == "10-30")
        #expect(when("tonight") == "10-30")  // later than now: no hour, so now
        #expect(Recall.when("at 9 pm", now: Self.now, cal: Self.cal)?.date(now: Self.now, cal: Self.cal) ?? .distantFuture <= Self.now)
    }

    @Test func guessedDaysAsk() {
        #expect(Recall.when("last month", now: Self.now, cal: Self.cal)?.question == "Which day last month?")
        #expect(Recall.when("last week", now: Self.now, cal: Self.cal)?.question == "Which day last week?")
        #expect(Recall.when("yesterday", now: Self.now, cal: Self.cal)?.question == nil)
    }

    @Test func anchorsCarryForward() {
        let c = Recall.clauses("Yesterday. In the morning I ran, in the afternoon a nap and pizza. Monday at the gym I lifted, then today I feel fine", now: Self.now, cal: Self.cal)
        let got = c.map { "\($0.text) | \(day($0.when))" }
        #expect(got == ["Yesterday | 10-29", "In the morning I ran | 10-29 08.00", "in the afternoon a nap | 10-29 15.00", "pizza | 10-29 15.00",
                        "Monday at the gym I lifted | 10-26", "today I feel fine | 10-30"])
        #expect(c[4].place == "Gym" && c[5].place == nil)
    }

    @Test func places() {
        #expect(Recall.place("at Mom's house") == "Mom's")
        #expect(Recall.place("dinner at Northwind Grill") == "Northwind Grill")
        #expect(Recall.place("at 7 I ate") == nil)
        #expect(Recall.place("at lunch") == nil)
    }
}
