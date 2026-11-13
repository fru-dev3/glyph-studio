import Foundation

/// Glyph Time's record: one JSON line per thing that happened to a timer, appended to
/// `<folder>/<YYYY-MM>.<host>.jsonl`. Each device writes only its own file, so two writers never
/// touch the same file; readers merge every file by time. The file is the timer: elapsed time is
/// worked out from the lines, so a crash, a reboot or sleep loses nothing.
///
///     {"event":"start","host":"laptop-local","project":"acme-api","source":"repo","ts":"2026-10-27T09:12:04-05:00"}
///     {"event":"pause","host":"laptop-local","reason":"idle","ts":"2026-10-27T09:40:00-05:00"}
///     {"event":"resume","host":"laptop-local","ts":"2026-10-27T09:43:10-05:00"}
///     {"answer":"keep","event":"nudge","host":"laptop-local","minutes":30,"ts":"2026-10-27T09:45:14-05:00"}
///     {"event":"stop","host":"laptop-local","minutes":85,"ts":"2026-10-27T10:40:12-05:00"}
///
/// Events: start (project, source, app, countdown), name (renames the open session), pause
/// (reason: user, idle, sleep, lock), resume, stop (minutes, for people reading the file), nudge
/// (minutes, answer: keep, stop, ignored, done), hide and show (project: off and back on the
/// Recent list), alarm and reminder (the phone: id, at, label;
/// the same id again with answer "cancel" takes it back; the same id again with new fields is an
/// edit, the last line wins). A repeating one carries days (1 Monday ... 7 Sunday) and its `at` is
/// the next time it goes off when written; sound, snooze and on (false: switched off) are optional.
/// Any other repeat is a `rule` ("d2" every other day, "h2" every 2 hours, "m1.1" the first Monday
/// of each month, "m-1.5" the last Friday); `end` is the last moment it may go off and `start` the
/// day it was said to begin ("until Nov 27", "starting next Monday").
/// Fixing the record is a line too, never a rewrite: edit (id, and any of project, start, end)
/// changes one session, delete takes it out, undelete brings it back; any device may write them,
/// naming the session by its `id`. rename (project: the old name, label: the new one) renames a
/// whole project, every session of it, on every device. Lines with other events are kept but not
/// folded.
///
///     {"at":"2026-10-28T06:30:00-05:00","event":"alarm","host":"iphone-16-pro","id":"7F3A...","label":"Gym","ts":"2026-10-27T21:02:11-05:00"}
public struct TimeEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var event: String
    public var host: String
    public var device: String?
    public var project: String?
    /// Where the project name came from: named, repo (a terminal or editor window), app.
    public var source: String?
    /// The front app's bundle id when the timer started. Never a window title or a URL.
    public var app: String?
    public var reason: String?
    public var minutes: Int?
    /// A countdown's length in minutes; none for a count-up.
    public var countdown: Int?
    public var answer: String?
    /// An alarm's or reminder's: when it goes off, what it says, and its id (to cancel it).
    public var at: Date?
    public var label: String?
    public var id: String?
    /// Repeats on these weekdays, 1 Monday ... 7 Sunday; none rings once.
    public var days: [Int]?
    /// The alert sound's name; none is the system's.
    public var sound: String?
    public var snooze: Bool?
    /// False while switched off; none is on.
    public var on: Bool?
    /// An edit's new start and end for the session named by `id`; an alarm's or reminder's first
    /// day and last moment.
    public var start: Date?
    public var end: Date?
    /// An alarm's or reminder's repeat other than weekly `days`: "d2", "h2", "m1.1".
    public var rule: String?

    public init(_ event: String, at ts: Date = .now, host: String, device: String? = nil, project: String? = nil,
                source: String? = nil, app: String? = nil, reason: String? = nil, minutes: Int? = nil,
                countdown: Int? = nil, answer: String? = nil,
                at: Date? = nil, label: String? = nil, id: String? = nil,
                days: [Int]? = nil, sound: String? = nil, snooze: Bool? = nil, on: Bool? = nil,
                start: Date? = nil, end: Date? = nil, rule: String? = nil) {
        self.ts = ts; self.event = event; self.host = host; self.device = device; self.project = project
        self.source = source; self.app = app; self.reason = reason; self.minutes = minutes
        self.countdown = countdown; self.answer = answer
        self.at = at; self.label = label; self.id = id
        self.days = days; self.sound = sound; self.snooze = snooze; self.on = on
        self.start = start; self.end = end; self.rule = rule
    }
}

