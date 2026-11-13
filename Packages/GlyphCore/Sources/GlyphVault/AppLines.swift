import CryptoKit
import Foundation

// The few lines other apps write that an agent writes too, byte for byte what those apps write today, so each
// app shows what an agent did and Fru checks it there. Every line carries an id, so sending it twice is the same
// line (the hub merges month files line by line) and Undo is the app's own delete line.

/// Local time with its offset, as the apps write it: 2026-10-27T08:10:00-05:00.
public func localStamp(_ d: Date) -> String {
    let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
}

/// "2026-10-27 08-10-00": Jot's memo names and CRM's note names.
public func fileStem(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f.string(from: d)
}

func sortedJSON(_ o: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
}

/// Glyph Well's entry lines (WellKit's WellLog): `data/apps/well/entries/<YYYY-MM>.<host>.jsonl`.
public enum WellLine {
    public static let kinds = ["symptom", "mood", "energy", "sleep", "food", "med", "stress", "activity", "event", "note"]

    /// A `log` line: what happened (`name`, 1 to 4 words), its kind, the words it came from, when.
    public static func log(id: String, kind: String, name: String, said: String, at: Date, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["at": localStamp(at), "event": "log", "host": host, "device": device, "id": id,
                    "kind": kinds.contains(kind) ? kind : "note", "name": name, "said": said, "via": "voice", "ts": localStamp(now)]) + "\n"
    }

    /// Takes an entry back (the line stays in the file, as Well does it).
    public static func delete(id: String, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["event": "delete", "host": host, "device": device, "id": id, "ts": localStamp(now)]) + "\n"
    }

    public static func file(_ d: Date, host: String) -> String { "\(fileStem(d).prefix(7)).\(host).jsonl" }
}

