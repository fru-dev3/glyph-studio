import AppKit
import SwiftUI
import GlyphCapture

// The pieces of a conversation, shared by every chat-shaped screen (a teammate's chat, Ben's weekly
// note): the header, a bubble, an approval card, a page card and the composer. Sizes from
// design/gen.py (chat_header, me, them, btn, doc, composer).

/// The bar above a conversation: avatar, name, the role line, then Role and Watch work.
struct ChatHeader<Extra: View>: View {
    let look: Look
    let title: String
    let subtitle: String
    var mood: FaceMood = .rest
    var onRole: (() -> Void)?
    var onWatch: (() -> Void)?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 12) {
            Avatar(look: look, size: 40, mood: mood)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(15, .semibold))
                Text(subtitle).font(.ui(12)).foregroundStyle(Color(hex: 0x7A7F7B)).lineLimit(1)
            }
            Spacer(minLength: 12)
            extra
            if let onRole {
                Button(action: onRole) {
                    Text("Role").font(.ui(13, .medium)).padding(.horizontal, 14).frame(height: 32)
                        .background(Capsule().fill(Ink.chip)).contentShape(Capsule())
                }
                .buttonStyle(.plain).probe("Role", action: onRole)
            }
            if let onWatch { RoundIcon(symbol: "display", label: "Watch work", action: onWatch) }
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

extension ChatHeader {
    /// A teammate's header from its id: its look and name, "<role> · works toward: <purpose>" unless
    /// a subtitle is given, Role and Watch work buttons, and `trailing` before them.
    init(teammateID id: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Extra) {
        let model = AppModel.shared
        let mate = model.teammate(id)
        self.init(look: mate?.look ?? Teammate.look(for: id),
                  title: mate?.name ?? (id == AppModel.chiefID ? model.chiefName : id.capitalized),
                  subtitle: subtitle ?? ChatSession.roleLine(id),
                  onRole: { model.go(.role(id)) }, onWatch: { model.go(.watch(id)) }, extra: trailing)
    }
}

extension ChatHeader where Extra == EmptyView {
    init(teammateID id: String, subtitle: String? = nil) { self.init(teammateID: id, subtitle: subtitle) { EmptyView() } }

    init(look: Look, title: String, subtitle: String, mood: FaceMood = .rest, onRole: (() -> Void)? = nil, onWatch: (() -> Void)? = nil) {
        self.init(look: look, title: title, subtitle: subtitle, mood: mood, onRole: onRole, onWatch: onWatch) { EmptyView() }
    }
}

/// One message. Yours: black, on the right. A teammate's: light grey on the left, with an optional
/// "From Estate" line above and anything below the text (buttons, a page).
struct ChatBubble<Accessory: View>: View {
    enum Side { case me, them }
    let text: String
    var side: Side = .them
    var from: String?
    var failed = false
    var streaming = false
    /// A bubble carrying something to act on (buttons, a page) takes the whole column, so every card
    /// in the thread shares one right edge with the composer. A plain spoken reply still hugs its
    /// words, which is what a chat should do.
    var fills = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        switch side {
        case .me:
            Text(text).font(.ui(15)).foregroundStyle(Ink.onInk).textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10.5)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.text))
                .columnMax(0.74, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .them:
            FitColumn(fill: fills) {
                // CSS line-height 1.5: half the leading above and below each line box.
                if let from { Text(from).font(.ui(12)).foregroundStyle(Ink.tertiary).padding(.top, -1).padding(.bottom, 11) }
                if !text.isEmpty || !streaming {
                    Text(Self.inline(text)).font(.ui(15)).lineSpacing(4.5).foregroundStyle(failed ? Ink.warn : Ink.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4.5)
                }
                if streaming && text.isEmpty { FaceFeatures(mood: .thinking, size: 30, ink: Ink.secondary).padding(.vertical, -2) }
                else if streaming { TypingDots().padding(.top, 6) }
                accessory
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(failed ? Ink.warnSoft : Ink.bubble))
            // The agent's side is the thread's measure: it fills the column, so every card, bubble
            // and the composer below share one right edge. It used to stop at 0.80 of the column,
            // which left a ragged 141pt of nothing beside every reply.
            .columnMax(1, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ChatBubble {
    /// A reply's Markdown: bold, italic, code and links inline; "- " and "* " lines as bullets,
    /// "#" headings as bold lines, numbered lines kept, line breaks kept.
    static func inline(_ s: String) -> AttributedString { ReplyText.attributed(s) }

}

extension ChatBubble where Accessory == EmptyView {
    init(text: String, side: Side = .them, from: String? = nil, failed: Bool = false, streaming: Bool = false) {
        self.init(text: text, side: side, from: from, failed: failed, streaming: streaming) { EmptyView() }
    }
}

/// Three dots while a reply is on its way.
struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { t in
            let step = Int(t.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { i in Circle().fill(Ink.tertiary.opacity(i == step ? 1 : 0.35)).frame(width: 6, height: 6) }
            }
        }
        .accessibilityLabel("Writing")
    }
}