/// A project on the Recent list: when it last started, its time today and in all, hidden or not.
public struct TimeProject: Equatable, Sendable {
    public var name: String
    public var last: Date
    public var today: TimeInterval = 0
    public var total: TimeInterval = 0
    public var hidden = false
    public init(name: String, last: Date) { self.name = name; self.last = last }
}

/// One stretch of work, folded from the lines.
public struct TimeSession: Equatable, Sendable, Identifiable {
    /// "laptop-local 2026-10-27T09:12:04-05:00": its device and first start, kept through edits,
    /// so an edit line can name it.
    public var id: String = ""
    public var host: String
    public var device: String?
    public var project: String?
    public var source: String?
    public var app: String?
    public var countdown: Int?
    public var start: Date
    /// Nil while it is still open.
    public var end: Date?
    /// Set while paused, with why.
    public var pausedSince: Date?
    public var pauseReason: String?
    /// Seconds paused in pauses that have ended.
    public var paused: TimeInterval = 0
    public var nudges = 0

    /// Seconds worked: start to end (or now), minus every pause.
    public func active(at now: Date = .now) -> TimeInterval {
        let until = end ?? now
        let open = pausedSince.map { max(0, until.timeIntervalSince($0)) } ?? 0
        return max(0, until.timeIntervalSince(start) - paused - open)
    }
}

