#if os(iOS)
import SwiftUI

/// The family's tag picker, as Glyph Jot's has been since its 32 tags stopped fitting a screen:
/// a field that both searches and names a new one, a count, and a row per tag carrying the hash,
/// the name, what it covers and a tick when it is on (Fru, 2026-11-10, of Jot's: "why is there no
/// search on this model here for the tags?"; 2026-11-11, of Omega's wall of chips: "compare how
/// Jot allows for tags").
///
/// A screen passes its tags and which are on. It does not pass a size, a spacing or a colour
/// beyond its own tint.
///
/// Glyph Jot still draws its own copy of this (`Jot/Tags.swift`), because that one also carries
/// suggestions from the words, renaming and re-ordering. It is the one to move onto this next.
public struct GlyphTagPicker: View {
    /// One tag: what it is called, and one line on what it covers, so choosing is a decision and
    /// not a memory test.
    public struct Tag: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let covers: String?
        public init(id: String, name: String, covers: String? = nil) {
            self.id = id; self.name = name; self.covers = covers
        }
    }

    private let tags: [Tag]
    @Binding private var on: Set<String>
    private let tint: Color
    /// Naming one that does not exist yet. nil means this screen's tags are a fixed list, and the
    /// field only narrows it.
    private let add: ((String) -> Void)?
    @State private var typed = ""

    public init(_ tags: [Tag], on: Binding<Set<String>>, tint: Color, add: ((String) -> Void)? = nil) {
        self.tags = tags; self._on = on; self.tint = tint; self.add = add
    }

    private var matching: [Tag] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.covers?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    private var exists: Bool {
        let q = typed.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && tags.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlyphTagHash(name: "tag", size: 15)
                TextField(add == nil ? "Search your tags" : "Search or add a tag", text: $typed)
                    .textFieldStyle(.plain).autocorrectionDisabled()
                    .accessibilityIdentifier("tag.search")
                if !typed.isEmpty {
                    Button { typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))

            Text(typed.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Your tags \u{00b7} \(tags.count)" : "\(matching.count) of \(tags.count)")
                .font(.system(size: 11.5, weight: .semibold)).tracking(0.5).textCase(.uppercase)
                .foregroundStyle(tint)
                .accessibilityIdentifier("tag.count")

            if let add, !exists, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    let name = typed.trimmingCharacters(in: .whitespaces)
                    add(name); typed = ""
                } label: {
                    Label("Create \u{201c}\(typed.trimmingCharacters(in: .whitespaces))\u{201d}", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                }
                .buttonStyle(.plain).accessibilityIdentifier("tag.create")
            }

            if matching.isEmpty {
                Text(add == nil ? "No tag has those words." : "No tag has those words. Create takes the name as you typed it.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("tag.none")
            }
            ForEach(matching) { row($0) }
        }
    }

    private func row(_ t: Tag) -> some View {
        let here = on.contains(t.id)
        return Button { if here { on.remove(t.id) } else { on.insert(t.id) } } label: {
            HStack(alignment: .top, spacing: 10) {
                GlyphTagHash(name: t.name, size: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    if let covers = t.covers, !covers.isEmpty {
                        Text(covers).font(.system(size: 12)).lineSpacing(4).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(here ? tint : .clear).frame(width: 16)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag." + t.id)
        .accessibilityLabel(t.name)
        .accessibilityAddTraits(here ? .isSelected : [])
    }
}
#endif
