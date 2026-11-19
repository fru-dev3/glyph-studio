import SwiftUI

/// The Tags place every Glyph app has: this app's own tags, what each covers, and how much of
/// this app's log carries it.
///
/// Fru, 2026-11-15, after opening Glyph Well and finding none: "every app will have tags, like
/// for well, which is health... and this is a subset of the tags in CRM. So you have things like
/// tag for stool, tag for food, tag for a workout, tag for feeling. So that is now tracked by
/// tags... If I open an app again on my phone and it doesn't have tags, they're implemented as a
/// subset of the tags relevant to the context of that app, there'll be a problem."
///
/// Which tags are this app's is written on each tag's page in the vault (`apps: ["well"]`), read
/// through `GlyphTags.forApp`. The app supplies only its own counts, so nothing here knows what
/// any app keeps.
///
/// ```swift
/// GlyphTagsScreen(app: "wealth", tint: .wealthGreen, counts: store.tagCounts) { tag in
///     open(tag)
/// }
/// ```
public struct GlyphTagsScreen: View {
    private let app: String
    private let tint: Color
    private let counts: [String: Int]
    private let empty: String
    private let open: ((String) -> Void)?

    /// - Parameters:
    ///   - app: the family id, "well" or "wealth". It picks the subset and nothing else.
    ///   - counts: how many of this app's own things carry each tag, keyed by `GlyphTag.slug`.
    ///     A tag with none is still shown: it exists, and it is one he can file to.
    ///   - empty: what to say when the register has nothing for this app yet.
    ///   - open: what a tapped tag does. Nothing when the app has no page for one yet.
    public init(app: String, tint: Color, counts: [String: Int] = [:],
                empty: String = "They arrive with your vault, and anything you say under a hashtag joins them.",
                open: ((String) -> Void)? = nil) {
        self.app = app
        self.tint = tint
        self.counts = counts
        self.empty = empty
        self.open = open
    }

    /// This app's tags, the ones in use first so the list opens on what he actually files.
    var rows: [(tag: GlyphTag, count: Int)] {
        let mine: [(tag: GlyphTag, count: Int)] = GlyphTags.forApp(app).map { ($0, counts[$0.id] ?? 0) }
        return mine.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.tag.name.localizedCaseInsensitiveCompare(b.tag.name) == .orderedAscending
        }
    }

    public var body: some View {
        let rows = rows
        ScrollView {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "number").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("No tags here yet").font(.headline)
                    Text(empty).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420).padding(.top, 60).padding(.horizontal, 20)
                .accessibilityIdentifier("tags.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.tag.id) { i, row in
                        Button { open?(row.tag.id) } label: { line(row) }
                            .buttonStyle(.plain)
                            .disabled(open == nil)
                            .accessibilityIdentifier("tags.row.\(row.tag.id)")
                        if i < rows.count - 1 { Divider().padding(.leading, 40) }
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: 760)
                .padding(.vertical, 6)
            }
        }
        .accessibilityIdentifier("tags.page")
    }

    @ViewBuilder private func line(_ row: (tag: GlyphTag, count: Int)) -> some View {
        HStack(spacing: 10) {
            GlyphTagHash(name: row.tag.name, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tag.name).font(.system(size: 15, weight: .medium))
                if let covers = row.tag.covers, !covers.isEmpty {
                    Text(covers).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(row.count == 0 ? "" : "\(row.count)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(row.count == 0 ? .secondary : tint)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