/// Glyph Jot's memo as the iPhone sends it to the hub (`PUT /memo/<stem>`); the stem is its id.
public enum JotMemo {
    /// Tags name domains the way Jot does ("Dreams" to dreams); the hub keeps only domains that exist.
    public static func body(text: String, tags: [String], device: String, kind: String = "voice") -> Data {
        let domains = tags.map { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-") }
        return Data(sortedJSON(["tags": tags, "domains": domains, "kind": kind, "text": text, "device": device]).utf8)
    }
}

/// Glyph CRM's suggestion lines (CRMKit's Proposal): `data/apps/crm/proposals/<YYYY-MM>.jsonl`. A suggestion
/// waits in CRM for a yes before anything reaches an entity page.
public enum CRMProposalLine {
    /// CRMKit's id (Proposal.init): the same thing said twice is the same suggestion.
    /// `note` only for a "Which Ken?" (`choices`): two of them about different things are two questions.
    public static func id(kind: String, name: String, key: String? = nil, value: String? = nil, linkAs: String? = nil,
                          toKind: String? = nil, toName: String? = nil, path: String? = nil, note: String? = nil) -> String {
        let key = [kind, name.lowercased(), key?.lowercased() ?? "", value ?? "", linkAs?.lowercased() ?? "", toKind ?? "",
                   toName?.lowercased() ?? "", path ?? ""].joined(separator: "|") + (note.map { "|" + $0 } ?? "")
        return String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// CRMKit's kinds: person, place, org (a company, brand or app, stored under orgs), thing.
    public static func kind(_ said: String) -> String {
        let k = said.lowercased()
        return ["org", "company", "organization", "business", "brand", "product"].contains(k) ? "org" : ["person", "place", "thing"].contains(k) ? k : "person"
    }

    /// A suggestion: about an entity (new, or `existing` by its permanent id), an attribute (`key`, `value`) or a
    /// link (`linkAs` to `toKind`/`toName`; "same as" is a merge into that one). `choices`: the pages a name fits
    /// ("Which Ken?"); the yes must pick one of them or a new one. `note` goes on the page on a yes.
    public static func line(kind: String, name: String, evidence: String, source: String = "voice", at: Date = .now, existing: String? = nil,
                            key: String? = nil, value: String? = nil, linkAs: String? = nil, toKind: String? = nil, toName: String? = nil,
                            choices: [String]? = nil, note: String? = nil) -> String {
        let kind = Self.kind(kind)
        var o: [String: Any] = ["at": ISO8601DateFormatter().string(from: at), "evidence": String(evidence.prefix(240)),
                                "id": id(kind: kind, name: name, key: key, value: value, linkAs: linkAs, toKind: toKind, toName: toName,
                                         note: choices?.isEmpty == false ? note ?? "" : nil),
                                "kind": kind, "name": name, "source": source, "status": "pending"]
        for (k, v) in [("existing", existing), ("key", key), ("value", value), ("linkAs", linkAs?.lowercased()), ("toKind", toKind), ("toName", toName)] {
            if let v { o[k] = v }
        }
        if let choices, !choices.isEmpty { o["choices"] = choices }
        if let note, !note.isEmpty { o["note"] = note }
        return sortedJSON(o) + "\n"
    }

    public static func file(_ d: Date) -> String { "data/apps/crm/proposals/\(fileStem(d).prefix(7)).jsonl" }

    /// The file with this suggestion added, or nil when it is already there (sending again changes nothing).
    public static func adding(_ line: String, to text: String?) -> String? {
        let t = text ?? ""
        if let id = idOf(line), t.split(separator: "\n").contains(where: { idOf(String($0)) == id }) { return nil }
        return (t.isEmpty || t.hasSuffix("\n") ? t : t + "\n") + line
    }

    /// The file with this suggestion turned down (Undo), as CRM's review marks it.
    public static func rejecting(_ id: String, in text: String) -> String? { settling(id, as: "rejected", in: text) }

    /// The file with this suggestion answered (accepted on that page, `existing`), as CRM's review marks it.
    public static func settling(_ id: String, as status: String, existing: String? = nil, in text: String) -> String? {
        var changed = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
            guard idOf(String(l)) == id, var o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                  o["status"] as? String == "pending" else { return String(l) }
            o["status"] = status; changed = true
            if let existing { o["existing"] = existing }
            return sortedJSON(o)
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    static func idOf(_ line: String) -> String? { ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? String }
}

/// Glyph Time's request queue: an agent asks, Time arms (it owns AlarmKit, its list, Undo and cancel) and
/// answers on the same line's id. One JSON line each, in the App Group both apps share; Time sweeps it on
/// every launch, so a request is never lost when the link doesn't open Time.
///     {"id":"..","event":"request","kind":"alarm","command":"wake me up in 2 hours","ts":".."}
///     {"id":"..","event":"armed","text":"Alarm at 4:51 AM","ts":".."}     (or "failed", with why)
public struct TimeRequest: Codable, Equatable, Sendable {
    public var id: String
    public var event: String       // request, taken, armed, failed
    public var kind: String?       // alarm, reminder, timer
    public var command: String?    // words Time understands
    public var text: String?       // Time's answer
    public var ts: String

    public init(id: String, event: String, kind: String? = nil, command: String? = nil, text: String? = nil, now: Date = .now) {
        self.id = id; self.event = event; self.kind = kind; self.command = command; self.text = text; ts = localStamp(now)
    }

    public static let group = "group.dev.fru.glyph"

    /// The queue file: the shared App Group, else (no group, as in a plain test build) this app's Documents.
    public static var queue: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? URL.documentsDirectory)
            .appending(path: "time-requests.jsonl")
    }

    public static func append(_ r: TimeRequest, to url: URL = queue) {
        var d = (try? JSONEncoder().encode(r)) ?? Data(); d.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: d) }
        else { try? d.write(to: url, options: .atomic) }
    }

    public static func all(in url: URL = queue) -> [TimeRequest] {
        ((try? Data(contentsOf: url)) ?? Data()).split(separator: 0x0A).compactMap { try? JSONDecoder().decode(TimeRequest.self, from: Data($0)) }
    }

    /// Requests nobody has taken yet, oldest first.
    public static func pending(in url: URL = queue) -> [TimeRequest] {
        let all = all(in: url), answered = Set(all.filter { $0.event != "request" }.map(\.id))
        return all.filter { $0.event == "request" && !answered.contains($0.id) }
    }

    /// Time's last word on a request (armed or failed), nil while it waits.
    public static func answer(_ id: String, in url: URL = queue) -> TimeRequest? {
        all(in: url).last { $0.id == id && ($0.event == "armed" || $0.event == "failed") }
    }
}

