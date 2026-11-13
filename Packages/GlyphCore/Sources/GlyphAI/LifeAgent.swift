import Foundation
import FoundationModels
import GlyphVault

/// Glyph Life's agent: personal administration. Life reads the vault's own administration (filed
/// documents, the app registry's costs, the domains' loops and task boards) and holds only two
/// things nothing else does, so the agent has only those tools: what was decided about a renewal,
/// and a run of a recurring administrative workflow. Both are Life's own lines (GlyphVault
/// `LifeLine`), written through the hub Life already sends to.
///
/// What it deliberately cannot do, because another app owns it:
///   a reminder or an alarm about a renewal   Glyph Time (`request_reminder`)
///   a company, a place or a thing            Glyph CRM
///   a goal or a next action                  Glyph Omega
///   placing a document in the vault          the filing pipeline (`glyphcore-report file`)
extension GlyphAgent {
    public static let life = GlyphAgent(
        id: "life", name: "Life", color: "1F6F3C",
        instructions: """
        You are Glyph Life's agent: the operational side of everyday life. A decision about a \
        subscription or a renewal, keep it or cancel it: decide_renewal with the service as they named it. \
        A recurring administrative job they want to work through (a renewal check, a coverage review, an \
        enrolment): start_workflow. One step of a run finished: finish_step. Nothing else is yours: a \
        reminder or an alarm belongs to Glyph Time, a company or a thing to Glyph CRM, a goal to Glyph \
        Omega, and filing a document to the filer. Never invent an amount; leave it at 0 when they did not say one.
        """,
        tools: { hub, ledger in [LifeDecideRenewal(hub: hub, ledger: ledger), LifeStartWorkflow(hub: hub, ledger: ledger),
                                 LifeFinishStep(hub: hub, ledger: ledger)] },
        fallback: { job, hub in
            await hub.decideRenewal(app: job.name.isEmpty ? job.instruction : job.name,
                                    keep: !job.instruction.lowercased().contains("cancel"), amount: 0)
        })
}

public struct LifeDecideRenewal: Tool {
    public let name = "decide_renewal"
    public let description = "Decide about a subscription or a renewal in Glyph Life: keep it, or cancel it."
    @Generable public struct Arguments {
        @Guide(description: "The service, as they named it, like the gym, Northwind.") public var service: String
        @Guide(description: "true to keep it, false to cancel it.") public var keep: Bool
        @Guide(description: "What it costs each period, if they said one; 0 when they did not.", .range(0...100_000)) public var amount: Double
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.decideRenewal(app: a.service, keep: a.keep, amount: a.amount)
        await ledger.add(d); return d.line
    }
}

public struct LifeStartWorkflow: Tool {
    public let name = "start_workflow"
    public let description = "Start a run of a recurring administrative workflow in Glyph Life."
    @Generable public struct Arguments {
        @Guide(description: "The workflow as they said it, like the renewal check, open enrolment.") public var workflow: String
        @Guide(description: "The life domain it belongs to, like insurance, benefits, records; empty when unclear.") public var domain: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.startWorkflow(a.workflow, domain: a.domain)
        await ledger.add(d); return d.line
    }
}

public struct LifeFinishStep: Tool {
    public let name = "finish_step"
    public let description = "Mark a step of the workflow they are running done, or the whole run finished."
    @Generable public struct Arguments {
        @Guide(description: "The workflow as they said it.") public var workflow: String
        @Guide(description: "Which step, counting from 1; 0 when they mean the whole run is finished.", .range(0...40)) public var step: Int
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.finishLifeStep(a.workflow, step: a.step)
        await ledger.add(d); return d.line
    }
}

extension Hub {

