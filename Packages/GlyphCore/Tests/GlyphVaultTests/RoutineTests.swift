import Foundation
import Testing
@testable import GlyphVault

/// Routines as Time lines, and the ideas `routines suggest` finds. Made-up names and data only.
private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    return c
}()
/// Friday 2026-10-30, 9:00.
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
private func day(_ back: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.date(byAdding: .day, value: -back, to: now)!)!
}

@Test func routineLinesCreateCheckPauseArchiveLastWins() {
    var walk = Routine(id: "R1", title: "Walk", days: [1, 2, 3, 4, 5], time: day(0, 7))
    let water = Routine(id: "R2", title: "Drink water", perDay: 8)
    var lines = [TimeLog.routineLine(walk, host: "phone", at: day(2, 8)), TimeLog.routineLine(water, host: "phone", at: day(2, 8))]
    // Round trip through the file format.
    lines = TimeLog.events(in: lines.map { TimeLog.line($0) }.reduce(Data(), +))
    var list = TimeLog.routines(lines, cal: cal)
    #expect(list.map(\.title) == ["Walk", "Drink water"])
    #expect(list[1].perDay == 8 && list[1].rule == "x8" && list[0].days == [1, 2, 3, 4, 5])
    #expect(list[0].cadence(cal).hasPrefix("Weekdays 7:00"))
    #expect(list[1].cadence(cal) == "8 a day")

    // Check-ins: twice today, then one taken back; a check yesterday stays yesterday's.
    lines += [TimeEvent("done", at: day(1, 7), host: "phone", id: "R1"), TimeEvent("done", at: day(0, 7), host: "phone", id: "R2"),
              TimeEvent("done", at: day(0, 8), host: "phone", id: "R2"), TimeEvent("done", at: day(0, 8, 30), host: "phone", answer: "undo", id: "R2")]
    list = TimeLog.routines(lines, cal: cal)
    #expect(list[1].done(on: now, cal) == 1 && list[1].target(on: now, cal) == 8 && !list[1].met(on: now, cal))
    #expect(list[0].done(on: day(1, 12), cal) == 1 && list[0].done(on: now, cal) == 0)

    // Paused: the whole line again, the last one wins; nothing asked of it.
    walk.on = false
    lines.append(TimeLog.routineLine(walk, host: "phone", at: day(0, 8, 40)))
    list = TimeLog.routines(lines, cal: cal)
    #expect(!list[0].on && list[0].target(on: now, cal) == 0 && list[0].checks.count == 1)
    // Archived: still in the record, flagged, never deleted.
    walk.on = true; walk.archived = true
    lines.append(TimeLog.routineLine(walk, host: "phone", at: day(0, 8, 50)))
    list = TimeLog.routines(lines, cal: cal)
    #expect(list.count == 2 && list[0].archived && list[0].on)
}

@Test func weeklyRoutineCountsTheWeek() {
    let gym = Routine(id: "G", title: "Gym", perWeek: 2)
    var lines = [TimeLog.routineLine(gym, host: "phone", at: day(6, 8))]
    #expect(TimeLog.routines(lines, cal: cal)[0].cadence(cal) == "2 a week")
    // Friday 2026-10-30: Monday and Wednesday done, so nothing more this week.
    lines += [TimeEvent("done", at: day(4, 7), host: "phone", id: "G"), TimeEvent("done", at: day(2, 7), host: "phone", id: "G")]
    let r = TimeLog.routines(lines, cal: cal)[0]
    #expect(r.doneThisWeek(now, cal) == 2 && r.target(on: now, cal) == 0)
}

@Test func suggestionsOpenUntilAnswered() {
    let idea = RoutineSuggestion(id: "s-gym", title: "Gym", days: [1, 3, 5], why: "Mon, Wed, Fri, 4 of 4 weeks", source: "garmin")
    var lines = [idea.line(host: RoutineSuggest.host, at: day(1, 3))]
    #expect(TimeLog.routineSuggestions(lines) == [idea])
    lines.append(TimeEvent("routine-suggestion", at: day(1, 2), host: "phone", answer: "dismiss", id: "s-gym")) // a clock behind
    #expect(TimeLog.routineSuggestions(lines).isEmpty)
    #expect(idea.routine(id: "R9").days == [1, 3, 5])
}

