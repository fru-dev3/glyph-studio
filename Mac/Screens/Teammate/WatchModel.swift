import Foundation

/// Watching a teammate work: its running job from `job list --json` / `job show <id> --json`
/// (src/jobs.ts Job and jobView), as steps done, now and next, and what its computer is on.
enum Watch {
    struct Job: Decodable, Sendable, Equatable {
        var id: String
        var ask: String
        var status: String
        var domains: Domains
        var team: [TeamStep]?
        var progress: [Progress]?
        var entities: [String]?
        var actions: [Action]?
        var created: Double?
        var note: String?

        struct Domains: Decodable, Sendable, Equatable { var owner: String }
        struct TeamStep: Decodable, Sendable, Equatable { var step: Int; var specialists: [String]; var brief: String? }
        struct Progress: Decodable, Sendable, Equatable { var step: Int; var specialist: String?; var pass: Int? }
        struct Action: Decodable, Sendable, Equatable { var n: Int?; var text: String; var status: String? }
    }

    struct View: Decodable, Sendable {
        var job: Job
        var steps: [Record]?
        struct Record: Decodable, Sendable { var id: String?; var specialist: String?; var brief: String?; var status: String? }
    }

    /// The newest running job this teammate owns, leaving out any you just stopped.
    static func running(_ jobs: [Job], domain: String, except stopped: Set<String> = []) -> Job? {
        jobs.filter { $0.status == "running" && $0.domains.owner == domain && !stopped.contains($0.id) }
            .max { ($0.created ?? 0) < ($1.created ?? 0) }
    }

    enum Mark: Equatable { case done, now, next }
    struct Step: Equatable { var label: String; var mark: Mark }

    /// The step under way: the furthest one the job has reached (progress), else the first.
    static func current(_ job: Job) -> Int { job.progress?.map(\.step).max() ?? (job.team?.first?.step ?? 1) }

    static func steps(_ job: Job) -> [Step] {
        let now = current(job)
        return (job.team ?? []).sorted { $0.step < $1.step }.map { t in
            let label = t.brief?.nonEmpty ?? t.specialists.map(\.capitalized).joined(separator: " and ")
            return Step(label: label, mark: t.step < now ? .done : t.step == now ? .now : .next)
        }
    }

    /// "step 3 of 5"
    static func position(_ job: Job) -> String {
        let all = job.team ?? []
        let now = all.firstIndex { $0.step == current(job) }.map { $0 + 1 } ?? 1
        return "step \(now) of \(max(all.count, now))"
    }

    struct Screen: Equatable { var site: String; var state: String; var heading: String }

    /// What its computer is on: the service the current step names (an org in the vault with a
    /// website), signed in only when you said yes to a sign-in; else its own vault.
    static func screen(_ job: Job, site: (String) -> (name: String, website: String)?) -> Screen {
        let label = steps(job).first { $0.mark == .now }?.label.lowercased() ?? ""
        let signedIn = job.actions?.contains { $0.text.lowercased().contains("sign") && ["done", "running"].contains($0.status ?? "") } ?? false
        for e in job.entities ?? [] where e.hasPrefix("org/") {
            guard let s = site(String(e.dropFirst(4))), label.contains(s.name.lowercased()) else { continue }
            // The page it last opened there ("Open Accounts"), else the site's name.
            let page = job.actions?.last { $0.text.hasPrefix("Open ") }.map { String($0.text.dropFirst(5)) }
            return Screen(site: s.website, state: signedIn ? "signed in after your yes" : "read only", heading: page ?? s.name)
        }
        return Screen(site: "Your vault", state: "reading your files", heading: "Files")
    }

    /// An org's name and website from its entity.md, if the vault knows it.
    static func org(_ slug: String, root: URL = Vault.root) -> (name: String, website: String)? {
        let fm = Frontmatter.read(root.appending(path: "data/entities/orgs/\(slug)/entity.md"))
        guard let w = fm["website"]?.nonEmpty else { return nil }
        return (fm["name"]?.nonEmpty ?? slug.capitalized, w)
    }
}
