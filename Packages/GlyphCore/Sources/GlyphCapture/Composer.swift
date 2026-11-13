import SwiftUI
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// The family's one input row, at the foot of every Glyph phone screen (Fru, 2026-11-09:
/// "standardize on one of this, right? I like the one where you have the text input, because I
/// think it's cleaner, it's more compact"). It is Glyph Jot's composer, and it replaces
/// `CaptureTrio` everywhere, including the screens where capture is the job.
///
/// One capsule with its controls inside it, not three things in a row (Fru, the same day, showing
/// ChatGPT's and Gemini's: "see how the plus button is inside of the design model... on the left
/// side is a plus button. On the right side is the microphone. And the middle is the text"): a `+`
/// on the left for whatever the screen offers to attach, the field in the middle, and a mic on the
/// right that becomes a send arrow the moment there is something to send. Both ends are filled
/// discs in the app's green, so the two buttons Fru presses most are the prominent things in the
/// bar (2026-11-09, on the white glyphs they replaced: "make it a feel green so it really stands
/// out, because it's a prominent button that I will have to click off very often. Same thing on
/// the left, and then the plus button on the right. I'd rather have it feel and prominent green").
/// Red while recording, and red means nothing else.
///
/// **The trade, stated so nobody rediscovers it:** on a capture-first screen the big mic was the
/// point, and a 34pt disc is a smaller target than the trio's 80pt one. Fru chose consistency
/// anyway.
///
/// `onSend` gets the words and whether they were spoken, so a screen that records its source
/// (Glyph Wealth logs "voice" against "typed") still can.
///
/// **One definition, and an app only ever changes what is in it** (Fru, 2026-11-09: "I hope you
/// have just one model template that you use for all the different apps... you're not changing the
/// design, you're not changing the dimensions, you're not changing it over and over again. The only
/// thing you change is the content of it... the same design, the same layout, the same pixel, the
/// same placement that just repeats throughout every single page"). An app passes its tint, its
/// placeholder and its actions. It does not pass a size, a spacing, a corner radius or a placement:
/// a parameter that would change the geometry is the signal that the template is about to fork, and
/// the answer is content instead. The one thing an app declares is how much of its own furniture
/// sits below the row, and it declares that once where it draws that furniture, through
/// `glyphComposerRoom`, not at each composer.
///
/// Accessibility identifiers: chat-attach, chat-field, chat-mic (or `micIdentifier`), chat-send.
public struct GlyphComposer: View {
    let tint: Color
    let placeholder: String
    /// The `+`: what this screen offers to attach (CRM's card scanner, Time's camera). The plus is
    /// always drawn, whatever an app passes: it is part of what the bar is made of, not content
    /// (Fru, 2026-11-09, having caught it missing in two apps: "the left side needs the icon
    /// there"). nil only means this screen has named no action of its own, and the plus then opens
    /// the family's own photo-or-file choice.
    let attach: (() -> Void)?
    let attachLabel: String
    /// What the mic does, when this screen's mic is not dictation: Glyph Jot's opens the recording
    /// screen, because a jot keeps its audio. nil dictates into the field, which is the default and
    /// what every other screen wants. The bar is the same bar either way: an app passes its action,
    /// never a size or a second drawing of the mic.
    let mic: (() -> Void)?
    /// What a check taps to talk. The family's name is "chat-mic"; an app whose suite already taps
    /// its own ("today.talk" in Glyph Wealth) passes that instead.
    let micIdentifier: String
    /// The colour the row's own ground blends into, so a grouped page does not show a lighter band
    /// behind it. `.clear` for a composer drawn inline, inside something that already has a ground.
    let page: Color
    let onSend: (String, Bool) async -> Void

    @State private var draft = ""
    /// This row's take, owned here rather than inside the mic, because sending has to end it and
    /// wait for the model's last words. See `send()`.
    @State private var dictation = LiveDictation()
    /// Send was pressed while the model was still writing the end of a take: the arrow waits
    /// rather than sending half a sentence.
    @State private var waiting = false
    /// The screen's own work on what was sent is still running: a hub round trip takes seconds,
    /// and without this the tap had nothing to show for itself (Fru, 2026-11-11, of Glyph Well:
    /// "when I type and hit submit it takes a long time to process and it's not obvious to me
    /// something is actually happening"). `onSend` is awaited, so the spinner lasts exactly as
    /// long as the work does and never guesses.
    @State private var working = false
    /// Waiting on the words, or on the work: either way the arrow is a spinner and does not take
    /// a second tap.
    private var busy: Bool { waiting || working }
    /// Any of what is in the field was spoken, so a screen that records its source ("voice"
    /// against "typed") is told the truth. It was always told "typed".
    @State private var spoke = false
    /// Listening: the mic stays a mic (a stop) even though the words it is writing would otherwise
    /// swap it for the send arrow.
    @State private var recording = false
    /// The family's photo-or-file choice, for a screen that named no attach action of its own.
    @State private var choosing = false
    @State private var taking = false
    /// Why the mic is not hearing anything, shown over the bar. Without it the mic is a control
    /// that can fail in silence: iOS refuses the microphone, or the speech model is still coming
    /// down, and all a tap does is nothing.
    @State private var micProblem: String?
    @FocusState private var field: Bool
    @Environment(\.glyphComposerRoom) private var room

