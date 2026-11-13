import Foundation
import FoundationModels
import GlyphVault

/// Glyph CRM's agent. A new person, place, org or thing (`add_record`) and a note, alias or attribute on one
/// already there (`update_record`) are written straight to its entity page (GlyphVault `CRMPage`, the bytes
/// Glyph CRM writes) through the hub's /crm routes, with Undo. What needs Fru's yes stays a suggestion in CRM's
/// review (`data/apps/crm/proposals`): a merge, a name that fits several pages ("Which Ken?"), a name not in CRM
/// when only a note was given.
extension GlyphAgent {
    public static let crm = GlyphAgent(
        id: "crm", name: "CRM", color: "2F5FB3",
        instructions: """
        You are Glyph CRM's agent. Someone new (a person, place, org or thing) with what was said: add_record. A note, \
        an alias or an attribute for someone already known: update_record. Two records that are the same: merge_records. \
        When unsure whether it is someone new, call update_record; it asks when the name fits several.
        """,
        tools: { hub, ledger in [CRMAddRecord(hub: hub, ledger: ledger), CRMUpdateRecord(hub: hub, ledger: ledger),
                                 CRMMergeRecords(hub: hub, ledger: ledger), CRMPropose(hub: hub, ledger: ledger)] },
        fallback: { job, hub in
            // Without the model: a note on the one page that name fits; otherwise a suggestion or a question.
            await hub.updateRecord(job.name.isEmpty ? job.instruction : job.name, kind: "person", note: job.instruction, proposeIfNew: true)
        })
}

public struct CRMAddRecord: Tool {
    public let name = "add_record"
    public let description = "Add a new person, place, org or thing to Glyph CRM, with a note and links."
    @Generable public struct Arguments {
        @Guide(description: "What it is", .anyOf(["person", "place", "org", "thing"])) public var kind: String
        @Guide(description: "Its name, as said, like Ken Lee.") public var name: String
        @Guide(description: "What was said about it.") public var note: String
        @Guide(description: "Who or what it is linked to, by name, like Acme. Empty when none.") public var linkTo: [String]
        @Guide(description: "How, for each linkTo, like works at, lives in. Empty when none.") public var linkAs: [String]
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let links = zip(a.linkAs + Array(repeating: "related to", count: max(0, a.linkTo.count - a.linkAs.count)), a.linkTo).map { ($0, $1) }
        let d = await hub.addRecord(kind: a.kind, name: a.name, note: a.note, links: links); await ledger.add(d); return d.line
    }
}

public struct CRMUpdateRecord: Tool {
    public let name = "update_record"
    public let description = "Add a note, an alias or an attribute to someone or something already in Glyph CRM."
    @Generable public struct Arguments {
        @Guide(description: "The name as said, like Ken.") public var name: String
        @Guide(description: "A note, or empty.") public var note: String
        @Guide(description: "Another name for it, or empty.") public var alias: String
        @Guide(description: "An attribute's name, like Phone or Birthday, or empty.") public var key: String
        @Guide(description: "The attribute's value, or empty.") public var value: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.updateRecord(a.name, note: a.note, alias: a.alias, key: a.key, value: a.value); await ledger.add(d); return d.line
    }
}

public struct CRMMergeRecords: Tool {
    public let name = "merge_records"
    public let description = "Suggest that two Glyph CRM records are the same; it waits in CRM for a yes."
    @Generable public struct Arguments {
        @Guide(description: "The one to keep, by name.") public var keep: String
        @Guide(description: "The one that goes into it, by name.") public var gone: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.mergeRecords(keep: a.keep, gone: a.gone); await ledger.add(d); return d.line
    }
}

public struct CRMPropose: Tool {
    public let name = "propose"
    public let description = "Suggest a person, place, org or thing for Glyph CRM, with a note; it waits there for a yes."
    @Generable public struct Arguments {
        @Guide(description: "What it is", .anyOf(["person", "place", "org", "thing"])) public var kind: String
        @Guide(description: "Its name, as said, like Ken.") public var name: String
        @Guide(description: "What was said about it.") public var note: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.propose(kind: a.kind, name: a.name, note: a.note); await ledger.add(d); return d.line
    }
}

