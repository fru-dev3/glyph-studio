import AppKit
import SwiftUI

/// A teammate's role: its routines (playbooks you can run now or switch off) and the tools it
/// reads (Added, or Add for a service with no connector, which offers the cheapest ways in).
struct TeammateRoleScreen: View {
    @Environment(AppModel.self) private var model
    let domain: String
    @State private var routines: [Role.Routine] = []
    @State private var tools: [Role.Tool] = []
    @State private var adding: String?
    @State private var problem: String?
    @State private var loaded = false
    private var runs = RoutineRuns.shared

    init(domain: String) { self.domain = domain }

    var body: some View {
        VStack(spacing: 0) {
            TeammateHeader(domain: domain, title: "\(name) · Role", subtitle: worksToward)
            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    column("ROUTINES") { routineList }
                    column("CONNECTED TOOLS") { toolList }
                }
                .padding(.horizontal, 34).padding(.vertical, 26)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .bottom) {
            if let problem {
                Text(problem).font(.ui(13)).foregroundStyle(Ink.warn).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Ink.warnSoft)).padding(.bottom, 20).probe("role-problem")
            }
        }
        .task(id: domain) { await load() }
    }

    private var name: String { model.teammate(domain)?.name ?? IntentStore().contract(domain).title }

    private var worksToward: String {
        let p = IntentStore().contract(domain).purpose.split(separator: "\n").first.map(String.init) ?? ""
        guard let p = p.nonEmpty else { return "No purpose written yet" }
        let s = p.hasSuffix(".") ? String(p.dropLast()) : p
        return "Works toward: " + s.prefix(1).lowercased() + s.dropFirst()
    }

    private func column<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.ui(12, .semibold)).foregroundStyle(Ink.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: routines

    @ViewBuilder private var routineList: some View {
        if loaded && routines.isEmpty {
            Text("No routines yet. Ask \(name) in the chat to make one.").font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.top, 14)
        }
        ForEach(routines) { r in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.name).font(.ui(15, .semibold)).lineLimit(1)
                    statusLine(r)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .running = runs.state[r.id] {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Running").font(.ui(12.5)) }
                        .padding(.horizontal, 11).frame(height: 26).background(Capsule().fill(Ink.chip))
                        .probe("running:\(r.id)")
                } else {
                    PillButton(title: "Run now", small: true, id: "run:\(r.id)") { runs.run(r.id) }
                }
                if r.scheduled {
                    Toggle38(isOn: Binding(get: { routines.first { $0.id == r.id }?.enabled ?? r.enabled }, set: { setEnabled(r, $0) }), label: r.name)
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0F1EF)).frame(height: 1) }
        }
    }

    @ViewBuilder private func statusLine(_ r: Role.Routine) -> some View {
        let (text, color): (String, Color) = switch runs.state[r.id] {
        case .running(let step)?: ("Running" + (step.map { " · \($0)" } ?? ""), Ink.secondary)
        case .done(let note)?: ("Done just now" + (note.nonEmpty.map { " · \($0)" } ?? ""), Ink.greenText)
        case .failed(let note)?: ("Didn't finish · \(note)", Ink.warn)
        case nil: (r.line, Color(hex: 0x7A7F7B))
        }
        Text(text).font(.ui(12.5)).foregroundStyle(color).lineLimit(2)
    }

    // MARK: tools

    @ViewBuilder private var toolList: some View {
        if loaded && tools.isEmpty {
            Text("No tools yet. \(name) reads only what is in its folder.").font(.ui(13)).foregroundStyle(Ink.tertiary).padding(.top, 14)
        }
        ForEach(tools) { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    // A grey letter tile, as the canvas draws every tool and agent tile. These were
                    // eight hues picked by the row's position in the list, so a tool changed colour
                    // whenever the list reordered and the colour said nothing about the tool. One of
                    // the eight was a goldenrod, and gold is out by brand rule.
                    // The letter is Ink.text, not the quiet grey the canvas draws it in: the canvas
                    // is dark only, and a quiet grey letter on the grey chip falls to about 2.8:1 in
                    // light mode. The drive test could not read half of them.
                    Text(t.letter).font(.ui(14, .bold)).foregroundStyle(Ink.text)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.chip))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.ui(15, .semibold)).lineLimit(1)
                        Text(t.detail).font(.ui(12.5)).foregroundStyle(Color(hex: 0x7A7F7B)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if t.path == .statement {
                        Button("Show") { NSWorkspace.shared.open(statementsFolder) }.buttonStyle(.plain)
                            .font(.ui(12.5)).foregroundStyle(Ink.greenText).probe("show:\(t.name)") { NSWorkspace.shared.open(statementsFolder) }
                    }
                    badge(t)
                }
                .padding(.vertical, 12)
                if adding == t.id { paths(for: t) }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0F1EF)).frame(height: 1) }
        }
    }

    @ViewBuilder private func badge(_ t: Role.Tool) -> some View {
        if t.added {
            Text("Added").font(.ui(12.5, .semibold)).foregroundStyle(Ink.greenText)
                .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(Ink.greenSoft))
        } else {
            let title = adding == t.id ? "Close" : t.path == nil ? "Add" : "Change"
            let act = { withAnimation(.snappy(duration: 0.2)) { adding = adding == t.id ? nil : t.id } }
            Button(action: act) {
                Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Ink.text)
                    .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(Ink.chip)).contentShape(Capsule())
            }
            .buttonStyle(.plain).probe("add:\(t.name)", action: act)
        }
    }

    private func paths(for t: Role.Tool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No connector for \(t.name). The cheapest ways in:").font(.ui(12.5)).foregroundStyle(Ink.secondary)
            ForEach(Role.Path.allCases, id: \.self) { p in
                Button { choose(p, for: t) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.path == p ? "checkmark.circle.fill" : "circle").foregroundStyle(t.path == p ? Ink.green : Ink.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).font(.ui(13.5, .medium))
                            Text(p.cost).font(.ui(12)).foregroundStyle(Ink.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bubble))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).probe("path:\(p.rawValue)") { choose(p, for: t) }
            }
        }
        .padding(.bottom, 12)
    }

    private var statementsFolder: URL { Vault.domain(domain).appending(path: "source/statements") }

    // MARK: actions

    private func load() async {
        loadTools()
        do {
            let rows = try await Engine.json(["playbook", "rows"], as: [Role.PlaybookRow].self)
            routines = Role.routines(rows, domain: domain)
            for r in rows where r.running == true && runs.state[r.id] == nil { runs.state[r.id] = .running(nil) }
        } catch { problem = error.localizedDescription }
        loaded = true
    }

    private func loadTools() {
        let state = Vault.read(Vault.domain(domain).appending(path: "memory/state.md")) ?? ""
        tools = Role.tools(domain: domain, apps: Role.vaultApps(), feeds: Role.feeds(state: state),
                           isService: { Role.isService($0) }, folder: "\(domain)/source/statements")
    }

    private func setEnabled(_ r: Role.Routine, _ on: Bool) {
        guard let i = routines.firstIndex(where: { $0.id == r.id }) else { return }
        routines[i].enabled = on
        problem = nil
        Task {
            do {
                _ = try await Engine.run(["playbook", "trigger", r.id, "--domain", r.space, on ? "--resume" : "--off", "--json"])
            } catch {
                if let j = routines.firstIndex(where: { $0.id == r.id }) { routines[j].enabled = !on }
                problem = "Couldn't turn \(r.name) \(on ? "on" : "off"): \(error.localizedDescription)"
            }
        }
    }

    private func choose(_ p: Role.Path, for t: Role.Tool) {
        guard let feed = t.feed else { return }
        let url = Vault.domain(domain).appending(path: "memory/state.md")
        do {
            let before = Vault.read(url) ?? ""
            try IntentStore().write(Role.choose(p, for: feed, in: before), to: url)
            if p == .statement { try FileManager.default.createDirectory(at: statementsFolder, withIntermediateDirectories: true) }
            problem = nil
        } catch { problem = error.localizedDescription }
        adding = nil
        loadTools()
    }
}

/// Playbook runs started from a role page. They outlive the page (leaving doesn't stop a run).
@MainActor @Observable
final class RoutineRuns {
    static let shared = RoutineRuns()
    enum State: Equatable { case running(String?), done(String), failed(String) }
    var state: [String: State] = [:]

    func run(_ id: String) {
        if case .running = state[id] { return }
        state[id] = .running(nil)
        Task {
            var last: Role.RunEvent?
            var total = 0
            do {
                for try await line in Engine.lines(["run-playbook", id, "--stream"]) {
                    guard let e = try? JSONDecoder().decode(Role.RunEvent.self, from: Data(line.utf8)) else { continue }
                    if let n = e.steps { total = n }
                    if e.phase == "step", let i = e.index {
                        state[id] = .running(total > 1 ? "step \(i + 1) of \(total)" + (e.label.map { ": \($0)" } ?? "") : e.label)
                    }
                    if ["complete", "error", "blocked"].contains(e.phase ?? "") { last = e }
                }
                if let last, last.ok == true { state[id] = .done(last.note ?? "") }
                else { state[id] = .failed(last?.note ?? last?.reason ?? "the engine stopped without a result") }
            } catch {
                state[id] = .failed(error.localizedDescription)
            }
        }
    }
}