    /// The gap Fru wants above and below the composer: "All spacing must be even." It is the
    /// drawn gap, not the padding, so the paddings are set against it. Above, the scroll content
    /// already contributes about 3pt of its own, measured at 12.9pt when this padding was 10.
    nonisolated public static let air: CGFloat = 16

    /// What a finger needs, and what every control in this bar is tapped at, whatever size its
    /// disc is drawn. 44 is Apple's own minimum and the number Glyph Wealth's largest-text check
    /// has been asking for since the bar replaced the trio.
    nonisolated public static let touch: CGFloat = 44
    /// The disc as it is drawn. Smaller than the target on purpose: the bar stays compact.
    nonisolated static let disc: CGFloat = 34

    public init(tint: Color = .officeGreen,
                placeholder: String,
                attach: (() -> Void)? = nil,
                attachLabel: String = "Attach",
                micIdentifier: String = "chat-mic",
                page: Color = .talkPage,
                mic: (() -> Void)? = nil,
                onSend: @escaping @MainActor (String, Bool) async -> Void) {
        self.tint = tint; self.placeholder = placeholder
        self.attach = attach; self.attachLabel = attachLabel; self.micIdentifier = micIdentifier
        self.page = page; self.mic = mic; self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 6) {
            if let micProblem {
                #if os(iOS)
                // A refused microphone is the one problem a tap can fix, and iOS never asks a
                // second time, so the sentence alone was a dead end: it named a screen and left
                // the person to find it. The button goes there (Fru, 2026-11-10: "I can't use the
                // button to record, like it says setting is off. You should be, it should enable
                // that"). The app cannot grant itself the microphone; this is the nearest thing.
                if micProblem == LiveDictation.micDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Turn on the microphone")
                            .font(.footnote.weight(.semibold)).foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-mic-settings")
                }
                #endif
                Text(micProblem).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                    .accessibilityIdentifier("chat-mic-problem")
            }
            bar
        }
        .padding(.top, GlyphComposer.air - 3).padding(.bottom, 6 + room)
        .frame(maxWidth: .infinity)
        .background(page.opacity(0.96).ignoresSafeArea())
    }

    /// The plus. A screen with its own action gets a plain button; otherwise a menu: take a photo
    /// (only where there is a camera) or choose a file or photo.
    @ViewBuilder private var plus: some View {
        let disc = plusDisc
        if let attach {
            Button { attach() } label: { disc }
                .buttonStyle(.plain).accessibilityLabel(attachLabel).accessibilityIdentifier("chat-attach")
        } else {
            #if os(iOS)
            Menu {
                if CameraPicker.isAvailable { Button("Take a photo", systemImage: "camera") { taking = true } }
                Button("Choose a photo", systemImage: "photo") { choosing = true }
            } label: { disc }
                .buttonStyle(.plain).accessibilityLabel("Attach a photo or a file").accessibilityIdentifier("chat-attach")
            #else
            Button { choosing = true } label: { disc }
                .buttonStyle(.plain).accessibilityLabel("Attach a photo or a file").accessibilityIdentifier("chat-attach")
            #endif
        }
    }

    private var plusDisc: some View {
        // The same disc the mic and the send arrow draw, so all three ends match.
        Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.disc, height: Self.disc)
            .background(tint, in: Circle())
            .frame(width: Self.touch, height: Self.touch)
            .contentShape(Circle())
    }

    /// The bar itself: the plus, the field, and the mic or the send arrow.
    private var bar: some View {
        HStack(spacing: 10) {
            if !recording {
                plus
            }
            // The field grows with what is in it, to five lines, then scrolls (Fru, 2026-11-12:
            // "that input box could expand to show me all the content I'm typing, not just stay
            // static in one location"). A vertical field is also a multi-line one, so a long
            // sentence can be read back, selected and copied before it is sent, which a
            // single-line field scrolled sideways past the end of.
            //
            // `submitLabel(.send)` and `onSubmit` still send: on a vertical field the Return key
            // becomes the send key rather than a newline, which is what every other Glyph
            // composer does and what the send arrow beside it does.
            TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(.secondary), axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($field).submitLabel(.send)
                .onSubmit { send() }
                .accessibilityIdentifier("chat-field")
                // A way out of the keyboard, drawn once for the family. Send is the only other
                // key that dismisses it, and send is not what someone who typed nothing wants, so
                // the only way out was to find a scroll view that happened to dismiss on a drag
                // (Fru, 2026-11-11: "I struggle to make the keyboard disappear"). The bar itself
                // is pinned to the keyboard, so this sits with it on every screen.
                #if os(iOS)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { field = false }
                            .font(.system(size: 16, weight: .semibold)).tint(tint)
                            .accessibilityIdentifier("chat-keyboard-done")
                    }
                }
                #endif
            if draft.trimmingCharacters(in: .whitespaces).isEmpty || recording {
                // The mic sits in the bar, not on a disc beside it. No second, round voice button:
                // Fru has no realtime mode, so there is nothing for it to open.
                //
                // It writes into the field as it hears, rather than sending what it heard (Fru,
                // 2026-11-09: "a transcription of the text I'm recording being put into the text
                // input form... And then when I stop, you put it into the text box. And then I can
                // record and add some more, maybe make some changes before submitting"). So the
                // words stay, the pause and the waveform appear in the bar beside it, and nothing
                // leaves until the send arrow is pressed. While it listens the `+` steps aside, so
                // the bar neither grows nor changes height.
                DictateButton(text: $draft, tint: tint, circle: Self.disc, recording: $recording,
                              micIdentifier: micIdentifier, problem: $micProblem, instead: mic,
                              live: dictation)
            } else {
                Button { send() } label: {
                    ZStack {
                        Circle().fill(tint).frame(width: Self.disc, height: Self.disc)
                        // Waiting on the last words of a take. The tap has to show that it landed,
                        // or the wait reads as the dead button it is meant to fix.
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: Self.touch, height: Self.touch)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat-send")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .onChange(of: recording) { _, on in if on { spoke = true } }
        .background(Color(white: 0.11), in: Capsule())
        .padding(.horizontal, 16)
        // One choice, defined here and nowhere else, for every screen that named no action of its
        // own. What comes back is the file's path, sent the way a typed sentence is sent: these
        // screens all hand `onSend` to an agent that reads the vault by path.
        // ponytail: a path as the sentence is the smallest honest wiring. A screen that wants a
        // photo understood rather than referenced passes its own `attach` (CRM's scanner, Time's
        // camera) and never reaches this.
        #if os(iOS)
        // A photo taken is saved as a file and its path sent, exactly as a chosen file is.
        .fullScreenCover(isPresented: $taking) {
            CameraPicker { image, _ in
                taking = false
                guard let data = image?.jpegData(compressionQuality: 0.9) else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                guard (try? data.write(to: url)) != nil else { return }
                Task { @MainActor in working = true; await onSend(url.path, false); working = false }
            }.ignoresSafeArea()
        }
        #endif
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let words = urls.map(\.path).joined(separator: "\n")
            Task { @MainActor in working = true; await onSend(words, false); working = false }
        }
    }

    /// Sending ends the take and waits for the words that have not arrived yet.
    ///
    /// Stopping the microphone does not stop the model: it goes on turning the last seconds into
    /// text for a moment afterwards (`finishing`), and those words land in the field when they
    /// come. Sending into that gap did two wrong things at once: it sent without the tail, and the
    /// arriving words then refilled the field, so the submit looked as though it had not happened
    /// and the next tap logged the same thing a second time (Fru, 2026-11-10: "When I record here
    /// and I hit submit, it's not actually submitting correctly. I have to do it 2 or 3 times...
    /// we have to make sure it submits so I'm not losing my content"). One tap, the whole
    /// sentence, once.
    private func send() {
        if dictation.on { dictation.stop() }
        guard dictation.finishing else { return deliver() }
        waiting = true
        Task { @MainActor in
            // Bounded: a model that never finishes must not keep his words.
            let deadline = ContinuousClock.now + .seconds(3)
            while dictation.finishing, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard waiting else { return }
            waiting = false
            deliver()
        }
    }

    /// The field empties the moment the words leave it, so nothing is typed twice, and the arrow
    /// stays a spinner until the screen's own work on them is done.
    private func deliver() {
        let w = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = spoke
        draft = ""
        spoke = false
        guard !w.isEmpty else { return }
        working = true
        Task { @MainActor in
            await onSend(w, said)
            working = false
        }
    }
}

public extension Color {
    /// #008000, the brand's office green, in both appearances. The artboards draw it on black.
    static let officeGreen = Color(red: 0, green: 128 / 255, blue: 0)
}

/// How much of an app's own furniture sits below the composer, such as Glyph CRM's footer bar. An
/// app sets this once, where it draws that furniture, and every composer under it leaves the room.
/// It is here rather than on `GlyphComposer` so no screen passes the template a dimension.
///
/// Two safe-area insets on views a NavigationStack apart do not compose: an inset set out at the
/// root never reaches the list, which is how the footer came to draw over the composer. The
/// composer reserves the room, and the app's bar is laid into what it left.
public struct GlyphComposerRoom: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var glyphComposerRoom: CGFloat {
        get { self[GlyphComposerRoom.self] }
        set { self[GlyphComposerRoom.self] = newValue }
    }
}
