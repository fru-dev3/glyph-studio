import GlyphCapture
import SwiftUI

/// The Tags place: Glyph Bot's own subset of the one register, with the line each tag covers.
///
/// the owner, 2026-11-18: "Tags is really the main way I would be collecting and synthesizing
/// information. That's the key. So if I want to look for something, I can just go to that tag and
/// find it." Bot was one of four apps with no tags at all while eight others had theirs.
///
/// The family's own screen (GlyphTagsScreen) over the register the CRM is the source of truth
/// for. Which tags are Bot's is written on each tag's page in the vault (`apps: ["bot"]`), never
/// in a list here: book, content, decisions, ideas, learning, mindset, names, notes, systems and
/// tech name this app today, and a tag added to the register joins them with no build.
///
/// No counts. Bot keeps conversations and decisions rather than entries filed under a tag, so a
/// zero beside every row would say less than nothing. What this screen is for is the words
/// themselves: which tags exist, what each one means, and the same meaning in every app.
struct TagsScreen: View {
    /// Read again when the place opens, for a tag added since launch. GlyphTagsScreen asks for
    /// the subset while it draws rather than watching it, so the redraw has to be asked for: the
    /// screen is rebuilt on `reread` changing, and the register is read before that.
    @State private var reread = 0

    var body: some View {
        MoreBoard(title: "Tags") {
            MoreBarNote(text: TagsScreen.note)
        } content: {
            ScrollView {
                GlyphTagsScreen(app: "bot", tint: Ink.green,
                                empty: "They arrive with your vault. A tag belongs here when its page names this app, and it means the same thing in Glyph CRM and in every other app.")
                    .padding(.top, 18).padding(.bottom, 30)
            }
        }
        .id(reread)
        .task {
            guard GlyphTags.shared.readVault(Vault.root) else { return }
            reread += 1
        }
        .probe("screen:tags")
    }

    /// "10 tags · the same ones Glyph CRM holds", or the honest line before the register is read.
    static var note: String {
        let n = GlyphTags.forApp("bot").count
        return n == 0 ? "From your vault" : "\(n) \(n == 1 ? "tag" : "tags") · the same ones Glyph CRM holds"
    }
}
