#if os(macOS)
import AppKit
import SwiftUI

/// The vault page every Glyph Mac app shows in its settings, in one layout with one set of words.
///
/// Fru, 2026-10-31: "each of these apps should have a setting page, so I can see the way the vault is
/// connected and that the vault is connected live... maybe have like a green check mark or something to
/// show that it's live. And then if somebody wants to install this app brand new, if they don't have a
/// vault, how do they go ahead and create a vault?"
///
/// It answers four things and nothing else: where the vault is, whether it is live right now, what this
/// app keeps there, and how to make one if there is none. The app supplies only the answers that are
/// genuinely its own, where its vault is and what it keeps; everything a reader sees is the same
/// in every app.
public struct GlyphVaultSettings: View {
    /// What a check found. There is no "unknown but probably fine": a check that has not finished is
    /// `checking`, and a check that failed is `away`, never the last good answer.
    public enum Health: Equatable { case checking, live, away(String) }

    private let keeps: String
    private let folders: [String]
    private let where_: () -> String?
    private let probe: () async -> Result<Void, Error>
    private let create: (URL, [String]) async -> Result<Void, Error>

    @State private var health: Health = .checking
    @State private var path: String?
    @State private var making = false

    /// - Parameters:
    ///   - where_: the vault's path as the app resolves it, re-read on every check. GlyphCore does not
    ///     know where an app keeps that answer, so nothing about one install is written down here.
    ///   - keeps: one line naming what this app writes to the vault, in this app's own words.
    ///   - folders: the folders this app needs, created when someone makes a vault from here.
    ///   - probe: a real read of the vault, performed now. It must touch the disk every time: a tick
    ///     that comes from a cached snapshot is the bug this page exists to make visible.
    ///   - create: make a vault at this path with these folders, then read it back. Returning success
    ///     means a read actually succeeded, not that the folders were written.
    public init(where_: @escaping () -> String?,
                keeps: String,
                folders: [String],
                probe: @escaping () async -> Result<Void, Error>,
                create: @escaping (URL, [String]) async -> Result<Void, Error>) {
        self.where_ = where_
        self.keeps = keeps
        self.folders = folders
        self.probe = probe
        self.create = create
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Vault").font(.system(size: 22, weight: .semibold))

            if let path {
                row("Where") {
                    HStack(spacing: 8) {
                        Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .buttonStyle(.link)
                    }
                }
                row("Live") { status }
                row("Keeps") { Text(keeps).foregroundStyle(.secondary) }
            } else {
                // No vault at all: the only thing to offer is making one.
                Text("No vault yet.").font(.system(size: 15, weight: .medium))
                Text("Glyph keeps everything in a folder you own, on this Mac. Choose where it goes and this app will make the folders it needs, then read them back to be sure it took.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(path == nil ? "Create a vault" : "Create a vault elsewhere") { choose() }
                    .disabled(making)
                    .accessibilityIdentifier("vault-create")
                if path != nil {
                    Button("Check again") { Task { await check() } }
                        .disabled(health == .checking)
                        .accessibilityIdentifier("vault-recheck")
                }
                if making { ProgressView().controlSize(.small) }
            }

            Text("If the vault is away this app keeps working and writes what you do on this Mac, then syncs it back when the vault returns. Nothing from the vault stays on screen while it is away.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await check() }
    }

    /// The tick, and never from a remembered answer: `check()` sets `.checking` first, so a failed read
    /// can only ever show as away.
    @ViewBuilder private var status: some View {
        switch health {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking").foregroundStyle(.secondary) }
                .accessibilityIdentifier("vault-checking")
        case .live:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.glyphGreen)
                Text("Live").foregroundStyle(Color.glyphGreen)
            }
            .accessibilityIdentifier("vault-live")
        case .away(let why):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Away").foregroundStyle(.secondary)
                }
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .accessibilityIdentifier("vault-away")
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    /// Reads the path from Glyph's own config every time, then reads the vault itself. Both halves are
    /// fresh: a path remembered from a previous check would survive someone moving the vault.
    @MainActor private func check() async {
        health = .checking
        path = where_()
        guard path != nil else { health = .away("No vault folder is set for this Mac"); return }
        switch await probe() {
        case .success: health = .live
        case .failure(let e): health = .away(message(e))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create"
        panel.message = "Choose where your vault goes. Glyph makes a folder here and reads it back."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        making = true
        Task { @MainActor in
            let made = await create(url, folders)
            making = false
            switch made {
            case .success: await check()   // the proof is a read, so run the real one
            case .failure(let e): health = .away(message(e))
            }
        }
    }

    private func message(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }
}

public extension Color {
    /// #008000 office green, #3FA34D in the dark so it reads on black. The one accent in every Glyph app.
    static let glyphGreen: Color = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x3F / 255, green: 0xA3 / 255, blue: 0x4D / 255, alpha: 1)
            : NSColor(red: 0, green: 128 / 255, blue: 0, alpha: 1)
    })
}
#endif
