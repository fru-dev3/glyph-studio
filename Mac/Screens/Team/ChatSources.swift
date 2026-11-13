import AppKit
import SwiftUI

/// Under a reply: what the agent read (numbered as it cites them) and the steps it took. Folded to
/// one quiet line; opens to the list, and each row opens to the excerpt and the file.
struct ReadsView: View {
    let reads: [SourceExcerpt]
    let steps: [String]
    let reply: String
    let lineID: UUID
    @State private var open = false
    @State private var shown: Int?

    var body: some View {
        if !reads.isEmpty || !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "book.pages").font(.system(size: 11, weight: .semibold))
                        Text(summary).font(.ui(12.5, .medium))
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Ink.secondary).padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(Ink.chip)).contentShape(Capsule())
                }
                .buttonStyle(.plain).probe("Read", action: toggle)
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(reads) { r in row(r) }
                        ForEach(steps, id: \.self) { s in
                            HStack(spacing: 10) {
                                Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Ink.tertiary).frame(width: 22)
                                Text(s).font(.ui(12.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.border))
                    .columnMax(0.80, alignment: .leading)
                }
            }
            .padding(.leading, 6)
        }
    }

    private var cited: Set<Int> { Turn.cited(in: reply) }

    private var summary: String {
        var parts: [String] = []
        if !reads.isEmpty {
            let used = cited.intersection(reads.map(\.n)).count
            parts.append("Read \(reads.count) \(reads.count == 1 ? "source" : "sources")" + (used > 0 ? ", cited \(used)" : ""))
        }
        if !steps.isEmpty { parts.append("\(steps.count) \(steps.count == 1 ? "step" : "steps")") }
        return parts.joined(separator: " · ")
    }

    private func toggle() { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }

    private func row(_ r: SourceExcerpt) -> some View {
        let isOpen = shown == r.n
        let flip = { withAnimation(.easeOut(duration: 0.15)) { shown = isOpen ? nil : r.n } }
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: flip) {
                HStack(spacing: 10) {
                    Text("\(r.n)").font(.ui(11.5, .bold)).foregroundStyle(cited.contains(r.n) ? Ink.onInk : Ink.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(cited.contains(r.n) ? Ink.green : Ink.chip))
                    Image(systemName: r.source.symbol).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.ui(13, .medium)).foregroundStyle(Ink.text).lineLimit(1)
                        Text(r.path).font(.ui(11.5)).foregroundStyle(Ink.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).probe("source:\(r.n)", action: flip)
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text(r.text).font(.ui(12)).foregroundStyle(Ink.secondary).textSelection(.enabled)
                        .lineLimit(14).frame(maxWidth: .infinity, alignment: .leading)
                    Button { reveal(r.path) } label: {
                        Label("Show in Finder", systemImage: "folder").font(.ui(12, .medium)).foregroundStyle(Ink.greenText)
                    }
                    .buttonStyle(.plain).probe("show:\(r.n)") { reveal(r.path) }
                }
                .padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
    }

    private func reveal(_ rel: String) {
        let url = Vault.root.appending(path: rel)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// One thing a reply asked to save: Save or Skip; once saved, where the engine filed it, and Undo.
struct SaveCard: View {
    let item: ChatSession.SaveItem
    let save: () -> Void
    let skip: () -> Void
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28).background(Circle().fill(tintSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.ui(14)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.ui(12)).foregroundStyle(Ink.tertiary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            switch item.state {
            case .proposed, .failed:
                PillButton(title: "Skip", small: true, action: skip)
                PillButton(title: "Save", primary: true, small: true, action: save)
            case .saving:
                ProgressView().controlSize(.small)
            case .saved:
                PillButton(title: "Undo", small: true, action: undo)
            case .skipped:
                EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.bubble))
        .columnMax(0.80, alignment: .leading)
        .opacity(item.state == .skipped ? 0.55 : 1)
    }

    private var icon: String {
        switch item.state {
        case .saved: "checkmark"
        case .failed: "exclamationmark"
        case .skipped: "minus"
        default: "square.and.arrow.down"
        }
    }
    private var tint: Color { if case .failed = item.state { return Ink.warn }; return item.state.isSaved ? Ink.onInk : Ink.greenText }
    private var tintSoft: Color { if case .failed = item.state { return Ink.warnSoft }; return item.state.isSaved ? Ink.green : Ink.greenSoft }

    private var caption: String {
        switch item.state {
        case .proposed: "Asks to save this to the vault"
        case .saving: "Saving through Glyph Engine"
        case .saved(let t): "Saved to \(t.where)" + (t.file.map { " · \($0)" } ?? "")
        case .skipped: "Not saved"
        case .failed(let m): "Not saved: \(m)"
        }
    }
}

extension ChatSession.SaveItem.State {
    var isSaved: Bool { if case .saved = self { return true }; return false }
}

/// The sources a message will read, as chips over the composer: lit when they go with this message.
/// They light up by themselves from the words you type; a tap turns one on or off for this chat.
struct SourceChips: View {
    let lit: Set<SourceID>
    let available: Set<SourceID>
    let toggle: (SourceID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Reads").font(.ui(12)).foregroundStyle(Ink.tertiary)
            ForEach(SourceID.allCases.filter { $0 != .vault }) { s in
                let on = lit.contains(s), can = available.contains(s)
                Button { toggle(s) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(s.chip).font(.ui(12, on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Ink.greenText : (can ? Ink.secondary : Ink.tertiary))
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(on ? Ink.greenSoft : Ink.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!can)
                .help(can ? (on ? "\(s.title) goes with this message" : "Read \(s.title) for this message") : "\(s.title) is off or has no data. See Sources.")
                .probe("reads:\(s.rawValue)") { toggle(s) }
            }
            Spacer()
        }
        .column()
    }
}