public enum TimeLog {
    // ISO8601DateFormatter is thread-safe; it is only configured here, once.
    nonisolated(unsafe) static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current // "2026-10-27T09:12:04-05:00": the hour as the person lived it
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(stamp.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    /// One line, newline included.
    public static func line(_ event: TimeEvent) -> Data {
        var data = (try? encoder.encode(event)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Every line that reads as an event; a torn or foreign line is skipped, never fatal.
    public static func events(in data: Data) -> [TimeEvent] {
        data.split(separator: 0x0A).compactMap { try? decoder.decode(TimeEvent.self, from: Data($0)) }
    }

    /// "2026-10" for the month the event happened in, on this device's calendar.
    public static func month(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public static func fileName(for event: TimeEvent) -> String { "\(month(event.ts)).\(event.host).jsonl" }

    /// Appends one line to its month's file in `folder`, making the folder and file if need be.
    public static func append(_ event: TimeEvent, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(for: event))
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line(event))
    }

    /// Every event in the folder's files for these months ("2026-10"), all devices, oldest first.
    public static func read(_ folder: URL, months: Set<String>) -> [TimeEvent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && months.contains(String($0.prefix(7))) }
            .flatMap { events(in: (try? Data(contentsOf: folder.appendingPathComponent($0))) ?? Data()) }
            .sorted { $0.ts < $1.ts }
    }

    /// This month and the one before: enough to find a session left open over a month's end.
    public static func recentMonths(_ now: Date = .now, count: Int = 2) -> Set<String> {
        Set((0..<max(1, count)).map { month(Calendar.current.date(byAdding: .month, value: -$0, to: now) ?? now) })
    }

    /// Every named project, most recently started first, with its time today and in all the
    /// sessions given. Hiding is a line too: `{"event":"hide","project":"X"}` takes it off the
    /// Recent list, `"show"` puts it back, and starting it again brings it back by itself. With
    /// `autoHideDays`, a project not started (or shown) in that many days is hidden as well.
    /// Hidden projects stay in the file and in every total; only the list leaves them out.
    public static func projects(_ events: [TimeEvent], now: Date = .now, autoHideDays: Int? = nil) -> [TimeProject] {
        let sessions = sessions(events)
        let day = Calendar.current.startOfDay(for: now)
        var list: [String: TimeProject] = [:]
        for s in sessions {
            guard let name = s.project?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            var p = list[name] ?? TimeProject(name: name, last: s.start)
            p.last = max(p.last, s.start)
            let secs = s.active(at: now)
            p.total += secs
            if s.start >= day { p.today += secs }
            list[name] = p
        }
        // Hidden when its last start, show or hide is a hide. Taken in line order (time, then place
        // in the file), since lines are stamped to the second: a hide in the second a session
        // started still hides it.
        var hiddenNow: [String: Bool] = [:], shown: [String: Date] = [:]
        for e in events.enumerated().sorted(by: { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }).map(\.element) {
            guard let name = e.project?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            switch e.event {
            case "hide": hiddenNow[name] = true
            case "show": hiddenNow[name] = false; shown[name] = max(shown[name] ?? .distantPast, e.ts)
            case "start", "name": hiddenNow[name] = false
            case "rename":
                guard let to = e.label?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else { break }
                hiddenNow[to] = hiddenNow.removeValue(forKey: name) ?? hiddenNow[to]
                if let was = shown.removeValue(forKey: name) { shown[to] = max(shown[to] ?? .distantPast, was) }
            default: break
            }
        }
        let cutoff = autoHideDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        for (name, var p) in list {
            let back = max(p.last, shown[name] ?? .distantPast)
            p.hidden = hiddenNow[name] == true || (cutoff.map { back < $0 } ?? false)
            list[name] = p
        }
        return list.values.sorted { $0.last > $1.last }
    }

    /// Folds events into sessions, each device on its own, oldest first. A start while a session
    /// is open closes that one at the new start, so a lost stop never makes a session run forever
    /// past the next one.
    public static func sessions(_ events: [TimeEvent]) -> [TimeSession] {
        var done: [TimeSession] = []
        var open: [String: TimeSession] = [:]
        func close(_ host: String, at ts: Date) {
            guard var s = open.removeValue(forKey: host) else { return }
            if let since = s.pausedSince {
                s.paused += max(0, ts.timeIntervalSince(since))
                s.pausedSince = nil
            }
            s.end = max(ts, s.start)
            done.append(s)
        }
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            switch e.event {
            case "start":
                close(e.host, at: e.ts)
                open[e.host] = TimeSession(id: "\(e.host) \(stamp.string(from: e.ts))", host: e.host, device: e.device,
                                           project: e.project, source: e.source, app: e.app, countdown: e.countdown, start: e.ts)
            case "name":
                open[e.host]?.project = e.project
                open[e.host]?.source = e.source ?? "named"
            case "pause":
                if open[e.host] != nil, open[e.host]?.pausedSince == nil {
                    open[e.host]?.pausedSince = e.ts
                    open[e.host]?.pauseReason = e.reason
                }
            case "resume":
                if let since = open[e.host]?.pausedSince {
                    open[e.host]?.paused += max(0, e.ts.timeIntervalSince(since))
                    open[e.host]?.pausedSince = nil
                    open[e.host]?.pauseReason = nil
                }
            case "stop":
                close(e.host, at: e.ts)
            case "nudge":
                open[e.host]?.nudges += 1
            default:
                break
            }
        }
        // Fixes, in order, the last word winning: a new project, start or end, or out and back in.
        var all = done + open.values
        var gone = Set<String>()
        for e in events.sorted(by: { $0.ts < $1.ts }) where ["edit", "delete", "undelete", "rename"].contains(e.event) {
            // A rename takes every session of that project, whenever it ran.
            // ponytail: renames all of history, not from its day on; split by date if that ever matters.
            if e.event == "rename" {
                let from = e.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let to = e.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !from.isEmpty, !to.isEmpty, from != to else { continue }
                for i in all.indices where all[i].project == from { all[i].project = to }
                continue
            }
            guard let id = e.id, let i = all.firstIndex(where: { $0.id == id }) else { continue }
            switch e.event {
            case "delete": gone.insert(id)
            case "undelete": gone.remove(id)
            default:
                if let p = e.project?.trimmingCharacters(in: .whitespacesAndNewlines) { all[i].project = p.isEmpty ? nil : p; all[i].source = "named" }
                if let start = e.start { all[i].start = start }
                if let end = e.end, all[i].end != nil { all[i].end = end }
                if let end = all[i].end, end < all[i].start { all[i].end = all[i].start }
                // Pauses can't be longer than the session they are in.
                if let end = all[i].end { all[i].paused = min(all[i].paused, end.timeIntervalSince(all[i].start)) }
            }
        }
        return all.filter { !gone.contains($0.id) }.sorted { $0.start < $1.start }
    }

