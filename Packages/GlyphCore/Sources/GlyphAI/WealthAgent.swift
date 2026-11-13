import Foundation
import FoundationModels
import GlyphVault

/// Glyph Wealth's agent: what was spent or came in, a balance somebody read off a screen, a new account, and
/// the assumptions the scenarios run on. Written as Glyph Wealth's own `log` lines in this device's month file
/// (`data/apps/wealth/entries/<YYYY-MM>.<host>.jsonl`), so the app lists what the agent did and Fru checks it
/// there, with Undo.
///
/// This is real money, so the agent writes only what it was told. It never works out a balance from a spend,
/// never guesses a figure nobody said, and never puts a number on an account it cannot name: a tool that has no
/// amount says so instead of filling one in. The paperwork is not here on purpose: a document is filed by the
/// family's one filer (GlyphVault Filing, GlyphAI Filer), and Glyph Wealth reads where it landed.
extension GlyphAgent {
    public static let wealth = GlyphAgent(
        id: "wealth", name: "Wealth", color: "1F6F43",
        instructions: """
        You are Glyph Wealth's agent. Money that left or arrived: log_money, one call each, with the amount in \
        dollars exactly as said. A balance somebody read off an account ("my checking is at 5,200", "the card \
        shows 1,840 owed"): set_balance. An account nobody has written down yet: add_account. An assumption for \
        the projections (growth, inflation, withdrawal rate, what a month costs, what goes in each month, the \
        number they are aiming at): set_assumption. Never invent an amount: if no number was said, do not call a \
        tool that needs one. Never turn a question into a log; a question is answered, not saved.
        """,
        tools: { hub, ledger in [WealthLogMoney(hub: hub, ledger: ledger), WealthSetBalance(hub: hub, ledger: ledger),
                                 WealthAddAccount(hub: hub, ledger: ledger), WealthSetAssumption(hub: hub, ledger: ledger)] },
        fallback: { job, hub in
            // Without the model: the words are kept as a note, never as a number. A wrong amount in a money
            // file is worse than no line at all.
            await hub.logWealth(kind: "note", name: job.name.isEmpty ? "Note" : job.name, cents: nil,
                                said: job.instruction, at: hub.now())
        })
}

public struct WealthLogMoney: Tool {
    public let name = "log_money"
    public let description = "Log money that left or arrived in Glyph Wealth: a spend, a bill paid, a paycheck, a refund."
    @Generable public struct Arguments {
        @Guide(description: "Who it went to or came from, 1 to 4 words as said, like Hardware store, Paycheck.") public var payee: String
        @Guide(description: "Which way the money went", .anyOf(["spend", "income"])) public var direction: String
        @Guide(description: "The amount in dollars, as said, never worked out or rounded. 42.5 for forty two fifty.") public var dollars: Double
        @Guide(description: "What kind of spending, or empty when not clear", .anyOf(["", "Housing", "Utilities", "Groceries", "Health", "Insurance", "Transport", "Debt", "Family", "Eating out", "Shopping", "Travel", "Learning", "Giving", "Taxes", "Fees", "Other"])) public var category: String
        @Guide(description: "The account it moved through, by name as said, or empty.") public var account: String
        @Guide(description: "When, if said: days before today (0 for today).", .range(0...400)) public var daysAgo: Int
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        guard a.dollars > 0 else {
            let d = Done(agent: "wealth", line: "No amount heard, nothing logged: \(a.payee)", title: a.payee, ok: false)
            await ledger.add(d); return d.line
        }
        let kind = a.direction == "income" ? "income" : "spend"
        let d = await hub.logWealth(kind: kind, name: a.payee.isEmpty ? (kind == "income" ? "Income" : "Spending") : a.payee,
                                    cents: WealthLine.signed(Int((a.dollars * 100).rounded()), kind: kind),
                                    said: a.payee, account: a.account, category: a.category,
                                    at: hub.now().addingTimeInterval(-86400 * Double(a.daysAgo)))
        await ledger.add(d); return d.line
    }
}

public struct WealthSetBalance: Tool {
    public let name = "set_balance"
    public let description = "Write down the balance just read off an account in Glyph Wealth, so net worth is current."
    @Generable public struct Arguments {
        @Guide(description: "The account by name as said, like checking, my 401k, the Visa.") public var account: String
        @Guide(description: "The balance in dollars, as said. For a card or a loan, what is owed.") public var dollars: Double
        @Guide(description: "True when this is money owed (a card, a loan).") public var owed: Bool
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        guard !a.account.trimmingCharacters(in: .whitespaces).isEmpty else {
            let d = Done(agent: "wealth", line: "Which account? Nothing written down", title: "Which account?", ok: false)
            await ledger.add(d); return d.line
        }
        let cents = Int((abs(a.dollars) * 100).rounded())
        let d = await hub.logWealth(kind: "balance", name: "", cents: a.owed ? -cents : cents,
                                     said: "\(a.account) \(a.dollars)", account: a.account, at: hub.now())
        await ledger.add(d); return d.line
    }
}

public struct WealthAddAccount: Tool {
    public let name = "add_account"
    public let description = "Add an account to Glyph Wealth that is not written down yet, with where it is and what kind it is."
    @Generable public struct Arguments {
        @Guide(description: "What to call it, as said, like Everyday checking.") public var name: String
        @Guide(description: "Where it is held, as said, or empty.") public var institution: String
        @Guide(description: "What kind of account", .anyOf(["cash", "invest", "retirement", "property", "card", "loan", "other"])) public var group: String
        @Guide(description: "Its balance in dollars when one was said, else 0.") public var dollars: Double
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        guard !a.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            let d = Done(agent: "wealth", line: "No account name heard", title: "Which account?", ok: false)
            await ledger.add(d); return d.line
        }
        let d = await hub.addWealthAccount(name: a.name, institution: a.institution, group: a.group,
                                            cents: a.dollars > 0 ? Int((a.dollars * 100).rounded()) : nil)
        await ledger.add(d); return d.line
    }
}

