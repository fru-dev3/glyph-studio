import SwiftUI

/// What the one who runs the team handed to the rest of it (the canvas, boards 21 and 22). You say
/// one thing; it is split into a brief per agent, and the thread shows each brief where you said it
/// rather than making you go and look for it.
///
/// Every field comes from the engine's own job: `team` is the briefs it wrote, `progress` is how far
/// each got. Nothing here is composed by Studio except the sentence that counts who is still going.
struct HandOff: Hashable {
    var jobID: String
    var cards: [Handed]

    struct Handed: Hashable, Identifiable {
        var id: String { "\(domain)-\(step)" }
        var domain: String
        var name: String
        var brief: String
        var step: Int
        var done: Bool
    }

    /// "Estate and Wealth are still working", or nothing once none of them is. An agent that has
    /// stopped for your answer is not working, so it is left out: its own ask is right above, and
    /// saying it is still working would be the thread telling you two different things at once.
    func working(waiting: Set<String> = []) -> String? {
        let names = cards.filter { !$0.done && !waiting.contains($0.domain) }.map(\.name)
        guard !names.isEmpty else { return nil }
        return "\(Self.list(names)) \(names.count == 1 ? "is" : "are") still working"
    }

    /// "Estate", "Estate and Wealth", "Estate, Wealth and Tax".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// The briefs one job handed out, in step order. A step with no brief of its own is left out: a
    /// card with nothing written on it tells you less than no card.
    ///
    /// A step only becomes a card when its specialist names a teammate you actually have. The engine
    /// also writes `specialists` as internal roles (researcher, operator, writer, steward) on a job
    /// an agent runs for itself, and those are not people you can open a thread with. Taking the
    /// first specialist as a domain would have drawn cards addressed to "Researcher" with a stranger's
    /// tile on them. So this is deliberately quiet: where the engine did not hand work to a named
    /// teammate, the thread says nothing rather than something invented.
    static func build(_ job: Watch.Job, team: [Teammate]) -> HandOff? {
        let now = Watch.current(job)
        let cards = (job.team ?? []).sorted { $0.step < $1.step }.compactMap { t -> Handed? in
            guard let brief = t.brief?.nonEmpty else { return nil }
            guard let mate = t.specialists.lazy.compactMap({ s in team.first { $0.id == s } }).first else { return nil }
            return Handed(domain: mate.id, name: mate.name, brief: brief, step: t.step, done: t.step < now)
        }
        return cards.isEmpty ? nil : HandOff(jobID: job.id, cards: cards)
    }

    /// The newest job the one who runs the team owns, which is the one the last thing you said
    /// became. A job owned by a domain agent is that agent's own work and belongs on its screen.
    static func mine(_ jobs: [Watch.Job], owner: String) -> Watch.Job? {
        jobs.filter { $0.domains.owner == owner && ($0.team?.isEmpty == false) }
            .max { ($0.created ?? 0) < ($1.created ?? 0) }
    }
}

/// One brief, as the canvas draws it: the agent's tile, TO <NAME> and the time in green, the brief
/// in full, and a mark on the right. The mark is a green dot while it works and two green ticks once
/// it is back. Never a grey tick: that one means you owe it something (the owner, 2026-11-07).
struct HandOffCard: View {
    let card: HandOff.Handed
    let at: String
    /// That agent has stopped and is waiting on your answer, so the mark owes you, not it.
    var waiting: Bool = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                Avatar(look: Teammate.look(for: card.domain), size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("To \(card.name)".uppercased()).font(.ui(11.5, .semibold)).tracking(0.6)
                            .foregroundStyle(Ink.greenText)
                        Text(at).font(.ui(11.5)).monospacedDigit().foregroundStyle(Ink.greenText.opacity(0.75))
                    }
                    Text(card.brief).font(.ui(15.5)).lineSpacing(5).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                mark.padding(.top, 5)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.bubble))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.border))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .probe("handed:\(card.domain)", action: open)
    }

    /// Three states, never two meanings on one mark (the owner, 2026-11-07). One grey tick: it stopped and
    /// you owe it an answer. Two green ticks: it is back and in the vault. A green dot: it is
    /// working and nothing is being asked of you. Owing it something comes first: a step can be
    /// finished and the agent still be holding a question, and the mark follows the question.
    @ViewBuilder private var mark: some View {
        if waiting {
            Ticks(count: 1).stroke(Ink.mark, style: Self.stroke).frame(width: 10, height: 11)
                .accessibilityLabel("Waiting on you")
        } else if card.done {
            Ticks().stroke(Ink.greenText, style: Self.stroke).frame(width: 16, height: 11)
                .accessibilityLabel("In the vault")
        } else {
            Circle().fill(Ink.green).frame(width: 7, height: 7)
                .accessibilityLabel("Working now")
        }
    }

    private static let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
}

/// The family's marks, drawn rather than taken from SF Symbols so they match the canvas stroke for
/// stroke and so one tick can never be mistaken for two. Two ticks mean it reached the vault; one
/// means it is waiting on you. The box is read as 16 x 11 for two and 10 x 11 for one, so the tick
/// itself is the same size either way.
struct Ticks: Shape {
    var count: Int = 2

    func path(in r: CGRect) -> Path {
        let k = r.width / (count > 1 ? 16 : 10), h = r.height / 11
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * h) }
        var path = Path()
        path.move(to: p(1, 6.2)); path.addLine(to: p(4, 9.4)); path.addLine(to: p(9.4, 2.2))
        guard count > 1 else { return path }
        path.move(to: p(6.6, 6.2)); path.addLine(to: p(9.6, 9.4)); path.addLine(to: p(15, 2.2))
        return path
    }
}
