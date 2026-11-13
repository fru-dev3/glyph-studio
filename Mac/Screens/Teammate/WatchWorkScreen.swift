import SwiftUI

/// Watching a teammate work: the job it is running, each step done, now or next, beside its
/// computer; Stop ends the job. You can tell it something while it works. When nothing runs,
/// a calm empty state.
struct WatchWorkScreen: View {
    @Environment(AppModel.self) private var model
    let domain: String
    @State private var job: Watch.Job?
    @State private var loaded = false
    @State private var stopped: Set<String> = []
    @State private var stoppedNote: String?
    @State private var problem: String?
    @State private var message = ""
    @State private var told: [(String, String)] = []

    var body: some View {
        VStack(spacing: 0) {
            TeammateHeader(domain: domain, title: name, subtitle: job.map { "Working · \(Watch.position($0))" } ?? "Not working on anything right now") {
                if job != nil { HeaderChip(title: "Stop", action: stop).padding(.trailing, 4) }
            }
            // The thread and its computer share one width, so the thread's column is worked out
            // here and not inherited. RootView sizes the column from the window minus the rail,
            // which knows nothing about the panel beside the thread on this one screen; the thread
            // then asked for more than was left, the HStack grew past the window to give it, the
            // VStack grew with the HStack, and the header's own controls were clipped off the right
            // edge along with the panel's caption (drive.sh teammate-watch, 2026-11-07).
            // The GeometryReader is what holds the width: it offers its child the window's space
            // instead of asking the window for the child's, so nothing in here can push the header
            // off screen again.
            GeometryReader { g in
                let panel = job == nil ? 0 : min(Self.panel, g.size.width * 0.42)
                HStack(spacing: 0) {
                    ScrollView { work.padding(22).frame(maxWidth: .infinity, alignment: .leading) }
                        .environment(\.column, min(820, g.size.width - panel - 56))
                    if let job { computer(job, width: panel) }
                }
            }
            .frame(maxHeight: .infinity)
            TeammateComposer(placeholder: "Message \(name)", text: $message, send: send)
        }
        .task(id: domain) {
            job = nil; loaded = false; stopped = []; stoppedNote = nil; problem = nil; told = []
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(job == nil ? 6 : 2))
            }
        }
    }

    private var name: String { model.teammate(domain)?.name ?? IntentStore().contract(domain).title }

    // MARK: the work

    @ViewBuilder private var work: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job {
                TeammateBubble(from: name) {
                    Text("Working on: \(job.ask.hasSuffix(".") ? String(job.ask.dropLast()) : job.ask). \(Watch.position(job).capitalizedFirst).")
                        .font(.ui(15)).lineSpacing(6).padding(.vertical, 3)
                }
                .columnMax(0.80, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Watch.steps(job).enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 10) {
                            mark(s.mark)
                            Text(s.label).font(.ui(14)).foregroundStyle(s.mark == .next ? Color(hex: 0x9A9F9B) : Ink.text)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine).accessibilityValue(s.mark == .done ? "done" : s.mark == .now ? "now" : "next")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .column(0.8, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.bubble))
            } else if loaded {
                empty
            }
            ForEach(Array(told.enumerated()), id: \.offset) { _, t in
                Text(t.0).font(.ui(15)).foregroundStyle(Ink.onInk).padding(.horizontal, 16).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.text))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(t.1).font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.leading, 6)
            }
            if let problem { Text(problem).font(.ui(13)).foregroundStyle(Ink.warn).probe("watch-problem") }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Avatar(look: model.teammate(domain)?.look ?? Teammate.look(for: domain), size: 56).opacity(0.9)
            Text(stoppedNote ?? "\(name) isn't working on anything right now.").font(.ui(16, .semibold))
            Text("When it runs a routine or a job, you can watch each step here, beside its computer.")
                .font(.ui(13.5)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            PillButton(title: "See its routines", small: true) { model.go(.role(domain)) }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.top, 140)
        .probe("watch-empty")
    }

    @ViewBuilder private func mark(_ m: Watch.Mark) -> some View {
        switch m {
        case .done: Circle().fill(Ink.green).frame(width: 16, height: 16)
        case .now: Circle().strokeBorder(Ink.green, lineWidth: 2).frame(width: 16, height: 16)
        case .next: Circle().strokeBorder(Color(hex: 0xD6D9D5), lineWidth: 2).frame(width: 16, height: 16)
        }
    }

    // MARK: its computer

    /// The widest the panel goes. Below about 1100 points of window it takes 42% instead, because
    /// a fixed 462 left the thread too narrow to hold its own bubbles.
    static let panel: CGFloat = 462

    private func computer(_ job: Watch.Job, width: CGFloat) -> some View {
        let screen = Watch.screen(job) { Watch.org($0) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("ITS COMPUTER · LIVE").font(.ui(12, .semibold)).foregroundStyle(Ink.tertiary).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 9, height: 9) }
                    Text("\(screen.site) · \(screen.state)").font(.ui(11.5)).foregroundStyle(Color(hex: 0x6B706C)).padding(.leading, 4).lineLimit(1)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .background(Color(hex: 0xECEEEB))
                VStack(alignment: .leading, spacing: 8) {
                    Text(screen.heading).font(.ui(15, .semibold)).padding(.bottom, 2)
                    // The page is being read: its lines load as the step goes.
                    ForEach(0..<7, id: \.self) { i in
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xECEEEB))
                                .frame(width: (g.size.width) * [0.8, 0.64, 0.72, 0.5][i % 4], height: 7)
                        }
                        .frame(height: 7).padding(.horizontal, 16)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).frame(height: 300)
                .background(Ink.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.border))
            Text(caption).font(.ui(12)).foregroundStyle(Color(hex: 0x7A7F7B)).padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0xFAFBF9))
        .overlay(alignment: .leading) { Rectangle().fill(Ink.line).frame(width: 1) }
    }

    /// Its boundaries, from its contract: read only unless it may act, and what it asks first.
    private var caption: String {
        let b = IntentStore().contract(domain).boundaries
        let agent = AgentFile(Vault.read(Vault.domain(domain).appending(path: "agent.md")) ?? "")
        let asks = Array(agent.list("asks").prefix(2)), never = agent.list("never")
        let first = b.tier == "act-ask" ? "It may act within its role." : "Read only."
        if let n = never.first { return asks.isEmpty ? "\(first) It never \(n)." : "\(first) It asks before \(asks[0]) and never \(n)." }
        guard !asks.isEmpty else { return first }
        let list = asks.count > 1 ? asks.dropLast().joined(separator: ", ") + " or " + asks.last! : asks[0]
        return "\(first) It asks before \(list)."
    }

    // MARK: actions

    private func load() async {
        do {
            let jobs = try await Engine.json(["job", "list"], as: [Watch.Job].self)
            if let j = Watch.running(jobs, domain: domain, except: stopped) {
                let v = try await Engine.json(["job", "show", j.id], as: Watch.View.self)
                job = v.job.status == "running" && !stopped.contains(v.job.id) ? v.job : nil
            } else { job = nil }
            problem = nil
        } catch { problem = error.localizedDescription }
        loaded = true
    }

    private func stop() {
        guard let j = job else { return }
        Task {
            do {
                let after = try await Engine.json(["job", "stop", j.id], as: Watch.Job.self)
                stopped.insert(j.id)
                job = nil
                stoppedNote = "Stopped. Nothing after \(Watch.position(after)) ran."
                problem = nil
            } catch { problem = "Couldn't stop it: \(error.localizedDescription)" }
        }
    }

    private func send() {
        guard let text = message.nonEmpty else { return }
        message = ""
        Task {
            struct Told: Decodable { var reply: String? }
            do {
                let r = try await Engine.json(["tell", text, "--domain", domain, "--surface", "desktop"], as: Told.self)
                told.append((text, r.reply ?? "Filed."))
            } catch { problem = "Couldn't tell \(name): \(error.localizedDescription)" }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