/// A made-up vault: Garmin gym on Mon/Wed/Fri, Well walks four mornings a week, and noise.
private func tempVault() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "routines-\(UUID().uuidString)")
    let fm = FileManager.default
    for p in ["data/apps/garmin-connect/timeline", "data/apps/well/entries", "data/apps/time/sessions"] {
        try fm.createDirectory(at: root.appending(path: p), withIntermediateDirectories: true)
    }
    var rows = ["# Garmin, October 2026", "", "| Day | Start | Name | Type | Where | Time | km |", "|---|---|---|---|---|---|---|"]
    var well: [String] = []
    let ymd = DateFormatter(); ymd.calendar = cal; ymd.timeZone = cal.timeZone; ymd.dateFormat = "yyyy-MM-dd"
    for back in 1...28 {
        let d = day(back, 6, 30), wd = Routine.weekday(d, cal)
        if [1, 3, 5].contains(wd) {
            rows.append("| \(ymd.string(from: d)) | 06:\(30 + back % 10) | Springfield Gym | strength | Springfield | 1.0 h | 0 |")
        }
        if (back + 2 * ((back - 1) / 7)) % 7 < 4 { // four mornings a week, on days that shift
            well.append(#"{"at":"\#(TimeLog.stamp.string(from: day(back, 7, back % 3 * 10)))","event":"log","host":"phone","id":"W\#(back)","kind":"activity","name":"Walk","ts":"\#(TimeLog.stamp.string(from: day(back, 8)))"}"#)
        }
        if back % 9 == 0 { // noise: now and then, never steady
            rows.append("| \(ymd.string(from: d)) | 1\(back % 10):05 | Springfield Kayak | other | Springfield | 1.0 h | 3 |")
            well.append(#"{"at":"\#(TimeLog.stamp.string(from: day(back, 13)))","event":"log","host":"phone","id":"N\#(back)","kind":"activity","name":"Yoga","ts":"\#(TimeLog.stamp.string(from: day(back, 13)))"}"#)
        }
        // Travel and meals never count.
        rows.append("| \(ymd.string(from: d)) | 18:00 | Springfield Drive | other | Springfield | 0.5 h | 20 |")
        well.append(#"{"at":"\#(TimeLog.stamp.string(from: day(back, 12)))","event":"log","host":"phone","id":"F\#(back)","kind":"food","name":"Rice","ts":"\#(TimeLog.stamp.string(from: day(back, 12)))"}"#)
    }
    try rows.joined(separator: "\n").write(to: root.appending(path: "data/apps/garmin-connect/timeline/2026-10.md"), atomically: true, encoding: .utf8)
    try (well.joined(separator: "\n") + "\n").write(to: root.appending(path: "data/apps/well/entries/2026-10.phone.jsonl"), atomically: true, encoding: .utf8)
    return root
}

@Test func suggestFindsGymAndMorningWalkNotNoise() throws {
    let vault = try tempVault()
    defer { try? FileManager.default.removeItem(at: vault) }
    let dry = try RoutineSuggest.run(vault: vault, write: false, now: now, cal: cal)
    #expect(Set(dry.map(\.title)) == ["Gym", "Walk"])
    let gym = dry.first { $0.title == "Gym" }!
    #expect(gym.days == [1, 3, 5] && gym.source == "garmin" && gym.why == "4 of the last 4 weeks")
    let walk = dry.first { $0.title == "Walk" }!
    #expect(walk.rule == "w4" && walk.why == "4 mornings a week lately" && walk.source == "well")
    #expect(cal.component(.hour, from: walk.time!) == 7)
    // A dry run writes nothing; a real one writes the lines, and a second run offers nothing new.
    let folder = vault.appending(path: "data/apps/time/sessions")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    _ = try RoutineSuggest.run(vault: vault, write: true, now: now, cal: cal)
    #expect(TimeLog.routineSuggestions(TimeLog.read(folder, months: ["2026-10"])).count == 2)
    #expect(try RoutineSuggest.run(vault: vault, write: true, now: now, cal: cal).isEmpty)
}

@Test func suggestSkipsDismissedAndExistingRoutines() throws {
    let vault = try tempVault()
    defer { try? FileManager.default.removeItem(at: vault) }
    let folder = vault.appending(path: "data/apps/time/sessions")
    try TimeLog.append(TimeEvent("routine-suggestion", at: day(1, 9), host: "phone", answer: "dismiss", id: "s-gym"), to: folder)
    try TimeLog.append(TimeLog.routineLine(Routine(id: "R", title: "walk"), host: "phone", at: day(1, 9)), to: folder)
    #expect(try RoutineSuggest.run(vault: vault, write: false, now: now, cal: cal).isEmpty)
}
