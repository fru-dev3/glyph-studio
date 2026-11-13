import Foundation
import Testing
@testable import GlyphVault

/// `TimeLog.open`: which session counts as running now, across devices. This is what Glyph Time on
/// the iPhone asks about a Mac's timer and what Glyph Native's Now card asks about any of them.
/// Made-up host and project names only.
private let now = Date(timeIntervalSince1970: 1_762_900_000)   // a fixed instant, so nothing drifts
private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

private func sessions(_ events: [TimeEvent]) -> [TimeSession] { TimeLog.sessions(events) }

@Test func openFindsASessionOnAnotherDeviceAndIgnoresAClosedOne() {
    let events = [
        TimeEvent("start", at: ago(3), host: "laptop", device: "Laptop", project: "acme-api", source: "named"),
        TimeEvent("stop", at: ago(2), host: "laptop", minutes: 60),
        TimeEvent("start", at: ago(1), host: "studio", device: "Studio", project: "foo", source: "named"),
    ]
    let open = TimeLog.open(sessions(events), now: now)
    #expect(open?.project == "foo")
    #expect(open?.device == "Studio")
    #expect(open?.end == nil)
}

@Test func openCountsAPausedSessionAsStillOpen() {
    // A Mac timer on a break is still the timer: Glyph Time says "Paused on <device>" rather than
    // showing nothing. The Now card filters the paused ones out before it asks.
    let events = [
        TimeEvent("start", at: ago(2), host: "studio", device: "Studio", project: "foo", source: "named"),
        TimeEvent("pause", at: ago(1), host: "studio", reason: "user"),
    ]
    let open = TimeLog.open(sessions(events), now: now)
    #expect(open?.project == "foo")
    #expect(open?.pausedSince != nil)
    #expect(TimeLog.open(sessions(events).filter { $0.pausedSince == nil }, now: now) == nil)
}

@Test func openIgnoresASessionLeftRunningForMoreThanEighteenHours() {
    // Nothing writes a stop for an app that was killed, so a file can hold a session open for
    // days. Showing it as "now" would be a clock that never moves.
    let stale = [TimeEvent("start", at: ago(19), host: "studio", device: "Studio", project: "foo", source: "named")]
    #expect(TimeLog.open(sessions(stale), now: now) == nil)
    let justInside = [TimeEvent("start", at: ago(17.9), host: "studio", device: "Studio", project: "foo", source: "named")]
    #expect(TimeLog.open(sessions(justInside), now: now)?.project == "foo")
}

@Test func openTakesTheNewestOfTwoRunningAtOnce() {
    let events = [
        TimeEvent("start", at: ago(4), host: "laptop", device: "Laptop", project: "acme-api", source: "named"),
        TimeEvent("start", at: ago(1), host: "studio", device: "Studio", project: "foo", source: "named"),
    ]
    #expect(TimeLog.open(sessions(events), now: now)?.device == "Studio")
}

@Test func openIsNilWhenNothingIsOpen() {
    #expect(TimeLog.open([], now: now) == nil)
}
