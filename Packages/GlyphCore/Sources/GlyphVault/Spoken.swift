import Foundation

/// Spoken words, shared by every Glyph app that reads what was said (Glyph Time's scheduling, Glyph
/// Well's logging, Jot, CRM, the filer): number words as digits, weekdays, months, ordinals, a time of
/// day ("half past 7", "7:30 pm", "7 in the morning") and small regex helpers. Pure Foundation, so a
/// `cat ... | swift -` check can include this file. Moved here from Glyph Time (2026-10-29), unchanged.
public enum Spoken {
    public static let numbers = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                  "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                                  "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
    public static let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
                           "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
                           "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30]


    /// Lower case, "a.m." as "am", "7.30" as "7:30", number words as digits ("seven thirty" is
    /// "7 30", "twenty five" is "25"), filler words and punctuation out, single spaces.
    public static func normalize(_ said: String, dropping fillers: Set<String> = []) -> String {
        var s = " " + said.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "o'clock", with: " ").replacingOccurrences(of: "oclock", with: " ") + " "
        s = sub(s, #"\b([ap])\.?\s?m\b\.?"#, "$1m")
        s = sub(s, #"(\d{1,2})\.(\d{2})\b"#, "$1:$2")
        s = sub(s, #"(\d)(st|nd|rd|th)\b"#, "$1th")
        s = sub(s, #"[^a-z0-9:'/ ]"#, " ")
        s = sub(s, #"\b(an hour and a half|one and a half hours|1 and a half hours)\b"#, "90 minutes")
        s = sub(s, #"\b(a )?quarter (of an )?hour\b"#, "15 minutes")
        s = sub(s, #"\bhalf (an )?hour\b"#, "30 minutes")
        s = sub(s, #"\ba (couple|couple of)\b"#, "2")
        s = sub(s, #"\b(the )?day after tomorrow\b"#, "in 2 days")
        // Number words to digits, tens and units joined ("twenty five" is 25).
        var words = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var w = words[i]
            if w.contains("-"), let a = numbers[String(w.split(separator: "-").first ?? "")], let b = numbers[String(w.split(separator: "-").last ?? "")], a >= 20, b < 10 {
                w = String(a + b)
            } else if let n = numbers[w] {
                if n >= 20, i + 1 < words.count, let u = numbers[words[i + 1]], u > 0, u < 10 { w = String(n + u); i += 1 } else { w = String(n) }
            }
            if !fillers.contains(w) { out.append(w) }
            i += 1
        }
        words = out
        return " " + words.joined(separator: " ") + " "
    }


    /// A time of day: (hour 0-23, minute, said with am, pm or a part of the day).
    public struct Clock: Equatable, Sendable {
        public var h: Int; public var m: Int; public var marked: Bool
        public init(h: Int, m: Int, marked: Bool) { self.h = h; self.m = m; self.marked = marked }
    }

    static let pm = #"(?:pm|in the afternoon|this afternoon|afternoon|in the evening|this evening|evening|at night|tonight|night)"#
    static let am = #"(?:am|in the morning|this morning|morning)"#

    /// The first time of day in normalized text, with where it was.
    public static func clockMatch(_ s: String) -> (Clock, Range<String.Index>)? {
        func mark(_ h: Int, _ tail: String) -> (Int, Bool) {
            if tail.range(of: "^\\s*" + pm, options: .regularExpression) != nil { return (h < 12 ? h + 12 : h, true) }
            if tail.range(of: "^\\s*" + am, options: .regularExpression) != nil { return (h == 12 ? 0 : h, true) }
            return (h, false)
        }
        let tail = #"(\s*(?:"# + pm + "|" + am + #"))?"#
        if let m = first(#"\b(noon|midday|midnight)\b"#, s) { return (Clock(h: m[1] == "midnight" ? 0 : 12, m: 0, marked: true), m.range) }
        if let m = first(#"\b(half|quarter|\d{1,2}) (?:past|after) (\d{1,2})\b"# + tail, s), let h = Int(m[2]), h <= 12 {
            let min = m[1] == "half" ? 30 : m[1] == "quarter" ? 15 : Int(m[1]) ?? 0
            let (hh, mk) = mark(h, m[3]); return (Clock(h: hh, m: min, marked: mk), m.range)
        }
        if let m = first(#"\b(?:at )?(quarter|\d{1,2}) (?:to|till|before) (\d{1,2})\b"# + tail, s), let h = Int(m[2]), h <= 12,
           m[1] == "quarter" || m[0].hasPrefix("at ") {
            let min = m[1] == "quarter" ? 15 : Int(m[1]) ?? 0
            let (hh, mk) = mark(h == 0 ? 11 : h - 1, m[3]); return (Clock(h: hh, m: 60 - min, marked: mk), m.range)
        }
        // "7:30 am", "7 30 am", "at 7 30", "730 am", "7 am", "at 7", "7 in the morning".
        let forms = [#"\b(\d{1,2}):(\d{2})\b"# + tail, #"\b(\d{1,2}) ([0-5]\d)\b"# + #"(\s*(?:"# + pm + "|" + am + "))",
                     #"\bat (\d{1,2}) ([0-5]\d)\b"# + tail, #"\b(\d{1,2})([0-5]\d)\s*(am|pm)\b"#, #"\b(\d{1,2})\s*"# + #"(\s*(?:"# + pm + "|" + am + "))",
                     #"\b(?:at|by|around) (\d{1,2})\b(?! ?(?:minutes?|mins?|hours?|days?|weeks?|months?|seconds?|th\b))"# + tail]
        for (i, f) in forms.enumerated() {
            guard let m = first(f, s), let h = Int(m[1]), h <= 23 else { continue }
            let hasMin = i < 4
            let mi = hasMin ? Int(m[2]) ?? 0 : 0
            let t = hasMin ? m[3] : m[2]
            let (hh, mk) = mark(h, t)
            return (Clock(h: h > 12 ? h : hh, m: min(59, mi), marked: mk || h > 12 || h == 0), m.range)
        }
        return nil
    }

    public static let weekdays: [(String, Int)] = [("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6), ("sunday", 7),
                                             ("mon", 1), ("tues", 2), ("tue", 2), ("wed", 3), ("thurs", 4), ("thur", 4), ("thu", 4), ("fri", 5), ("sat", 6), ("sun", 7)]
    public static let weekdayPattern = #"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|wed|thurs|thur|thu|fri|sat|sun)s?"#
    public static func weekday(_ w: String) -> Int? {
        let w = w.hasSuffix("s") && w.count > 4 ? String(w.dropLast()) : w
        return weekdays.first { $0.0 == w }?.1
    }
    public static let months = ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8, "september": 9,
                         "october": 10, "november": 11, "december": 12, "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8,
                         "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12]
    public static let monthPattern = #"(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"#
    public static let ordinalPattern = #"(?:\d{1,2}th|\d{1,2}|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth|twenty first|twenty second|twenty third|twenty fourth|twenty fifth|twenty sixth|twenty seventh|twenty eighth|twenty ninth|thirty first)"#
    public static func ordinal(_ s: String) -> Int? {
        if let n = Int(s.replacingOccurrences(of: "th", with: "")) { return n }
        if let n = ordinals[s] { return n }
        let p = s.split(separator: " ")
        if p.count == 2, let t = numbers[String(p[0])], let u = ordinals[String(p[1])] { return t + u }
        return nil
    }


    // MARK: Regex helpers

    public struct Match {
        public let groups: [String]
        public let range: Range<String.Index>
        public subscript(_ i: Int) -> String { i < groups.count ? groups[i] : "" }
    }

    public static func first(_ pattern: String, _ s: String) -> Match? { all(pattern, s, limit: 1).first }

    public static func all(_ pattern: String, _ s: String, limit: Int = .max) -> [Match] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var out: [Match] = []
        for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            let groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            out.append(Match(groups: groups, range: whole))
            if out.count >= limit { break }
        }
        return out
    }

    public static func sub(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
    }
}

/// When something already happened, from the way it was told: "Yesterday. In the morning I ran, in
/// the afternoon pizza, and I slept badly" puts all three on yesterday. For logging and recall (Glyph
/// Well, Jot, CRM notes), never for scheduling: a weekday is the last one that has come, never the
/// next, and nothing lands in the future. Each clause carries the last day and part of the day said
/// until a new one is said. The date math is here, in code; a model may split and label the words,
/// never work out a date. When the day had to be guessed ("last month"), `question` says what to ask.
public enum Recall {
    public enum Part: String, Sendable, CaseIterable, Codable {
        case morning, midday, afternoon, evening, night
        /// The usual hour, when only the part of the day was said (approximate).
        public var hour: Double { switch self { case .morning: 8; case .midday: 12; case .afternoon: 15; case .evening: 19; case .night: 22 } }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public struct When: Equatable, Sendable {
        /// The start of the day it happened.
        public var day: Date
        /// Hours after midnight, when a time or a part of the day was said.
        public var hour: Double?
        public var part: Part?
        /// The hour is a part of the day's usual hour, or the day is a guess.
        public var approximate = false
        /// Said as "last night": the night before `day + 1`.
        public var night = false
        /// The day had to be guessed: one short question to ask before saving.
        public var question: String?
        /// "Now", "right now", "currently": this moment.
        public var now = false
        public init(day: Date, hour: Double? = nil, part: Part? = nil, approximate: Bool = false, night: Bool = false, question: String? = nil, now: Bool = false) {
            self.day = day; self.hour = hour; self.part = part; self.approximate = approximate; self.night = night; self.question = question; self.now = now
        }

        /// The moment to file it at: the hour said, else now for today, else midday of that day
        /// (approximate). Never after `now`.
        public func date(now: Date, cal: Calendar = .current) -> Date {
            let today = cal.startOfDay(for: now)
            let d: Date
            if let hour { d = cal.date(byAdding: .minute, value: Int((hour * 60).rounded()), to: day)! }
            else if day >= today || self.now { d = now }
            else { d = cal.date(byAdding: .hour, value: 12, to: day)! }
            return min(d, now)
        }
        /// True when nothing but the day is known for a past day (filed at midday).
        public var dayOnly: Bool { hour == nil && !now }
    }

    /// One piece of what was said, with when (nil: nothing said yet, so now) and where it was said to happen.
    public struct Clause: Equatable, Sendable {
        public var text: String
        public var when: When?
        public var place: String?
    }

    public static let fillers: Set<String> = ["uh", "uhh", "um", "umm", "uhm", "er", "erm", "ah", "hmm", "hm", "mm"]

    /// The words split where a new thing starts (sentence ends, commas, "and", "then", "but"), each
    /// with its time and place carried forward until a new one is said.
    public static func clauses(_ said: String, now: Date, cal: Calendar = .current) -> [Clause] {
        let pieces = said.replacingOccurrences(of: #"\b([aApP])\.\s?[mM]\.?"#, with: "$1m", options: .regularExpression)
            .replacingOccurrences(of: #"[.!?;]+(?=\s|$)|,\s*|\s+(?:and then|after that|and later|later on|then|but|and)\s+"#,
                                               with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?i)(and then|then|and|but|also|plus)\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        var out: [Clause] = []
        var current: When?
        var place: String?
        for p in pieces {
            let s = Spoken.normalize(p, dropping: fillers)
            if let w = read(s, carry: current, now: now, cal: cal) {
                if w.day != current?.day || w.hour != current?.hour { place = nil }
                current = w
            }
            if let here = Recall.place(p) { place = here }
            out.append(Clause(text: p, when: current, place: place))
        }
        return out
    }

    /// One phrase on its own ("tuesday", "last night", "on the 3rd at 7 pm"), for a correction or an answer.
    public static func when(_ phrase: String, now: Date, cal: Calendar = .current) -> When? {
        read(Spoken.normalize(phrase, dropping: fillers), carry: nil, now: now, cal: cal)
    }

    /// What this clause says about when, on top of what came before. Nil when it says nothing.
    static func read(_ s: String, carry: When?, now: Date, cal: Calendar) -> When? {
        let today = cal.startOfDay(for: now)
        let anchor = day(s, now: now, cal: cal)
        let time = hour(s, part: anchor?.part)
        guard anchor != nil || time != nil else { return nil }
        // The same day said again with no time ("in the morning ... I mean yesterday"): the time carries on.
        if var a = anchor, time == nil, let carry, a.day == carry.day, a.hour == nil, a.part == nil, carry.hour != nil {
            a.hour = carry.hour; a.part = carry.part; a.approximate = carry.approximate; return a
        }
        var w = anchor ?? When(day: carry?.day ?? today, night: false, question: carry?.question)
        if anchor == nil, let carry { w.approximate = carry.approximate && carry.question != nil }
        if var time {
            // "Had pasta at 7" said in the evening: the 7 that has just been, not this morning's.
            if !time.marked, time.hour >= 7, time.hour < 12, w.day == today,
               cal.date(byAdding: .minute, value: Int((time.hour + 12) * 60), to: today)! <= now { time.hour += 12; time.part = part(of: time.hour) }
            w.hour = time.hour; w.part = time.part ?? w.part; w.approximate = w.approximate || time.approximate
        } else if let part = w.part {
            w.hour = part.hour; w.approximate = true
        }
        // Later today than now: it hasn't happened yet, so it is now (said in the past tense, "tonight" can't be later).
        if w.day == today, let h = w.hour, cal.date(byAdding: .minute, value: Int(h * 60), to: today)! > now { w.hour = nil; w.part = nil; w.approximate = false }
        return w
    }

    /// The day said, as the start of that day. A question when it had to be guessed.
    static func day(_ s: String, now: Date, cal: Calendar) -> When? {
        let today = cal.startOfDay(for: now)
        func back(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }
        func f(_ p: String) -> Spoken.Match? { Spoken.first(p, s) }
        func count(_ x: String) -> Int { Int(x) ?? 1 }
        let part = partWord(s)
        if f(#"\b(the )?day before yesterday\b"#) != nil { return When(day: back(2), part: part) }
        if f(#"\blast night\b"#) != nil { return When(day: back(1), part: .night, night: true) }
        if f(#"\byesterday\b"#) != nil { return When(day: back(1), part: part) }
        if let m = f(#"\b(\d+) (?:of )?days? ago\b"#) { return When(day: back(count(m[1])), part: part) }
        if f(#"\b(a few|few|several) days ago\b"#) != nil { return When(day: back(3), part: part, approximate: true, question: "Which day was that?") }
        if let m = f(#"\b(\d+|a|an) (?:of )?weeks? ago\b"#) {
            let n = count(m[1]); return When(day: back(7 * n), part: part, approximate: true, question: n == 1 ? "Which day a week ago?" : "Which day \(n) weeks ago?")
        }
        if f(#"\blast weekend\b"#) != nil {
            let todayWD = (cal.component(.weekday, from: today) + 5) % 7 + 1  // 1 Monday ... 7 Sunday
            let diff = (todayWD - 6 + 7) % 7
            return When(day: back(diff <= 1 ? diff + 7 : diff), part: part, approximate: true, question: "Saturday or Sunday?")
        }
        if f(#"\blast week\b"#) != nil { return When(day: back(7), part: part, approximate: true, question: "Which day last week?") }
        if let m = f(#"\b(\d+|a|an) months? ago\b"#) {
            let n = count(m[1]); return When(day: cal.date(byAdding: .month, value: -n, to: today)!, part: part, approximate: true, question: "Which day \(n == 1 ? "a month" : "\(n) months") ago?")
        }
        if f(#"\blast month\b"#) != nil { return When(day: cal.date(byAdding: .month, value: -1, to: today)!, part: part, approximate: true, question: "Which day last month?") }
        if f(#"\blast year\b"#) != nil { return When(day: cal.date(byAdding: .year, value: -1, to: today)!, part: part, approximate: true, question: "When last year?") }
        if f(#"\b(tomorrow|next (week|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#) != nil {
            return When(day: today, approximate: true, question: "That sounds like later. When did it happen?")
        }
        let names = #"(monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?"#
        if let m = f(#"\b(last |this past |past |on |this )?"# + names + #"\b"#), let wd = Spoken.weekday(m[2]) {
            let todayWD = (cal.component(.weekday, from: today) + 5) % 7 + 1  // 1 Monday ... 7 Sunday
            var diff = (todayWD - wd + 7) % 7
            if diff == 0, m[1].contains("last") || m[1].contains("past") { diff = 7 }
            return When(day: back(diff), part: part)
        }
        func dated(_ month: Int, _ d: Int) -> When? {
            let y = cal.component(.year, from: today)
            guard var x = cal.date(from: DateComponents(year: y, month: month, day: d)), cal.component(.day, from: x) == d else { return nil }
            if x > today { x = cal.date(from: DateComponents(year: y - 1, month: month, day: d))! }
            return When(day: x, part: part)
        }
        if let m = f(#"\b("# + Spoken.monthPattern + #") (?:the )?("# + Spoken.ordinalPattern + #")\b"#), let mo = Spoken.months[m[1]], let d = Spoken.ordinal(m[2]), let w = dated(mo, d) { return w }
        if let m = f(#"\b(?:the )?("# + Spoken.ordinalPattern + #") (?:of )?("# + Spoken.monthPattern + #")\b"#), let mo = Spoken.months[m[2]], let d = Spoken.ordinal(m[1]), let w = dated(mo, d) { return w }
        if let m = f(#"\b(\d{1,2})/(\d{1,2})\b"#), let mo = Int(m[1]), let d = Int(m[2]), (1...12).contains(mo), let w = dated(mo, d) { return w }
        // "the 3rd", "on the third" (a bare "the first" is too often not a date).
        if let m = f(#"\b(on )?the ("# + Spoken.ordinalPattern + #")\b"#), let d = Spoken.ordinal(m[2]), (1...31).contains(d), m[2].hasSuffix("th") || (Int(m[2]) == nil && !m[1].isEmpty) {
            // The 3rd: this month's, or last month's while this month's is still ahead.
            var c = cal.dateComponents([.year, .month], from: today); c.day = d
            for _ in 0..<3 {
                if let x = cal.date(from: c), cal.component(.day, from: x) == d, x <= today { return When(day: x, part: part) }
                c.month! -= 1
            }
        }
        if f(#"\b(earlier )?this week\b"#) != nil { return When(day: today, part: part, approximate: true, question: "Which day this week?") }
        if f(#"\b(earlier )?this month\b"#) != nil { return When(day: today, part: part, approximate: true, question: "Which day this month?") }
        if f(#"\b(right now|now|currently|at the moment)\b"#) != nil { return When(day: today, now: true) }
        if f(#"\b(today|this morning|this afternoon|this evening|tonight|earlier today|so far)\b"#) != nil { return When(day: today, part: part) }
        return nil
    }

    /// A part of the day said in words ("in the morning", "at lunch", "after dinner").
    static func partWord(_ s: String) -> Part? {
        partHour(s)?.0
    }

    static func partHour(_ s: String) -> (Part, Double)? {
        let table: [(String, Part, Double)] = [
            (#"\b(last night|tonight|at night|in the night|before bed|bedtime|night)\b"#, .night, 22),
            (#"\bafter dinner\b"#, .evening, 19.5), (#"\b(evening|after work|dinner|supper)\b"#, .evening, 19),
            (#"\bafternoon\b"#, .afternoon, 15),
            (#"\bafter lunch\b"#, .midday, 13), (#"\b(lunch|lunchtime)\b"#, .midday, 12.5), (#"\b(noon|midday)\b"#, .midday, 12),
            (#"\b(woke up|when i got up|first thing)\b"#, .morning, 7), (#"\bafter breakfast\b"#, .morning, 8.5),
            (#"\b(morning|breakfast)\b"#, .morning, 8),
        ]
        return table.first { Spoken.first($0.0, s) != nil }.map { ($0.1, $0.2) }
    }

    /// A clock time said ("at 7", "7:30 pm", "half past 3") or a part of the day. Numbers that are not
    /// times ("type 4", "6 out of 10", "5 hours", "2 glasses") are taken out first.
    static func hour(_ s: String, part dayPart: Part?) -> (hour: Double, part: Part?, approximate: Bool, marked: Bool)? {
        let clean = Spoken.sub(s, #"\b(type|level|number|bristol) \d+\b|\b\d+ ?(out of|/) ?\d+\b|\b\d+(\.\d+)? ?(hours?|hrs?|minutes?|mins?|glasses|cups|times|mg|days?|weeks?|months?|years?|pounds?|lbs?|kg|miles?|km|steps|reps|sets)\b"#, " ")
        let said = partHour(clean)
        if let (c, _) = Spoken.clockMatch(clean) {
            var h = c.h
            let p = said?.0 ?? dayPart
            if !c.marked, h < 12 {
                if let p { if p != .morning, h < 12, !(p == .night && h <= 4) { h += 12 } }
                else if h <= 6 { h += 12 }
            }
            let hour = Double(h) + Double(c.m) / 60
            return (hour, p ?? part(of: hour), false, c.marked || p != nil)
        }
        if let (p, h) = said { return (h, p, true, true) }
        return nil
    }

    static func part(of hour: Double) -> Part {
        hour < 11 ? .morning : hour < 14 ? .midday : hour < 17 ? .afternoon : hour < 21 ? .evening : .night
    }

    /// Where it happened, when the words say: "at the gym", "at Mom's", "at Northwind Clinic". The name
    /// as said; matching it to a Glyph CRM place is the app's job.
    public static func place(_ said: String) -> String? {
        let common = #"gym|office|work|home|school|church|mosque|park|beach|pool|hospital|clinic|doctor's|dentist|pharmacy|restaurant|bar|cafe|coffee shop|mall|store|grocery store|airport|hotel|studio|library|trail|lake|track"#
        if let m = Spoken.first(#"\b(?:at|to|in|from) (?:the |my |a )?("# + common + #")\b"#, said) {
            return m[1].prefix(1).uppercased() + m[1].dropFirst()
        }
        if let m = Spoken.first(#"\b(?:at|to) (?:my )?([a-z]+'s)(?: (?:house|place))?\b"#, said.lowercased()), !["it's", "that's", "what's", "there's"].contains(m[1]) {
            return m[1].prefix(1).uppercased() + m[1].dropFirst()
        }
        // A name said with capitals: "at Northwind Clinic".
        if let r = said.range(of: #"\b(?:at|to) ((?:[A-Z][a-z'’]+)(?: [A-Z][a-z'’]+){0,3})"#, options: .regularExpression) {
            let name = said[r].split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            let skip = Spoken.weekdays.map(\.0) + Spoken.months.keys.map { $0 } + ["i", "noon", "night", "lunch", "dinner", "breakfast", "first", "least", "all", "home"]
            if !name.isEmpty, !skip.contains(name.lowercased().components(separatedBy: " ").first ?? "") { return name }
        }
        return nil
    }
}