public struct WealthSetAssumption: Tool {
    public let name = "set_assumption"
    public let description = "Set one assumption the Glyph Wealth projections run on, so a date on screen can be traced to it."
    @Generable public struct Arguments {
        @Guide(description: "Which one", .anyOf(["growth", "inflation", "withdrawal", "burn", "saving", "target"])) public var rule: String
        @Guide(description: "For growth, inflation or withdrawal: the rate as a percent, like 7 for seven percent. Else 0.") public var percent: Double
        @Guide(description: "For burn, saving or target: the amount in dollars. Else 0.") public var dollars: Double
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let rate = ["growth", "inflation", "withdrawal"].contains(a.rule)
        guard rate ? a.percent > 0 : a.dollars > 0 else {
            let d = Done(agent: "wealth", line: "No number heard for \(a.rule), left as it was", title: a.rule, ok: false)
            await ledger.add(d); return d.line
        }
        let d = await hub.setWealthPlan(rule: a.rule, value: rate ? a.percent / 100 : nil,
                                         cents: rate ? nil : Int((a.dollars * 100).rounded()))
        await ledger.add(d); return d.line
    }
}

extension Hub {
    static let wealthLink = URL(string: "glyph-wealth://today")

    /// One Glyph Wealth entry in this device's month file, with Undo. `cents` nil keeps a line with no amount
    /// (a note), which is what an agent writes when nobody said a number.
    public func logWealth(kind: String, name: String, cents: Int?, said: String, account: String? = nil,
                          category: String? = nil, at: Date) async -> Done {
        let id = UUID().uuidString.lowercased()
        let shown = name.isEmpty ? said : name.prefix(1).uppercased() + name.dropFirst()
        let line = WealthLine.log(id: id, kind: kind, name: name.isEmpty ? "" : String(shown), cents: cents, at: at,
                                  host: host, device: device, account: account, category: category, said: said)
        let what = cents.map { "\(String(shown)) \(Self.dollars($0))" } ?? String(shown)
        guard let code = await put("wealth/\(WealthLine.file(now(), host: host))", body: Data(line.utf8), type: "application/x-ndjson") else {
            return kept("wealth", what)
        }
        guard code == 204 else { return Done(agent: "wealth", line: "Wealth didn't take it (\(code)): \(what)", title: what, ok: false) }
        return Done(agent: "wealth", line: "\(Self.verb(kind)) in Wealth: \(what)", title: what, ok: true,
                    undo: .wealthDelete(id: id), link: Self.wealthLink)
    }

    /// A new account, and its first balance when one was said, so one sentence makes both.
    public func addWealthAccount(name: String, institution: String, group: String, cents: Int?) async -> Done {
        let id = UUID().uuidString.lowercased()
        let at = now()
        var body = WealthLine.log(id: id, kind: "account", name: name, cents: nil, at: at, host: host, device: device,
                                  institution: institution, group: group, said: name)
        if let cents {
            body += WealthLine.log(id: UUID().uuidString.lowercased(), kind: "balance", name: "", cents: cents, at: at,
                                   host: host, device: device, account: id, said: name)
        }
        let what = name + (cents.map { ", \(Self.dollars($0))" } ?? "")
        guard let code = await put("wealth/\(WealthLine.file(at, host: host))", body: Data(body.utf8), type: "application/x-ndjson") else {
            return kept("wealth", what)
        }
        guard code == 204 else { return Done(agent: "wealth", line: "Wealth didn't take it (\(code)): \(what)", title: what, ok: false) }
        return Done(agent: "wealth", line: "Added to Wealth: \(what)", title: what, ok: true,
                    undo: .wealthDelete(id: id), link: URL(string: "glyph-wealth://accounts"))
    }

    /// One assumption, as a `plan` line (the last one wins, so the assumptions keep a history).
    public func setWealthPlan(rule: String, value: Double?, cents: Int?) async -> Done {
        var o: [String: Any] = ["event": "plan", "host": host, "device": device, "id": UUID().uuidString.lowercased(),
                                "rule": rule, "ts": localStamp(now())]
        if let value { o["value"] = value }
        if let cents { o["amount"] = cents }
        let line = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
        let what = value.map { "\(rule) \(String(format: "%.1f", $0 * 100))%" } ?? "\(rule) \(cents.map(Self.dollars) ?? "")"
        guard let code = await put("wealth/\(WealthLine.file(now(), host: host))", body: Data(line.utf8), type: "application/x-ndjson") else {
            return kept("wealth", what)
        }
        guard code == 204 else { return Done(agent: "wealth", line: "Wealth didn't take it (\(code)): \(what)", title: what, ok: false) }
        return Done(agent: "wealth", line: "Assumed in Wealth: \(what)", title: what, ok: true, link: URL(string: "glyph-wealth://scenarios"))
    }

    static func verb(_ kind: String) -> String {
        switch kind {
        case "spend": "Logged"
        case "income": "Logged"
        case "balance": "Balance written down"
        default: "Kept"
        }
    }

    /// Cents as people read them, for a card's one line. Never used for arithmetic.
    static func dollars(_ cents: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = abs(cents) < 1_000_000 ? 2 : 0
        f.minimumFractionDigits = abs(cents) < 1_000_000 ? 2 : 0
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "$\(Double(cents) / 100)"
    }
}