    /// Alarms and reminders still set (not taken back), soonest first. Past ones are kept: the
    /// caller decides what "upcoming" means.
    public static func reminders(_ events: [TimeEvent]) -> [TimeEvent] {
        var set: [String: TimeEvent] = [:]
        for e in events.sorted(by: { $0.ts < $1.ts }) where e.event == "alarm" || e.event == "reminder" {
            guard let id = e.id else { continue }
            if e.answer == "cancel" { set[id] = nil } else if e.at != nil { set[id] = e }
        }
        return set.values.sorted { $0.at! < $1.at! }
    }

    /// The session that is open now, from any device's lines, newest start first. Nil when
    /// nothing is open.
    ///
    /// A session is only open until someone writes its `stop`, and nothing writes that for an app
    /// that was killed or a Mac that never woke, so a file can hold a session left open for days.
    /// Anything older than 18 hours is not "now" however the file reads. Glyph Native's Now card
    /// carried this rule privately; Glyph Time on the iPhone needs the same answer about a Mac's
    /// timer, so the rule lives next to the lines it is about.
    // ponytail: 18 hours, no setting. A real session that long is already a mistake in the file.
    public static func open(_ sessions: [TimeSession], now: Date = .now) -> TimeSession? {
        sessions.last { $0.end == nil && now.timeIntervalSince($0.start) < 18 * 3600 }
    }

    /// Seconds per project for sessions that started in [from, to), biggest first. A session is
    /// counted on the day it started.
    // ponytail: no splitting at midnight; split by day if late-night sessions start to matter.
    public static func totals(_ sessions: [TimeSession], from: Date, to: Date, now: Date = .now) -> [(project: String, seconds: TimeInterval)] {
        var sum: [String: TimeInterval] = [:]
        for s in sessions where s.start >= from && s.start < to {
            sum[s.project?.isEmpty == false ? s.project! : "Unnamed", default: 0] += s.active(at: now)
        }
        return sum.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// "0:42", "1:05:09": hours only once there are some.
    public static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "1 h 12 min", "35 min", "42 s": for totals. Under a minute shows its seconds, never "0 min".
    public static func span(_ seconds: TimeInterval) -> String {
        if seconds > 0 && seconds < 60 { return "\(max(1, Int(seconds))) s" }
        let m = Int(max(0, seconds) / 60)
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }

    /// The short read for Glyph Bot and any agent: today, this week and last week by project,
    /// and this week by device, from every device's sessions. Plain Markdown, no times of day.
    public static func summary(_ sessions: [TimeSession], now: Date = .now, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.firstWeekday = 2 // weeks start on Monday
        let today = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeek = cal.date(byAdding: .day, value: -7, to: week) ?? week
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEE d MMM"
        func block(_ title: String, from: Date, to: Date) -> String {
            let picked = sessions.filter { $0.start >= from && $0.start < to }
            let all = picked.reduce(0) { $0 + $1.active(at: now) }
            guard all >= 60 else { return "## \(title)\n\nNothing timed.\n" }
            let rows = totals(picked, from: from, to: to, now: now).filter { $0.seconds >= 60 }.map { t in
                let n = picked.filter { ($0.project?.isEmpty == false ? $0.project! : "Unnamed") == t.project }.count
                return "- \(t.project): \(span(t.seconds)) (\(n) \(n == 1 ? "session" : "sessions"))"
            }
            return "## \(title): \(span(all))\n\n" + rows.joined(separator: "\n") + "\n"
        }
        let thisWeek = sessions.filter { $0.start >= week && $0.start < now.addingTimeInterval(1) }
        var devices: [String: TimeInterval] = [:]
        for s in thisWeek { devices[s.device ?? s.host, default: 0] += s.active(at: now) }
        let deviceRows = devices.sorted { $0.value > $1.value }.filter { $0.value >= 60 }.map { "- \($0.key): \(span($0.value))" }
        return """
        # Glyph Time

        Hours by project from Glyph Time, every device (sessions in data/apps/time/sessions). \
        Rewritten as sessions end; the session files are the record.

        \(block("Today, \(day.string(from: today))", from: today, to: today.addingTimeInterval(86_400)))
        \(block("This week, from \(day.string(from: week))", from: week, to: week.addingTimeInterval(7 * 86_400)))
        \(block("Last week, from \(day.string(from: lastWeek))", from: lastWeek, to: week))
        ## This week by device

        \(deviceRows.isEmpty ? "Nothing timed." : deviceRows.joined(separator: "\n"))

        """
    }
}