/// A page an agent wrote, inside a message. Opening it goes to the domain's board, where pages live.
/// The design's page icon (gen.py DOCI, a 16x16 path): a sheet with its corner folded.
struct DocGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var path = Path()
        path.move(to: p(4, 2)); [p(10, 2), p(13, 5), p(13, 14), p(4, 14)].forEach { path.addLine(to: $0) }; path.closeSubpath()
        path.move(to: p(10, 2)); path.addLine(to: p(10, 5)); path.addLine(to: p(13, 5))
        return path
    }
}

struct DocCard: View {
    let title: String
    let subtitle: String
    var id: String? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                DocGlyph().stroke(Ink.green, style: StrokeStyle(lineWidth: 1.6 * 18 / 16, lineCap: .round, lineJoin: .round)).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.ui(13.5, .semibold)).foregroundStyle(Ink.text).padding(.vertical, 2)
                    Text(subtitle).font(.ui(12)).foregroundStyle(Ink.tertiary).padding(.vertical, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 11.5) // 60 pt tall, as drawn
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xECEEEB)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 7) // the design's 10 from the line box; SwiftUI's text sits 3 pt lower
        .fillsBubble()
        .probe(id ?? "page:\(title)", action: open)
    }
}

extension DocCard {
    /// "Page in Tax · 2 sources".
    init(_ brief: Brief, sources: Bool = true, open: @escaping () -> Void) {
        let who = AppModel.shared.teammate(brief.domain)?.name ?? brief.domain.capitalized
        let n = brief.sources
        self.init(title: brief.title, subtitle: "Page in \(who)" + (sources && n > 0 ? " · \(n) source\(n == 1 ? "" : "s")" : ""), open: open)
    }
}

/// Something a teammate is waiting on, with the design's buttons. The answer runs for real
/// (TeamState.answer) and the card then shows what happened.
struct ApprovalCard: View {
    let ask: Ask
    let label: String
    var buttons = true
    var sources = true
    @Environment(AppModel.self) private var model
    @State private var answering = false
    @State private var draft = ""
    private var state: TeamState { TeamState.shared }