/// Glyph Wealth's entry lines (WealthKit's WealthLog): `data/apps/wealth/entries/<YYYY-MM>.<host>.jsonl`.
/// Byte for byte what Glyph Wealth writes, so an agent's spend reads in the app as one Fru said himself.
/// Money is whole cents here as it is there: a Double in a money file is a wrong total later.
public enum WealthLine {
    /// What a line can be about. `balance` and `holding` carry an account; `spend` and `income` an amount.
    public static let kinds = ["spend", "income", "balance", "account", "transfer", "holding", "trade", "bill", "goal", "paper", "decision", "note"]
    public static let groups = ["cash", "invest", "retirement", "property", "card", "loan", "other"]

    /// A `log` line. `cents` is signed the way the file means it: a spend negative, income positive, a
    /// card's balance owed negative. `account` is the account's id (or its name, when the agent only
    /// heard a name and the app has to match it).
    public static func log(id: String, kind: String, name: String, cents: Int?, at: Date, host: String, device: String,
                           account: String? = nil, category: String? = nil, institution: String? = nil, group: String? = nil,
                           said: String, via: String = "voice", now: Date = .now) -> String {
        let kind = kinds.contains(kind) ? kind : "note"
        var o: [String: Any] = ["at": localStamp(at), "event": "log", "host": host, "device": device, "id": id,
                                "kind": kind, "said": said, "ts": localStamp(now), "via": via]
        if !name.isEmpty { o["name"] = name }
        if let cents { o["amount"] = cents }
        if let account, !account.isEmpty { o["account"] = account }
        if let category, !category.isEmpty { o["category"] = category }
        if let institution, !institution.isEmpty { o["institution"] = institution }
        if let group, groups.contains(group) { o["group"] = group }
        // A spend's payee is its name, as the app writes it, so a second import knows the merchant again.
        if kind == "spend", !name.isEmpty { o["payee"] = name }
        return sortedJSON(o) + "\n"
    }

    /// Takes an entry back (the line stays in the file, as Glyph Wealth does it).
    public static func delete(id: String, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["event": "delete", "host": host, "device": device, "id": id, "ts": localStamp(now)]) + "\n"
    }

    public static func file(_ d: Date, host: String) -> String { "\(fileStem(d).prefix(7)).\(host).jsonl" }

    /// A spend leaves, income arrives: the sign is the fact, not the screen's colour.
    public static func signed(_ cents: Int, kind: String) -> Int {
        switch kind {
        case "spend": -abs(cents)
        case "income": abs(cents)
        default: cents
        }
    }
}

/// Glyph Life's lines (LifeKit's `LifeLog`): `data/apps/life/entries/<YYYY-MM>.<host>.jsonl`. Life reads the
/// vault's own administration (filed documents, the app registry's costs, the domains' loops and task boards)
/// and writes only the two things nothing else holds: what was decided about a renewal, and a run of a
/// recurring administrative workflow. Folded by id, the last line winning, as Well's and Time's are.
///
///     {"amount":183.36,"app":"northwind","choice":"keep","event":"decide","id":"d-..","ts":".."}
///     {"domain":"insurance","event":"run","id":"r-..","loop":"renewal-watch","state":"start","steps":4,"ts":".."}
///     {"event":"run","id":"r-..","n":2,"state":"step","ts":".."}
///     {"event":"run","id":"r-..","state":"done","ts":".."}
///     {"event":"delete","id":"d-..","ts":".."}      takes one back (the line stays)
public enum LifeLine {
    /// A decision about a subscription's renewal: keep it, or cancel it. `app` is its id in the vault's app
    /// registry (`data/apps/<app>/manifest.json`), never a name; `amount` is what the decision is about, 0 when
    /// the registry has no cost on it.
    public static func decide(id: String, app: String, choice: String, amount: Double, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["amount": amount, "app": app, "choice": choice == "cancel" ? "cancel" : "keep", "device": device,
                    "event": "decide", "host": host, "id": id, "ts": localStamp(now)]) + "\n"
    }

    /// A workflow run started: the loop's id and the domain it belongs to, with how many steps it has.
    public static func start(id: String, loop: String, domain: String, steps: Int, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["device": device, "domain": domain, "event": "run", "host": host, "id": id, "loop": loop,
                    "state": "start", "steps": steps, "ts": localStamp(now)]) + "\n"
    }

    /// One step of a run done (`n` counts from 1), or the whole run finished (`n` nil).
    public static func step(id: String, n: Int?, host: String, device: String, now: Date = .now) -> String {
        var o: [String: Any] = ["device": device, "event": "run", "host": host, "id": id,
                                "state": n == nil ? "done" : "step", "ts": localStamp(now)]
        if let n { o["n"] = n }
        return sortedJSON(o) + "\n"
    }

    /// Takes one line back, as Well's delete does: the line stays in the file and readers skip its id.
    public static func delete(id: String, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["device": device, "event": "delete", "host": host, "id": id, "ts": localStamp(now)]) + "\n"
    }

    public static func file(_ d: Date, host: String) -> String { "\(fileStem(d).prefix(7)).\(host).jsonl" }
}

