import SwiftUI

/// "Which Ken?": the pages a name could mean, as a clean inset list (Fru, 2026-10-30: "the pills below look
/// bad"). Each row is a small circle with the initials, the name, one short fact when there is one, and a
/// chevron, the whole row one tap; hairlines between; the last row makes a new page (a plus, in secondary).
/// Used by Glyph Native's CRM card and Glyph CRM's review on the iPhone. Each row's accessibility identifier
/// is `<idPrefix>-<name>`, the new row `<idPrefix>-new`; its label is the name.
public struct WhichList: View {
    public struct Choice: Identifiable {
        public var id: String, name: String, detail: String?
        public init(id: String, name: String, detail: String? = nil) { self.id = id; self.name = name; self.detail = detail }
    }
    let choices: [Choice], newLabel: String, tint: Color, idPrefix: String
    let pick: (String?) -> Void
    public init(_ choices: [Choice], newLabel: String, tint: Color, idPrefix: String, pick: @escaping (String?) -> Void) {
        self.choices = choices; self.newLabel = newLabel; self.tint = tint; self.idPrefix = idPrefix; self.pick = pick
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(choices) { c in
                row(id: c.id, name: c.name, detail: c.detail) {
                    Text(Self.initials(c.name)).font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(tint, in: Circle())
                }
                Divider().padding(.leading, 54)
            }
            row(id: nil, name: newLabel, detail: nil) {
                Image(systemName: "plus").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).background(Color.secondary.opacity(0.15), in: Circle())
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(id: String?, name: String, detail: String?, @ViewBuilder mark: () -> some View) -> some View {
        Button { pick(id) } label: {
            HStack(spacing: 12) {
                mark()
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body).foregroundStyle(id == nil ? .secondary : .primary).lineLimit(1)
                    if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("\(idPrefix)-\(id == nil ? "new" : name)")
    }

    /// "Ken Park" -> "KP", "Ken" -> "K".
    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
