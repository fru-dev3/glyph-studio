import SwiftUI

/// What a screen shows before there is anything on it: a mark, what the screen is for, a sentence
/// saying how to start, and the one action that starts it.
///
/// Drawn once here because Fru's governing rule is one model for every app: "the same design, the
/// same layout, the same pixel, the same placement that just repeats throughout every single
/// page". It was five: Glyph Well drew a 34pt mark over a headline in a card, Glyph Omega a 30pt
/// mark over a 15pt title with no card, Glyph Wealth a 32pt title with no mark at all and left
/// aligned, Glyph Time a mark over a title with no sentence under it, and Glyph Jot a mark over one
/// block of text with no title. Five answers to the same question, and a person moving between two
/// of the apps sees it.
///
/// This is Well's, which was the most finished of the five, with Wealth's action: centred, the mark
/// in the app's own tint, the title, the sentence, and a button when the screen has one way to
/// start. An app passes its words, its tint and its card colour, and never a dimension.
///
/// Accessibility identifiers: `empty` on the whole thing, and the action carries `probe`, which
/// defaults to `empty.action`. A screen whose only way to start is this button should pass its own
/// id, so the id follows the control rather than the control following the id.
public struct GlyphEmpty: View {
    let symbol: String?
    let title: String
    let text: String?
    let tint: Color
    let card: Color?
    let action: (title: String, run: () -> Void)?
    let probe: String

    /// `card` nil draws it straight on the page, which is right inside something that is already a
    /// card. `text` nil leaves the sentence out, for a screen whose title says the whole of it.
    public init(symbol: String? = nil, title: String, text: String? = nil,
                tint: Color = .officeGreen, card: Color? = nil,
                action: (title: String, run: () -> Void)? = nil, probe: String = "empty.action") {
        self.symbol = symbol; self.title = title; self.text = text
        self.tint = tint; self.card = card; self.action = action; self.probe = probe
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 34, weight: .light))
                    .foregroundStyle(tint.opacity(0.8))
            }
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let text, !text.isEmpty {
                // The sentence is drawn on the phone too. It was behind an `os(macOS)` in Glyph
                // Well, so sixteen empty states on the iPhone were a title with nothing under it
                // and the words had been written all along.
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380).padding(.horizontal, 20)
            }
            if let action {
                Button(action.title) { action.run() }
                    .font(.subheadline.weight(.semibold))
                    .tint(tint)
                    .padding(.top, 4)
                    .accessibilityIdentifier(probe)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
        .modifier(GlyphEmptyGround(card: card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty")
    }
}

/// The card behind it, or nothing. A modifier rather than an `if` in the body, so the view has one
/// shape either way and a transition does not have two things to animate between.
private struct GlyphEmptyGround: ViewModifier {
    let card: Color?
    func body(content: Content) -> some View {
        if let card {
            content.background(card, in: .rect(cornerRadius: 18, style: .continuous))
        } else {
            content
        }
    }
}
