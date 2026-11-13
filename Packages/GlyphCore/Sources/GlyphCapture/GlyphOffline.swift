#if os(iOS)
import SwiftUI

/// The family's one offline row (Fru, 2026-11-11: "make the offline consistent, just one row").
///
/// Every app had drawn its own. Glyph Jot's was an amber two-line card with a chevron, Glyph
/// Omega's a grey line with a retry, Glyph Time's a pill in the thread, and each said the same
/// thing in a different shape and a different number of lines. This is the shape, once: one row,
/// one line, the slash-cloud at the left and one control at the right.
///
/// It is a banner and never a barrier. Capture never blocks on the vault: what was said is on the
/// phone and goes when it can reach, and this row says so rather than standing in the way.
///
/// An app passes what is true and what to do about it. It does not pass a size, a spacing or a
/// corner radius.
public struct GlyphOffline: View {
    /// The short words: "Offline", "Glyph is away". Never a sentence.
    private let state: String
    /// What that means for Fru right now, in a few words: "showing 7:46 AM", "3 waiting, kept
    /// here". nil when there is nothing to add.
    private let detail: String?
    /// Try it again. Draws the turning arrow.
    private let retry: (() -> Void)?
    /// Somewhere to go about it (Glyph Jot's Settings). Draws the chevron, and the whole row taps.
    private let open: (() -> Void)?
    private let tint: Color

    public init(_ state: String, detail: String? = nil, tint: Color = .officeGreen,
                retry: (() -> Void)? = nil, open: (() -> Void)? = nil) {
        self.state = state; self.detail = detail; self.tint = tint; self.retry = retry; self.open = open
    }

    /// Amber, never red: red is a live recording in this family and means nothing else. Out of
    /// reach is worth noticing and is not an emergency.
    public static let amber = Color(red: 0xE5 / 255, green: 0xA2 / 255, blue: 0x3D / 255)

    public var body: some View {
        let row = HStack(spacing: 8) {
            Image(systemName: "icloud.slash").font(.footnote).foregroundStyle(Self.amber)
            Text(detail.map { "\(state) \u{00b7} \($0)" } ?? state)
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if retry != nil {
                Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold)).foregroundStyle(tint)
            } else if open != nil {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if let go = open ?? retry {
                Button(action: go) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                row
            }
        }
        .background(Color(.secondarySystemBackground))
        // One element, so a screen reader says the sentence and not whichever glyph inside it the
        // identifier happened to land on.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(state). \($0)" } ?? state)
        .accessibilityIdentifier("offline")
    }
}
#endif
