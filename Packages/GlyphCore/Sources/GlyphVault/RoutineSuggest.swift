import Foundation

/// Ideas for routines from what the vault already holds (`glyphcore-report routines suggest`):
/// Garmin activities (data/apps/garmin-connect/timeline), Glyph Well logs (data/apps/well/entries)
/// and Glyph Time sessions (data/apps/time/sessions). Plain rules over the last four weeks, each
/// one easy to explain:
///   - on fixed weekdays: the same thing on a weekday in 3 of the 4 weeks, and seldom on others ("Gym, Mon Wed Fri")
///   - so many days a week: 2 or more days in 3 of the 4 weeks, on any days ("Walk, 4 a week")
/// A time of day is added when most starts sit within an hour of each other. Once offered, an
/// idea is never offered again (added, dismissed or still open), nor one named like a routine.
public enum RoutineSuggest {
    /// One thing that happened: what, when, and where it was read.
    public struct Seen: Equatable, Sendable {
        public var title: String
        public var at: Date
        public var source: String
        public init(_ title: String, at: Date, source: String) { self.title = title; self.at = at; self.source = source }
    }

    /// The host name suggestion lines are written under: `<month>.routines.jsonl`.
    public static let host = "routines"

    /// Logs that are not habits (Well), and Garmin recordings that are travel, not exercise.
    static let notHabits: Set<String> = ["food", "mood", "stool", "symptom", "note", "sleep"]
    static let travel = ["drive", "track me", "commute", "flight"]

    // MARK: Reading the vault

    /// Everything the three apps have seen.
    public static func seen(vault: URL, now: Date = .now, cal: Calendar = .current) -> [Seen] {
        garmin(vault, cal: cal) + well(vault) + time(vault, now: now)
    }

    /// Garmin's monthly timeline tables: | Day | Start | Name | Type | Where | Time | km |; the name without its place.
    static func garmin(_ vault: URL, cal: Calendar) -> [Seen] {
        let folder = vault.appending(path: "data/apps/garmin-connect/timeline")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [Seen] = []
        var f = DateComponents()
        for name in names where name.hasSuffix(".md") {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("| 2") {
                let c = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard c.count >= 5 else { continue }
                let d = c[0].split(separator: "-").compactMap { Int($0) }, t = c[1].split(separator: ":").compactMap { Int($0) }
                guard d.count == 3, t.count == 2 else { continue }
                f.year = d[0]; f.month = d[1]; f.day = d[2]; f.hour = t[0]; f.minute = t[1]
                guard let at = cal.date(from: f) else { continue }
                var title = c[2]
                if !c[4].isEmpty, title.hasPrefix(c[4] + " ") { title = String(title.dropFirst(c[4].count + 1)) }
                let low = title.lowercased()
                guard !title.isEmpty, !travel.contains(where: { low.contains($0) }) else { continue }
                out.append(Seen(title, at: at, source: "garmin"))
            }
        }
        return out
    }