    var body: some View {
        ChatBubble(text: ask.text, from: label, fills: true) {
            if let page = ask.page { DocCard(page, sources: sources) { model.go(.chat(ask.domain)) } }
            if let outcome = state.outcomes[ask.id] {
                Label(outcome, systemImage: "checkmark.circle.fill").font(.ui(13.5, .medium)).foregroundStyle(Ink.greenText)
                    .padding(.top, 12)
            } else if buttons {
                if answering { answerField } else { row }
            }
            if let f = state.failures[ask.id] {
                Text(f).font(.ui(13)).foregroundStyle(Ink.warn).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var key: String { ask.domain }

    private var row: some View {
        HStack(spacing: 8) {
            // Green is for a commitment, not for navigation. A loop card's only action is Open,
            // which just takes you somewhere, so it is quiet: four saturated green pills down one
            // column meant nothing on the screen was actually primary.
            PillButton(title: ask.primary, primary: ask.style != .loop, id: "\(key):\(ask.primary)") { primary() }
            if let s = ask.secondary { PillButton(title: s, id: "\(key):\(s)") { secondary() } }
            if state.busy.contains(ask.id) { ProgressView().controlSize(.small).padding(.leading, 4) }
        }
        .padding(.top, 10)
        .disabled(state.busy.contains(ask.id))
    }

    private var answerField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $draft, prompt: Text("Your answer").foregroundStyle(Color(hex: 0x9A9F9B)), axis: .vertical)
                .studioDictatable($draft)
                .textFieldStyle(.plain).font(.ui(15)).lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.border))
                .onSubmit(sendAnswer)
                .probeField("answer:\(key)", text: $draft, submit: sendAnswer)
                .fillsBubble()
            HStack(spacing: 8) {
                PillButton(title: "Send", primary: true, id: "\(key):Send") { sendAnswer() }
                PillButton(title: "Cancel", id: "\(key):Cancel") { answering = false; draft = "" }
                if state.busy.contains(ask.id) { ProgressView().controlSize(.small).padding(.leading, 4) }
            }
        }
        .padding(.top, 12)
    }

    private func primary() {
        switch ask.style {
        case .question: answering = true
        case .loop: model.go(.chat(ask.domain))
        default: state.answer(ask, .yes)
        }
    }

    private func secondary() {
        if ask.style == .review { model.go(.chat(ask.domain)) } else { state.answer(ask, .no) }
    }

    private func sendAnswer() {
        guard let text = draft.nonEmpty else { return }
        state.answer(ask, .answer(text))
    }
}

/// Where you write to a teammate. Return sends; + brings another teammate's context in; the mic
/// (Glyph's shared one) puts your words in the box as you talk, and Send waits for you.
struct Composer: View {
    let who: String
    @Binding var text: String
    var busy = false
    var others: [Teammate] = []
    @Binding var bringIn: [String]
    var files: Binding<[Pending]> = .constant([])
    let send: () -> Void
    @FocusState private var focused: Bool

    @State private var dictation = LiveDictation()
    /// Send stops a take first, so all of what was said goes, and nothing said after comes back.
    private func go() { dictation.finishForSend(); send() }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "Attach photos or files to your message"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let d = try? Data(contentsOf: url) { files.wrappedValue.append(Pending(name: url.lastPathComponent, data: d)) } }
    }

    /// An image on the clipboard (a screenshot, a copied photo) or copied files.
    private func pasteImage() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { if let d = try? Data(contentsOf: url) { files.wrappedValue.append(Pending(name: url.lastPathComponent, data: d)) } }
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            files.wrappedValue.append(Pending(name: "Pasted image.png", data: png))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !files.wrappedValue.isEmpty {
                HStack(spacing: 8) {
                    ForEach(files.wrappedValue) { f in PendingChip(file: f) { files.wrappedValue.removeAll { $0.id == f.id } } }
                    Spacer()
                }
                .column()
            }
            if !bringIn.isEmpty {
                HStack(spacing: 6) {
                    ForEach(bringIn, id: \.self) { id in
                        Button { bringIn.removeAll { $0 == id } } label: {
                            Label("With \(others.first { $0.id == id }?.name ?? id)", systemImage: "xmark").labelStyle(TrailingIcon())
                                .font(.ui(12.5, .medium)).padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(Ink.chip))
                        }
                        .buttonStyle(.plain).probe("without:\(id)") { bringIn.removeAll { $0 == id } }
                    }
                    Spacer()
                }
                .column()
            }
            HStack(spacing: 10) {
                Menu {
                    Button("Photo or file…") { pickFiles() }
                    Button("Paste image") { pasteImage() }.disabled(NSPasteboard.general.canReadObject(forClasses: [NSImage.self]) == false)
                    Section("Bring in a teammate") {
                        ForEach(others) { t in
                            Button(t.name) { if !bringIn.contains(t.id) { bringIn.append(t.id) } }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                        .frame(width: 34, height: 34).background(Circle().fill(Ink.chip)).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Bring in a teammate").probe("Bring in")
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(.ui(15)).focused($focused)
                    .background(alignment: .leading) {
                        if text.isEmpty { Text("Message \(who)").font(.ui(15)).foregroundStyle(Color(hex: 0x9A9F9B)).allowsHitTesting(false) }
                    }
                    .onSubmit(go)
                    .probeField("composer", text: $text, submit: go)
                    .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in pasteImage() }
                    .onAppear {
                        guard TestDriver.active else { return }
                        Probe.attachers["composer"] = { url in if let d = try? Data(contentsOf: url) { files.wrappedValue.append(Pending(name: url.lastPathComponent, data: d)) } }
                    }
                // The mic stays put while you talk (the box fills, the take goes on); Send joins it.
                Mic(text: $text, dictation: dictation, id: "composer")
                if busy {
                    ProgressView().controlSize(.small).frame(width: 34, height: 34)
                } else if text.nonEmpty != nil || !files.wrappedValue.isEmpty {
                    Button(action: go) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Circle().fill(Ink.green)).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Send").accessibilityLabel("Send").probe("send", action: go)
                }
            }
            .padding(.leading, 10).padding(.trailing, 8)
            .column(height: 50)
            .background(Capsule().fill(Ink.surface).shadow(color: .black.opacity(0.07), radius: 6, y: 6))
            .overlay(Capsule().strokeBorder(Ink.border))
        }
        .padding(.top, 14).padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.title; configuration.icon.font(.system(size: 9, weight: .bold)) }
    }
}