    /// What Glyph Life reads, as the hub serves it: {vault path: text}. nil when the hub is away.
    func lifeContext() async -> [String: String]? {
        guard let got = await send("GET", "life/context"), got.0 == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: got.1)) as? [String: String]
    }

    func lifePut(_ line: String) async -> Int? {
        await put("life/\(LifeLine.file(now(), host: host))", body: Data(line.utf8), type: "application/x-ndjson")
    }

    /// The app registry's id for what they named, and the cost on it, from what the hub serves. A
    /// service the registry does not know is written under the slug of what they said, so the
    /// decision is never lost; Life shows it beside the registry's own.
    func lifeApp(_ said: String) async -> (id: String, name: String, amount: Double) {
        let slug = said.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        guard let files = await lifeContext() else { return (slug, said, 0) }
        var best: (id: String, name: String, amount: Double)?
        for (path, text) in files where path.hasPrefix("data/apps/") && path.hasSuffix("manifest.json") {
            guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let id = m["id"] as? String else { continue }
            let name = (m["name"] as? String) ?? (m["title"] as? String) ?? id
            let words = said.lowercased()
            guard id == slug || words.contains(id.replacingOccurrences(of: "-", with: " "))
                    || words.contains(name.lowercased()) || name.lowercased().contains(words) else { continue }
            let amount = ((m["cost"] as? [String: Any])?["amount"] as? Double) ?? 0
            if best == nil || amount > best!.amount { best = (id, name, amount) }
        }
        return best ?? (slug, said, 0)
    }

    public func decideRenewal(app said: String, keep: Bool, amount: Double) async -> Done {
        let found = await lifeApp(said)
        let id = "d-" + UUID().uuidString.prefix(12)
        let line = LifeLine.decide(id: id, app: found.id, choice: keep ? "keep" : "cancel",
                                   amount: amount > 0 ? amount : found.amount, host: host, device: device, now: now())
        let code = await lifePut(line)
        let what = (keep ? "Keeping " : "Cancelling ") + found.name
        if code == nil { return kept("life", what) }
        guard code == 204 else { return Done(agent: "life", line: "Life didn't take it (\(code!)): \(what)", title: what, ok: false) }
        return Done(agent: "life", line: what + ".", title: what, ok: true,
                    undo: .lifeDelete(id: id), link: URL(string: "glyph-life://money"))
    }

    /// The loop their words name, from what the hub serves, with its step count. Nothing is started
    /// for a workflow the vault does not have: Life never invents a loop.
    func lifeLoop(_ said: String, domain: String) async -> (loop: String, domain: String, name: String, steps: Int)? {
        guard let files = await lifeContext() else { return nil }
        let words = said.lowercased()
        var best: (loop: String, domain: String, name: String, steps: Int)?
        for (path, text) in files where path.hasSuffix("_loops.json") {
            let parts = path.split(separator: "/")
            guard parts.count > 2, let file = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let loops = file["loops"] as? [[String: Any]] else { continue }
            let dom = String(parts[2])
            if !domain.isEmpty, dom != domain.lowercased() { continue }
            for l in loops {
                guard let id = l["id"] as? String else { continue }
                let name = (l["name"] as? String) ?? id
                let plain = name.lowercased()
                guard words.contains(plain) || plain.contains(words) || words.contains(id.replacingOccurrences(of: "-", with: " "))
                        || plain.split(separator: " ").allSatisfy({ words.contains($0) }) else { continue }
                let steps = ((l["actions"] as? [String]) ?? []).count
                best = (id, dom, name, steps > 0 ? steps : 4)
            }
        }
        return best
    }

    public func startWorkflow(_ said: String, domain: String) async -> Done {
        guard let found = await lifeLoop(said, domain: domain) else {
            return Done(agent: "life", line: "No workflow like that in the vault: \(said)", title: said, ok: false)
        }
        let id = "r-" + UUID().uuidString.prefix(12)
        let code = await lifePut(LifeLine.start(id: id, loop: found.loop, domain: found.domain, steps: found.steps,
                                                host: host, device: device, now: now()))
        let what = "Started \(found.name), \(found.steps) steps"
        if code == nil { return kept("life", what) }
        guard code == 204 else { return Done(agent: "life", line: "Life didn't take it (\(code!)): \(what)", title: what, ok: false) }
        return Done(agent: "life", line: what + ".", title: found.name, ok: true, undo: .lifeDelete(id: id), link: URL(string: "glyph-life://workflows"))
    }

    /// The run in flight for that workflow, from Life's own lines, and one step of it done.
    public func finishLifeStep(_ said: String, step: Int) async -> Done {
        guard let found = await lifeLoop(said, domain: ""), let files = await lifeContext() else {
            return Done(agent: "life", line: "No run like that: \(said)", title: said, ok: false)
        }
        var run: String?
        var finished = Set<String>()
        for (path, text) in files.sorted(by: { $0.key < $1.key }) where path.hasPrefix("data/apps/life/entries/") {
            for l in text.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                      o["event"] as? String == "run", let id = o["id"] as? String else { continue }
                if o["state"] as? String == "start", o["loop"] as? String == found.loop { run = id }
                if o["state"] as? String == "done" { finished.insert(id) }
            }
        }
        guard let run, !finished.contains(run) else {
            return Done(agent: "life", line: "No run of \(found.name) is going. Start one first.", title: found.name, ok: false)
        }
        let code = await lifePut(LifeLine.step(id: run, n: step > 0 ? step : nil, host: host, device: device, now: now()))
        let what = step > 0 ? "Step \(step) of \(found.name) done" : "Finished \(found.name)"
        if code == nil { return kept("life", what) }
        guard code == 204 else { return Done(agent: "life", line: "Life didn't take it (\(code!)): \(what)", title: what, ok: false) }
        return Done(agent: "life", line: what + ".", title: found.name, ok: true, link: URL(string: "glyph-life://workflows"))
    }
}