/// One entity page, as the hub lists them (`GET /crm/names`).
public struct CRMName: Decodable, Equatable, Sendable {
    public var id: String, name: String, kind: String, path: String
    public var aliases: [String]
    public init(id: String, name: String, kind: String, path: String, aliases: [String]) {
        self.id = id; self.name = name; self.kind = kind; self.path = path; self.aliases = aliases
    }
}

/// A name that fits several pages, waiting for Fru's pick: one of `choices`, or a new page (`Hub.answer`).
public struct CRMAsk: Equatable, Sendable {
    public var kind: String, name: String, note: String, key: String, value: String
    public var choices: [CRMName]
    public var id: String, file: String  // the suggestion in CRM's review
}

extension Hub {
    static let crmLink = URL(string: "glyph-crm://suggestions")

    public func crmNames() async -> [CRMName]? {
        guard let got = await send("GET", "crm/names"), got.0 == 200 else { return nil }
        return try? JSONDecoder().decode([CRMName].self, from: got.1)
    }

    /// The pages a name fits: the name or an alias exactly; else every page whose name holds each word said
    /// ("Ken" fits Ken Lee and Ken Park).
    public static func crmMatches(_ said: String, kind: String? = nil, in all: [CRMName]) -> [CRMName] {
        let s = CRMPage.oneLine(said)
        let pool = kind.map { k in all.filter { $0.kind == CRMKind(rawValue: CRMProposalLine.kind(k))?.prefix } } ?? all
        let exact = pool.filter { ([$0.name] + $0.aliases).contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
        if !exact.isEmpty { return exact }
        func words(_ t: String) -> Set<String> { Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let want = words(s)
        guard !want.isEmpty else { return [] }
        return pool.filter { p in ([p.name] + p.aliases).contains { want.isSubset(of: words($0)) } }
    }

    /// A new entity page, written as Glyph CRM's Store.create and Batch.fill write one. An exact name already
    /// there gets the note instead.
    public func addRecord(kind: String, name: String, note: String, links: [(String, String)] = [], key: String = "", value: String = "") async -> Done {
        let name = CRMPage.oneLine(name)
        guard !name.isEmpty, let kind = CRMKind(rawValue: CRMProposalLine.kind(kind)) else { return Done(agent: "crm", line: "No name heard", title: "Who?", ok: false) }
        guard let all = await crmNames() else { return unreachable("crm", name) }
        if Self.crmMatches(name, kind: kind.rawValue, in: all).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return await updateRecord(name, kind: kind.rawValue, note: note)
        }
        let root = CRMPage.slug(name).isEmpty ? "\(kind.rawValue)-\(Int(now().timeIntervalSince1970))" : CRMPage.slug(name)
        var slug = root, n = 2
        let taken = Set(all.map(\.id))
        while taken.contains("\(kind.prefix)/\(slug)") { slug = "\(root)-\(n)"; n += 1 }
        var page = CRMPage.new(name: name, kind: kind, now: now())
        page.permanentID = "\(kind.prefix)/\(slug)"
        var left: [String] = []
        for (label, to) in links {
            let hits = Self.crmMatches(to, in: all)
            if to.lowercased() == "me" { page.links += [CRMLink(to: "me", as: label.lowercased())] }
            else if hits.count == 1 { page.links += [CRMLink(to: hits[0].id, as: label.lowercased())] } else { left.append(to) }
        }
        if !key.isEmpty, !value.isEmpty { page.attributes = [(CRMPage.oneLine(key), CRMPage.oneLine(value))] }
        page.appendNote(note, on: OmegaFormat.today(now()))
        let folder = "data/entities/\(kind.dir)/\(slug)", rel = folder + "/entity.md"
        guard let code = await send("PUT", "crm/file", query: ["path": rel], body: json(["text": page.render(), "base": NSNull()]))?.0 else { return unreachable("crm", name) }
        guard code == 204 else { return Done(agent: "crm", line: "CRM didn't take it (\(code)): \(name)", title: name, ok: false) }
        let gone = "data/apps/crm/undone/\(kind.dir)/\(slug)-\(fileStem(now()).filter(\.isNumber))"
        return Done(agent: "crm", line: "Added to CRM: \(name)" + (left.isEmpty ? "" : " (not linked, not one page in CRM: \(left.joined(separator: ", ")))"),
                    title: name, ok: true, undo: .crmUnmake(folder: folder, to: gone), link: URL(string: "glyph-crm://"))
    }

    /// A note, an alias or an attribute on the one page the name fits, written as Glyph CRM's Store.edit writes it.
    /// Several fit: a suggestion that asks which. None: a suggestion for a new one when `proposeIfNew` or when an
    /// alias or attribute was given, else a card that says so.
    public func updateRecord(_ name: String, kind: String? = nil, note: String = "", alias: String = "", key: String = "", value: String = "",
                             proposeIfNew: Bool = true) async -> Done {
        let name = CRMPage.oneLine(name)
        guard let all = await crmNames() else { return unreachable("crm", name) }
        let hits = Self.crmMatches(name, kind: kind, in: all)
        let k = key.trimmingCharacters(in: .whitespaces), v = value.trimmingCharacters(in: .whitespaces)
        guard hits.count == 1, let it = hits.first else {
            let kind = kind ?? "person"
            if hits.count > 1 {
                // A yes must pick one of them or a new one: the line carries the pages, the card offers them.
                let three = Array(hits.prefix(3)), names = three.map(\.name).joined(separator: " or ")
                var d = await propose(kind: kind, name: name, note: note, key: k.isEmpty ? nil : k, value: v.isEmpty ? nil : v,
                                      choices: three.map(\.id), title: "Which \(name)?", line: "Which \(name): \(names)? Waiting for your pick")
                if d.review, case .crmReject(let id, let file)? = d.undo {
                    d.ask = CRMAsk(kind: kind, name: name, note: note, key: k, value: v, choices: three, id: id, file: file)
                }
                return d
            }
            guard proposeIfNew || !k.isEmpty else { return Done(agent: "crm", line: "No \(name) in CRM", title: name, ok: false) }
            return await propose(kind: kind, name: name, note: note, key: k.isEmpty ? nil : k, value: v.isEmpty ? nil : v)
        }
        return await update(it, note: note, alias: alias, key: k, value: v)
    }

    /// Fru's pick for a "Which Ken?": the note (and attribute) on that page, or on a new page with the name as said
    /// (`nil`). The suggestion in CRM's review is marked answered; the card's Undo is the write's own.
    public func answer(_ ask: CRMAsk, with pick: CRMName?) async -> Done {
        let d = if let pick { await update(pick, note: ask.note, key: ask.key, value: ask.value) }
            else { await addRecord(kind: ask.kind, name: ask.name, note: ask.note, key: ask.key, value: ask.value) }
        guard d.ok else { return d }
        if let got = await send("GET", "crm/file", query: ["path": ask.file]), got.0 == 200,
           let text = CRMProposalLine.settling(ask.id, as: "accepted", existing: pick?.id, in: String(decoding: got.1, as: UTF8.self)) {
            _ = await send("PUT", "crm/file", query: ["path": ask.file], body: json(["text": text, "base": String(decoding: got.1, as: UTF8.self)]))
        }
        return d
    }

    /// A note, an alias or an attribute on this page, written as Glyph CRM's Store.edit writes it, with Undo.
    func update(_ it: CRMName, note: String, alias: String = "", key k: String = "", value v: String = "") async -> Done {
        guard let got = await send("GET", "crm/file", query: ["path": it.path]), got.0 == 200 else { return Done(agent: "crm", line: "CRM couldn't read \(it.name)", title: it.name, ok: false) }
        let before = String(decoding: got.1, as: UTF8.self)
        let parts = it.path.split(separator: "/")
        var p = CRMPage(text: before, slug: parts.count > 3 ? String(parts[3]) : it.name, kind: it.kind)
        let a = CRMPage.oneLine(alias)
        if !a.isEmpty, !a.contains(","), a.caseInsensitiveCompare(p.name) != .orderedSame, !p.aliases.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) { p.aliases.append(a) }
        if !k.isEmpty, !v.isEmpty {
            var attrs = p.attributes
            if let i = attrs.firstIndex(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }) { attrs[i].value = CRMPage.oneLine(v) } else { attrs.append((CRMPage.oneLine(k), CRMPage.oneLine(v))) }
            p.attributes = attrs
        }
        p.appendNote(note, on: OmegaFormat.today(now()))
        if p.permanentID == nil { p.permanentID = it.id }
        p.updated = CRMPage.iso(now())
        p.saved = true
        let after = p.render()
        let what = [a.isEmpty ? nil : "also \(a)", k.isEmpty || v.isEmpty ? nil : "\(k) \(v)", note.isEmpty ? nil : "a note"].compactMap { $0 }.joined(separator: ", ")
        guard !what.isEmpty else { return Done(agent: "crm", line: "Nothing to add to \(it.name)", title: it.name, ok: false) }
        guard let code = await send("PUT", "crm/file", query: ["path": it.path], body: json(["text": after, "base": before]))?.0 else { return unreachable("crm", it.name) }
        guard code == 204 else { return Done(agent: "crm", line: "CRM didn't take it (\(code)): \(it.name)", title: it.name, ok: false) }
        return Done(agent: "crm", line: "Added to \(it.name) in CRM: \(what)", title: it.name, ok: true,
                    undo: .restore(app: "crm", path: it.path, before: before, after: after), link: URL(string: "glyph-crm://"))
    }

    /// A merge always waits for a yes: a "same as" suggestion that Glyph CRM's review turns into its own merge.
    public func mergeRecords(keep: String, gone: String) async -> Done {
        guard let all = await crmNames() else { return unreachable("crm", gone) }
        let k = Self.crmMatches(keep, in: all), g = Self.crmMatches(gone, in: all)
        guard k.count == 1, g.count == 1, k[0].id != g[0].id else {
            let which = k.count != 1 ? (keep, k) : (gone, g)
            let names = which.1.prefix(3).map(\.name).joined(separator: " or ")
            return Done(agent: "crm", line: which.1.isEmpty ? "No \(which.0) in CRM to merge" : "Which \(which.0): \(names)?", title: "Which \(which.0)?", ok: false)
        }
        let kind = CRMKind(prefix: g[0].kind)?.rawValue ?? "person", toKind = CRMKind(prefix: k[0].kind)?.rawValue ?? "person"
        return await propose(kind: kind, name: g[0].name, note: "\(g[0].name) is \(k[0].name)", existing: g[0].id, linkAs: "same as", toKind: toKind, toName: k[0].name,
                             title: "\(g[0].name) into \(k[0].name)", line: "Merge \(g[0].name) into \(k[0].name)? Waiting for your yes in CRM")
    }

    /// A suggestion in CRM's review; the card waits for Fru's yes there.
    public func propose(kind: String, name: String, note: String, existing: String? = nil, key: String? = nil, value: String? = nil,
                        linkAs: String? = nil, toKind: String? = nil, toName: String? = nil, choices: [String]? = nil,
                        title: String? = nil, line shown: String? = nil) async -> Done {
        let file = CRMProposalLine.file(now())
        let kind = CRMProposalLine.kind(kind)
        let line = CRMProposalLine.line(kind: kind, name: name, evidence: note, at: now(), existing: existing, key: key, value: value,
                                        linkAs: linkAs, toKind: toKind, toName: toName, choices: choices, note: choices == nil ? nil : note)
        let code = await appendProposal(line, file: file, keep: true)
        if code == nil { return kept("crm", name) }
        guard code == 204 else { return Done(agent: "crm", line: "CRM didn't take it (\(code!)): \(name)", title: name, ok: false) }
        let id = CRMProposalLine.id(kind: kind, name: name, key: key, value: value, linkAs: linkAs, toKind: toKind, toName: toName,
                                    note: choices?.isEmpty == false ? note : nil)
        return Done(agent: "crm", line: shown ?? "Waiting for your yes in CRM: \(name)", title: title ?? name, ok: true, review: true,
                    undo: .crmReject(id: id, file: file), link: Self.crmLink)
    }

    /// Adds the line to the month's file with the text it read as the base (409: changed since, read again).
    /// 204 when it is there (already there counts). nil: the hub is away (kept for `flush()` when `keep`).
    func appendProposal(_ line: String, file: String, keep: Bool) async -> Int? {
        for _ in 0..<3 {
            guard let got = await send("GET", "crm/file", query: ["path": file]) else {
                if keep { Outbox.keep(.init(path: "crm/propose", query: ["path": file], body: Data(line.utf8), type: "")) }
                return nil
            }
            let base: String? = got.0 == 200 ? String(decoding: got.1, as: UTF8.self) : nil
            guard let text = CRMProposalLine.adding(line, to: base) else { return 204 }
            guard let code = await send("PUT", "crm/file", query: ["path": file], body: json(["text": text, "base": base ?? NSNull()]))?.0 else { return nil }
            if code != 409 { return code }
        }
        return 409
    }
}