/// Glyph Travel's lines (TravelKit's TravelLog): `data/apps/travel/trips/<YYYY-MM>.<host>.jsonl`.
/// Byte for byte what Glyph Travel writes, so an agent's trip shows in the app and Fru checks it there.
public enum TravelLine {
    public static func file(_ d: Date, host: String) -> String { "\(fileStem(d).prefix(7)).\(host).jsonl" }

    /// `2027-03-19` in the local calendar.
    public static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// What a travel phrase means, read forward: travel is about days to come, so a day already
    /// past is taken as the next one of its kind (next year for a date, next week for a weekday).
    /// Nil when nothing about a day was said.
    public static func ahead(_ phrase: String, now: Date = .now, cal: Calendar = .current) -> (day: Date, hour: Double?)? {
        guard !phrase.trimmingCharacters(in: .whitespaces).isEmpty, let w = Recall.when(phrase, now: now, cal: cal) else { return nil }
        var d = w.day
        let today = cal.startOfDay(for: now)
        if d < today {
            // A weekday reads as the one coming; a date reads as next year's.
            let weeks = cal.dateComponents([.day], from: d, to: today).day ?? 0
            d = weeks <= 7 ? cal.date(byAdding: .day, value: 7, to: d)! : cal.date(byAdding: .year, value: 1, to: d)!
        }
        return (d, w.hour)
    }

    /// A trip. `when` is their words ("March 19 to March 31", "in July"); the first day read out of
    /// them is the trip's start, the second its end. Nothing is invented when nothing was said.
    public static func trip(id: String, name: String, place: String, when: String, why: String,
                            host: String, device: String, now: Date = .now) -> String {
        var o: [String: Any] = ["event": "trip", "host": host, "device": device, "id": id, "name": name,
                                "status": "planned", "ts": localStamp(now), "via": "voice"]
        if !place.isEmpty { o["place"] = place }
        if !why.isEmpty { o["why"] = why }
        let parts = when.components(separatedBy: CharacterSet(charactersIn: "-")).map { $0 }
            .flatMap { $0.components(separatedBy: " to ") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let days = parts.compactMap { ahead($0, now: now)?.day }
        if let first = days.first { o["from"] = day(first) }
        if days.count > 1, let last = days.last { o["to"] = day(last) }
        if !when.isEmpty { o["said"] = when }
        return sortedJSON(o) + "\n"
    }

    /// One thing on one day. `trip` is the trip's name as they said it; Glyph Travel matches it to a
    /// trip when it opens, and an unmatched one sits on the next trip.
    public static func plan(id: String, name: String, trip: String, day said: String, reference: String,
                            host: String, device: String, now: Date = .now) -> String {
        var o: [String: Any] = ["event": "plan", "host": host, "device": device, "id": id, "name": name,
                                "ts": localStamp(now), "via": "voice"]
        if !trip.isEmpty { o["said"] = trip }
        if !reference.isEmpty { o["ref"] = reference }
        if let (d, hour) = ahead(said, now: now) {
            if let hour {
                o["at"] = localStamp(Calendar.current.date(byAdding: .minute, value: Int((hour * 60).rounded()), to: d) ?? d)
            } else {
                o["from"] = day(d)
            }
        }
        return sortedJSON(o) + "\n"
    }

    public static func note(id: String, text: String, trip: String, host: String, device: String, now: Date = .now) -> String {
        var o: [String: Any] = ["event": "note", "host": host, "device": device, "id": id,
                                "note": text, "ts": localStamp(now), "via": "voice"]
        if !trip.isEmpty { o["said"] = trip }
        return sortedJSON(o) + "\n"
    }

    /// Takes a line back. The line stays in the file, as Glyph Travel does it.
    public static func delete(id: String, host: String, device: String, now: Date = .now) -> String {
        sortedJSON(["event": "delete", "host": host, "device": device, "id": id, "ts": localStamp(now)]) + "\n"
    }
}
