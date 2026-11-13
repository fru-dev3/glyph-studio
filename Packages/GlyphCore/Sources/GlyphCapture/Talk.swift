import SwiftUI

/// The big talk button, the same in every Glyph app on the phone (Glyph Jot's): a green disc in a
/// pale ring, the mic, "Tap to talk" under it. Tap and talk: only a waveform shows while you
/// speak (no live words), the disc turns red with a stop square; tap again and the final words go
/// to `onFinal` for the app to make sense of and save. On-device (`LiveDictation`).
///
///     TodayView().talkButton { words in log(words) }     // pinned bottom center, above the tab bar
///     TalkButton { words in log(words) }                  // the button alone, to place yourself
///
/// Tests inject the words with `GLYPH_DICTATION_TEXT`. Accessibility identifier: `glyph.talk`.
public struct TalkButton: View {
    @State private var dictation = LiveDictation()
    @State private var levels: [Double] = Array(repeating: 0.04, count: 36)
    var tint: Color
    var caption: String
    var onTalking: ((Bool) -> Void)?
    var onFinal: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `onTalking` hears when you start and stop (a chat's face listens while you talk).
    public init(tint: Color = Color(red: 0, green: 128 / 255, blue: 0), caption: String = "Tap to talk", onTalking: ((Bool) -> Void)? = nil, onFinal: @escaping (String) -> Void) {
        self.tint = tint; self.caption = caption; self.onTalking = onTalking; self.onFinal = onFinal
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let p = dictation.problem {
                Text(p).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            if dictation.on { waveform }
            controls
            Text(dictation.paused ? "Paused" : dictation.on ? "Tap to stop" : dictation.finishing ? "One moment" : caption)
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if LiveDictation.audioFile != nil || ProcessInfo.processInfo.environment["GLYPH_DICTATION_DEBUG"] != nil {  // device checks only
                Text("\(dictation.route) | on=\(dictation.on) finishing=\(dictation.finishing) problem=\(dictation.problem ?? "none") text=\(dictation.text)").font(.caption2).foregroundStyle(.clear).frame(height: 1).accessibilityIdentifier("glyph.route")
            }
        }
        .animation(.snappy, value: dictation.on)
        .onChange(of: dictation.level) { _, l in
            levels.removeFirst()
            levels.append(max(0.04, min(1, l)))
        }
        .onChange(of: dictation.on) { _, on in
            if on { levels = Array(repeating: 0.04, count: levels.count) }
            onTalking?(on || dictation.finishing)
        }
        .onChange(of: dictation.finishing) { _, f in onTalking?(dictation.on || f) }
        // The words once the model has finished, not the moment you tap stop.
        .onAppear { let f = onFinal; dictation.onFinal = { f($0) }; dictation.selfTestIfAsked() }
    }

    var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * Double(i) / Double(levels.count)))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(4, levels[i] * 56))
            }
        }
        .frame(height: 56)
        .opacity(dictation.paused ? 0.3 : 1)
        .padding(.horizontal, 24)
        .animation(reduceMotion ? .linear(duration: 0.08) : .spring(response: 0.16, dampingFraction: 0.55), value: levels)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// Pause (while talking) left of the disc, as in Glyph Jot; the disc talks and stops.
    var controls: some View {
        HStack(spacing: 36) {
            if dictation.on { pauseButton }
            disc
            if dictation.on { Color.clear.frame(width: 60, height: 60) }  // keeps Stop centered
        }
    }

    var pauseButton: some View {
        Button { dictation.paused ? dictation.resume() : dictation.pause() } label: {
            Image(systemName: dictation.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 60, height: 60)
                .background(Color.primary.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.paused ? "Resume" : "Pause")
        .accessibilityIdentifier("glyph.pause")
        .transition(.scale.combined(with: .opacity))
    }

    var disc: some View {
        let color = dictation.on ? Color.red : tint
        return Button { dictation.toggle() } label: {
            ZStack {
                // While you talk: the pale ring swells with your voice on a spring, and a soft ripple leaves it.
                if dictation.on && !reduceMotion { ripple(color) }
                Circle().fill(color.opacity(0.14)).frame(width: 104, height: 104)
                    .scaleEffect(dictation.on && !reduceMotion ? 1 + 0.22 * (levels.last ?? 0) : 1)
                    .animation(.spring(response: 0.22, dampingFraction: 0.5), value: levels.last)
                Circle().fill(color).frame(width: 80, height: 80).shadow(color: color.opacity(0.35), radius: 12, y: 6)
                if dictation.on {
                    RoundedRectangle(cornerRadius: 7).fill(.white).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(Squish(still: reduceMotion))
        .sensoryFeedback(.impact(weight: .medium), trigger: dictation.on)
        .accessibilityLabel(dictation.on ? "Stop talking" : "Talk")
        .accessibilityIdentifier("glyph.talk")
    }
}

extension TalkButton {
    /// One soft ring leaving the button every 1.6 s while you talk.
    func ripple(_ color: Color) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let k = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Circle().stroke(color.opacity(0.35 * (1 - k)), lineWidth: 2)
                .frame(width: 104, height: 104).scaleEffect(1 + 0.3 * k)
        }
        .allowsHitTesting(false)
    }
}

/// A press that gives a little, then springs back.
struct Squish: ButtonStyle {
    let still: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !still ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

public extension View {
    /// The family's composer pinned at the foot of the page (above a tab bar), as in Glyph Jot: a
    /// `+`, a field, and a mic that becomes send. Scroll views inside (also inside a
    /// NavigationStack) get a bottom margin so their last rows scroll clear of it, and it rides up
    /// with the keyboard, because it is now the thing the keyboard is for. `page` is the colour the
    /// row's ground uses: a grouped or tinted page passes its own, or a lighter band shows behind it.
    func talkButton(tint: Color = Color(red: 0, green: 128 / 255, blue: 0),
                    placeholder: String = "Say or type what happened",
                    page: Color = .talkPage,
                    attach: (() -> Void)? = nil,
                    onFinal: @escaping @MainActor (String) async -> Void) -> some View {
        modifier(TalkButtonPlacement(tint: tint, placeholder: placeholder, page: page, attach: attach, onFinal: onFinal))
    }
}

/// How tall the pinned composer is, for the scroll margin: the 44pt row with 4 above and below, 10
/// on top and 6 under. It was 52 while the field was one fixed line; a vertical field (which is
/// what lets a long sentence be read back and copied) is a few points taller, and the margin has
/// to be the bar's real height or the last row of a page parks under it for good. Measured in the
/// Simulator by Well's capture test, which scrolls to the end and compares the two frames: at 52
/// the last row ended 5pt inside the bar.
let composerHeight: CGFloat = (GlyphComposer.air - 3) + 60 + 6

struct TalkButtonPlacement: ViewModifier {
    let tint: Color, placeholder: String, page: Color, attach: (() -> Void)?, onFinal: @MainActor (String) async -> Void

    func body(content: Content) -> some View {
        content
            // `contentMargins` for the room: this modifier is applied outside the page's
            // NavigationStack, and an inset attached out there never reaches the ScrollView in,
            // but contentMargins does carry down to it and keeps the last row clear.
            .contentMargins(.bottom, composerHeight, for: .scrollContent)
            // A safeAreaInset for the placement, not an overlay. An overlay is laid out in its
            // content's bounds and so stays where it is when the keyboard comes up: the keyboard
            // then covers the very field you are typing into (Fru, 2026-11-09, on Glyph Well's
            // Meds screen: "Why is the keyboard covering the input text? It's kind of silly").
            // The safe area shrinks for the keyboard, so an inset rides up with it, which is how
            // Glyph Time's composer has always behaved. The bar is the thing the keyboard is for.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlyphComposer(tint: tint, placeholder: placeholder, attach: attach, page: page) { words, _ in await onFinal(words) }
            }
    }
}

public extension Color {
    /// The system background, the talk button's default fade.
    static var talkPage: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