    /// Glyph Well's logs (not meals, moods or symptoms), less the ones deleted.
    static func well(_ vault: URL) -> [Seen] {
        let folder = vault.appending(path: "data/apps/well/entries")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var logs: [(id: String?, Seen)] = [], gone = Set<String>()
        for name in names where name.hasSuffix(".jsonl") {
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let event = o["event"] as? String else { continue }
                if event == "delete", let id = o["id"] as? String { gone.insert(id); continue }
                guard event == "log", let kind = o["kind"] as? String, !notHabits.contains(kind),
                      let stamp = (o["at"] ?? o["ts"]) as? String, let at = TimeLog.stamp.date(from: stamp) else { continue }
                let title = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? kind.capitalized
                logs.append((o["id"] as? String, Seen(title, at: at, source: "well")))
            }
        }
        return logs.filter { $0.id.map { !gone.contains($0) } ?? true }.map(\.1)
    }

    /// Glyph Time's named sessions of 25 minutes or more: blocks of focused work.
    static func time(_ vault: URL, now: Date) -> [Seen] {
        TimeLog.sessions(TimeLog.read(vault.appending(path: "data/apps/time/sessions"), months: TimeLog.recentMonths(now, count: 2)))
            .filter { $0.end != nil && $0.active(at: now) >= 25 * 60 }
            .compactMap { s in s.project.flatMap { $0.isEmpty ? nil : Seen($0, at: s.start, source: "time") } }
    }

    // MARK: The rules

    /// Ideas from `seen` over the four whole weeks before `now`'s day, best first, leaving out
    /// what `events` already offered or names as a routine. At most `limit`.
    public static func suggest(_ seen: [Seen], events: [TimeEvent], now: Date = .now, cal: Calendar = .current, limit: Int = 3) -> [RoutineSuggestion] {
        let today = cal.startOfDay(for: now)
        guard let from = cal.date(byAdding: .day, value: -28, to: today) else { return [] }
        let offered = Set(events.filter { $0.event == "routine-suggestion" }.compactMap(\.id))
        let named = Set(TimeLog.routines(events, cal: cal).map { key($0.title) })
        let open = TimeLog.routineSuggestions(events).count
        guard open < limit else { return [] }
        var groups: [String: [Seen]] = [:], order: [String] = []
        for s in seen where s.at >= from && s.at < today {
            let k = key(s.title)
            guard !k.isEmpty else { continue }
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(s)
        }
        var out: [(score: Int, s: RoutineSuggestion)] = []
        for k in order {
            let id = "s-" + k
            guard !offered.contains(id), !named.contains(k), let all = groups[k] else { continue }
            if let s = rule(all, id: id, from: from, cal: cal) { out.append(s) }
        }
        out += TimeLog.snoozeIdeas(events, now: now, calendar: cal).filter { !offered.contains($0.s.id) } // TimeSnoozes.swift
        return out.sorted { $0.score > $1.score }.prefix(limit - open).map(\.s)
    }

    /// One thing's four weeks, as an idea, or nil when it shows no steady pattern.
    static func rule(_ all: [Seen], id: String, from: Date, cal: Calendar) -> (Int, RoutineSuggestion)? {
        // Each of the four weeks, as the set of weekdays it happened on (one per day, however many times).
        var weeks = Array(repeating: Set<Int>(), count: 4)
        for s in all {
            let n = cal.dateComponents([.day], from: from, to: cal.startOfDay(for: s.at)).day ?? -1
            guard (0..<28).contains(n) else { continue }
            weeks[n / 7].insert(Routine.weekday(s.at, cal))
        }
        let first = all.min { $0.at < $1.at }!
        let time = usualTime(all.map(\.at), cal: cal)
        // On fixed weekdays: weekdays it happened on in 3 or 4 of the weeks, holding 3 in 4 of the days it happened
        // (four days a week on shifting days lands on some weekday 3 times by chance alone).
        let hits = (1...7).map { d in weeks.filter { $0.contains(d) }.count }
        let days = (1...7).filter { hits[$0 - 1] >= 3 }
        let onDays = days.map { hits[$0 - 1] }.reduce(0, +), total = weeks.map(\.count).reduce(0, +)
        if !days.isEmpty, onDays * 4 >= total * 3 {
            let least = days.map { hits[$0 - 1] }.min()!
            let why = "\(least) of the last 4 weeks" // the days are in the card's title line
            return (days.count * least, RoutineSuggestion(id: id, title: first.title, days: days.count == 7 ? [] : days, time: time,
                                                          why: why, source: first.source))
        }
        // So many days a week, on any days: at least 2 days in 3 of the weeks.
        let counts = weeks.map(\.count).sorted(by: >)
        let perWeek = counts[2]
        guard perWeek >= 2 else { return nil }
        let morning = time.map { cal.component(.hour, from: $0) < 12 } ?? false
        let why = "\(perWeek) \(morning ? "mornings" : "days") a week lately"
        return (perWeek * 3, RoutineSuggestion(id: id, title: first.title, time: time, rule: "w\(perWeek)", why: why, source: first.source))
    }

    /// The usual time of day, to the quarter hour, when 3 in 4 starts sit within an hour of the middle one.
    static func usualTime(_ dates: [Date], cal: Calendar) -> Date? {
        let minutes = dates.map { cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0) }.sorted()
        guard !minutes.isEmpty else { return nil }
        let mid = minutes[minutes.count / 2]
        guard Double(minutes.filter { abs($0 - mid) <= 60 }.count) >= Double(minutes.count) * 0.75 else { return nil }
        let q = (mid + 7) / 15 * 15
        return cal.date(bySettingHour: q / 60 % 24, minute: q % 60, second: 0, of: cal.startOfDay(for: .now))
    }

    /// "gym", "morning-walk": a title as an id part, the same for "Gym" and "gym ".
    static func key(_ title: String) -> String {
        let chars: [Character] = title.lowercased().map { c -> Character in c.isLetter || c.isNumber ? c : "-" }
        return String(chars).split(separator: "-").joined(separator: "-")
    }

    /// Reads the vault, works out the ideas, and (unless `write` is false) adds them as lines.
    @discardableResult
    public static func run(vault: URL, write: Bool, now: Date = .now, cal: Calendar = .current) throws -> [RoutineSuggestion] {
        let folder = vault.appending(path: "data/apps/time/sessions")
        let events = TimeLog.read(folder, months: TimeLog.recentMonths(now, count: 12))
        let ideas = suggest(seen(vault: vault, now: now, cal: cal), events: events, now: now, cal: cal)
        if write { for s in ideas { try TimeLog.append(s.line(host: host, at: now), to: folder) } }
        return ideas
    }
}
