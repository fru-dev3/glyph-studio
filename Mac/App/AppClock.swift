import Foundation

/// "Now", pinnable for tests: STUDIO_TODAY=2026-10-26 makes today that date (at the current time of day),
/// STUDIO_TODAY=2026-10-26T21:58 that exact minute;
/// so the week strip and "due in N days" match the design renders on any day. Use it, never Date().
enum AppClock {
    static var now: Date {
        guard let s = Engine.env["STUDIO_TODAY"] else { return Date() }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let exact = f.date(from: s) { return exact } // STUDIO_TODAY=2026-10-26T21:58 pins the time too
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: s) else { return Date() }
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute, .second], from: Date())
        return cal.date(bySettingHour: t.hour ?? 12, minute: t.minute ?? 0, second: t.second ?? 0, of: day) ?? day
    }
    static var today: Date { Calendar.current.startOfDay(for: now) }
}