/// A bubble's column: as wide as its widest text (up to what it is offered), with pages and fields
/// stretched to that width, as the design's bubbles size to their words.
struct FitColumn: Layout {
    private struct Fills: LayoutValueKey { static let defaultValue = false }
    /// Take the whole width offered instead of hugging the widest line.
    var fill = false

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let offered = proposal.width ?? .infinity
        if fill, offered.isFinite { return offered }
        let natural = subviews.filter { !$0[Fills.self] }.map { $0.sizeThatFits(ProposedViewSize(width: offered, height: nil)).width }.max()
        return min(offered, natural ?? offered)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal, subviews)
        let h = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        return CGSize(width: w.isFinite ? w : 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for v in subviews {
            let p = ProposedViewSize(width: bounds.width, height: nil)
            v.place(at: CGPoint(x: bounds.minX, y: y), proposal: p)
            y += v.sizeThatFits(p).height
        }
    }

    static func fills<V: View>(_ v: V) -> some View { v.layoutValue(key: Fills.self, value: true) }
}

extension View {
    /// Takes the bubble's width instead of setting it (pages, answer fields).
    func fillsBubble() -> some View { FitColumn.fills(self) }
}


/// A file waiting to go: a thumbnail (or a document icon) with its name and a remove button.
struct PendingChip: View {
    let file: Pending
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if file.isImage, let img = NSImage(data: file.data) { Image(nsImage: img).resizable().scaledToFill() }
                else { Image(systemName: "doc").font(.system(size: 14)).foregroundStyle(Ink.secondary) }
            }
            .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(file.name).font(.ui(12.5)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(file.name)").probe("unattach:\(file.name)", action: remove)
        }
        .padding(4).padding(.trailing, 6)
        .background(Capsule().fill(Ink.chip))
        .accessibilityIdentifier("pending:\(file.name)")
        .probe("pending:\(file.name)")
    }
}

/// Files that went with a message, as thumbnails (images) or named documents; read from the vault.
struct AttachmentStrip: View {
    let paths: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { p in
                let url = Vault.root.appending(path: p)
                Group {
                    if Attachments.isImage(p), let img = NSImage(contentsOf: url) {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: 120, height: 90)
                    } else {
                        Label(Attachments.shownName(p), systemImage: "doc").font(.ui(12.5)).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 36)
                    }
                }
                .background(Ink.chip)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help("Open \((p as NSString).lastPathComponent)")
                .probe("attachment:\(Attachments.shownName(p))")
            }
        }
    }
}
