import AppKit
import SwiftUI

/// Sources: the vault Studio works on and each Glyph app it reads, with how each stands. The vault
/// comes first because Studio needs one; the apps follow, each with a switch for whether agents
/// may read it. Studio reads these files and never changes them.
struct SourcesScreen: View {
    let open: String?
    @Environment(AppModel.self) private var model
    @State private var rows: [SourceStatus] = []
    @State private var on: Set<SourceID> = Sources.enabled()
    @State private var mode = Vault.mode
    @State private var problem: String?
    @State private var hover: SourceID?

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sources").font(.ui(30, .bold)).foregroundStyle(Ink.text)
                    Text("What your agents read. Glyph Bot reads these files and never changes them; anything an agent saves goes through Glyph Engine, with a receipt.")
                        .font(.ui(14)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6).columnMax(0.80, alignment: .leading)

                    vaultCard.padding(.top, 26)

                    Text("Glyph apps").font(.ui(13, .semibold)).foregroundStyle(Ink.tertiary).padding(.top, 30).padding(.bottom, 10)
                    VStack(spacing: 0) {
                        ForEach(rows.filter { $0.id != .vault }, id: \.id) { r in
                            appRow(r).id(r.id)
                            if r.id != SourceID.allCases.last { Rectangle().fill(Ink.line).frame(height: 1).padding(.leading, 64) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.surface))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.border))

                    if let problem { Text(problem).font(.ui(12.5)).foregroundStyle(Ink.warn).padding(.top, 12).accessibilityIdentifier("sources-problem") }
                }
                .columnMax(1.03, alignment: .leading)
                .padding(.horizontal, 40).padding(.vertical, 44)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Ink.surface)
        .task(id: open) { reload() }
    }

    private func reload() {
        let root = Vault.root
        rows = SourceID.allCases.map { Sources.status($0, root: root, now: AppClock.now) }
        on = Sources.enabled()
        mode = Vault.mode
    }

    // MARK: the vault

    private var vaultCard: some View {
        let s = rows.first { $0.id == .vault }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                tile(.vault, state: s?.state ?? .missing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .demo ? "Demo vault" : "Your vault").font(.ui(17, .semibold)).foregroundStyle(Ink.text)
                    statusLine(s)
                    Text(Self.abbreviate(Vault.root.path)).font(.ui(12)).foregroundStyle(Ink.tertiary).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("vault-path")
                }
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    segment("Demo", .demo)
                    segment("Yours", .yours)
                }
                .padding(2).background(Capsule().fill(Ink.chip))
            }
            Text(mode == .demo
                 ? "A made-up vault for trying Glyph Bot. Agents can change it freely."
                 : "The vault every Glyph app uses (from ~/.prevail/config.json). Glyph Bot only reads it; agents save to it through Glyph Engine after you say Save.")
                .font(.ui(12.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PillButton(title: "Show in Finder", small: true) { NSWorkspace.shared.activateFileViewerSelecting([Vault.root]) }
                PillButton(title: "Check again", small: true) { reload() }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(open == "vault" ? Ink.green : Ink.border))
    }

    private func segment(_ title: String, _ m: Vault.Mode) -> some View {
        let on = mode == m
        return Button { choose(m) } label: {
            Text(title).font(.ui(12.5, on ? .semibold : .medium)).foregroundStyle(on ? Ink.onInk : Ink.secondary)
                .padding(.horizontal, 14).frame(height: 26)
                .background(Capsule().fill(on ? Ink.text : .clear)).contentShape(Capsule())
        }
        .buttonStyle(.plain).help(m == .demo ? "Use the made-up demo vault" : "Use your vault (read only)")
        .probe("vault:\(m.rawValue)") { choose(m) }
    }

    private func choose(_ m: Vault.Mode) {
        guard m != Vault.mode else { return }
        do {
            try Vault.set(mode: m)
            problem = nil
            reload()
            Task { await model.refresh() }
        } catch { problem = error.localizedDescription; mode = Vault.mode }
    }

    // MARK: an app

    private func appRow(_ r: SourceStatus) -> some View {
        let isOn = on.contains(r.id)
        return HStack(alignment: .center, spacing: 14) {
            tile(r.id, state: r.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.id.title).font(.ui(15, .semibold)).foregroundStyle(Ink.text)
                Text(r.id.blurb).font(.ui(12.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                statusLine(r)
            }
            Spacer(minLength: 10)
            if hover == r.id || open == r.id.rawValue {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                        .frame(width: 28, height: 28).background(Circle().fill(Ink.chip)).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Show \(r.id.folder) in Finder").disabled(r.state == .missing)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Toggle38(isOn: Binding(get: { isOn }, set: { v in Sources.set(r.id, on: v); on = Sources.enabled() }), label: "Read \(r.id.title)")
                Text(isOn ? "Agents read" : "Off").font(.ui(11)).foregroundStyle(Ink.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(open == r.id.rawValue ? Ink.bubble : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 ? r.id : (hover == r.id ? nil : hover) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-row:\(r.id.rawValue)")
    }

    private func tile(_ id: SourceID, state: SourceStatus.State) -> some View {
        Image(systemName: id.symbol).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(state == .connected ? Ink.greenText : Ink.secondary)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(state == .connected ? Ink.greenSoft : Ink.chip))
    }

    private func statusLine(_ s: SourceStatus?) -> some View {
        let state = s?.state ?? .missing
        return HStack(spacing: 6) {
            Circle().fill(state == .connected ? Ink.green : state == .empty ? Ink.tertiary : Ink.warn).frame(width: 7, height: 7)
            Text(Self.word(state)).font(.ui(12, .medium)).foregroundStyle(Ink.text)
            Text(s?.detail ?? "").font(.ui(12)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
    }

    static func word(_ s: SourceStatus.State) -> String {
        switch s { case .connected: "Connected"; case .empty: "Empty"; case .missing: "Not found" }
    }

    /// "~/Library/..." instead of the home folder's full path.
    static func abbreviate(_ path: String) -> String {
        let home = URL.homeDirectory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
