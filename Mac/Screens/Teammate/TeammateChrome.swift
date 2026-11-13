import SwiftUI
import GlyphCapture

/// The teammate header the chat screen uses (avatar, name, a line under it, Role and the screen
/// button), drawn here until Screens/Team's ChatHeader is shared. Role opens the role page, the
/// screen button watches it work; on those pages the same button goes back to the chat.
struct TeammateHeader<Extra: View>: View {
    @Environment(AppModel.self) private var model
    let domain: String
    let title: String
    let subtitle: String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 12) {
            Avatar(look: model.teammate(domain)?.look ?? Teammate.look(for: domain), size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(15, .semibold)).lineLimit(1)
                Text(subtitle).font(.ui(12)).foregroundStyle(Color(hex: 0x7A7F7B)).lineLimit(1)
            }
            Spacer(minLength: 12)
            extra
            HeaderChip(title: "Role", filled: true) { model.go(onRole ? .chat(domain) : .role(domain)) }
            RoundIcon(symbol: "display", label: onWatch ? "Back to the chat" : "Watch it work") {
                model.go(onWatch ? .chat(domain) : .watch(domain))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }

    private var onRole: Bool { model.route == .role(domain) }
    private var onWatch: Bool { model.route == .watch(domain) }
}

extension TeammateHeader where Extra == EmptyView {
    init(domain: String, title: String, subtitle: String) {
        self.init(domain: domain, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The header's 32pt buttons: grey filled (Role) or white with a hairline (Stop).
struct HeaderChip: View {
    let title: String
    var filled = false
    var id: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(13, filled ? .medium : .regular)).foregroundStyle(Ink.text)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(filled ? Ink.chip : Ink.surface))
                .overlay(Capsule().strokeBorder(filled ? .clear : Ink.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .probe(id ?? title, action: action)
    }
}

/// The message box under a teammate's page: a plus, the field, the mic. Return sends.
struct TeammateComposer: View {
    let placeholder: String
    @Binding var text: String
    var id = "composer"
    let send: () -> Void

    @State private var dictation = LiveDictation()
    /// Send stops a take first, so all of what was said goes, and nothing said after comes back.
    private func go() { dictation.finishForSend(); send() }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34).background(Circle().fill(Ink.chip))
            TextField("", text: $text)
                .textFieldStyle(.plain).font(.ui(15))
                .background(alignment: .leading) {
                    if text.isEmpty { Text(placeholder).font(.ui(15)).foregroundStyle(Color(hex: 0x9A9F9B)).allowsHitTesting(false) }
                }
                .onSubmit(go)
                .probeField(id, text: $text, submit: go)
            Mic(text: $text, dictation: dictation, id: id)
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .column(height: 50)
        .background(Capsule().fill(Ink.surface).shadow(color: .black.opacity(0.1), radius: 10, y: 6))
        .overlay(Capsule().strokeBorder(Ink.border))
        .padding(.top, 14).padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }
}

/// A teammate's bubble, as in the chat: a light grey card, an optional small line on top.
struct TeammateBubble<Body: View>: View {
    var from: String? = nil
    @ViewBuilder var content: Body
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let from { Text(from).font(.ui(12)).foregroundStyle(Ink.tertiary) }
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.bubble))
    }
}
