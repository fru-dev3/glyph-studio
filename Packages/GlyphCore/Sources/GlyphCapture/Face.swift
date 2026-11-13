import SwiftUI

/// An agent's face (moved from Glyph Bot to GlyphCapture on 2026-10-30, so every Glyph app's agents share it): two white eyes and a mouth on the agent's tile, alive the way a character is
/// (Grok's companions, Duolingo's Lily, Brilliant's Koji): it blinks and breathes at rest, leans in
/// while you type, glances away while it thinks, talks while the reply streams, tilts its head when it
/// waits on you, hops once when something is saved, and droops when a turn fails. Every mood eases
/// back to rest. Tap it for a wink. Drawn here, no images, no emoji. With Reduce Motion the face holds
/// still and only its expression changes. `FaceTile` is the face on its coloured tile, with `ThinkingDots`,
/// `springIn` and `settle` the shared motion of every Glyph chat.
public enum FaceMood: String, CaseIterable, Sendable {
    case rest, listening, thinking, speaking, asking, happy, sad
}

/// What one frame of a face looks like, as fractions of its size.
public struct FacePose: Equatable {
    public var eyeW: CGFloat = 0.12, eyeH: CGFloat = 0.17, eyeGap: CGFloat = 0.34, eyeY: CGFloat = 0.5
    public var gazeX: CGFloat = 0, gazeY: CGFloat = 0
    public var smile: CGFloat = 0.5      // -1 frown .. 1 grin
    public var mouthW: CGFloat = 0.26, mouthY: CGFloat = 0.72
    public var open: CGFloat = 0         // 0 closed .. 1 wide
    public var arcs: CGFloat = 0         // 1: happy ^ ^ eyes
    public var tilt: CGFloat = 0         // degrees
    public var scale: CGFloat = 1

    public static func of(_ mood: FaceMood) -> FacePose {
        var p = FacePose()
        switch mood {
        case .rest: break
        case .listening: p.eyeW = 0.15; p.eyeH = 0.22; p.gazeY = 0.05; p.smile = 0.35; p.mouthW = 0.2; p.scale = 1.04
        case .thinking: p.eyeH = 0.15; p.gazeX = 0.07; p.gazeY = -0.07; p.smile = 0.05; p.mouthW = 0.16
        case .speaking: p.smile = 0.3; p.open = 0.45
        case .asking: p.eyeW = 0.14; p.eyeH = 0.21; p.smile = 0.2; p.mouthW = 0.18; p.tilt = -7
        case .happy: p.arcs = 1; p.smile = 1; p.mouthW = 0.32; p.open = 0.25
        case .sad: p.eyeH = 0.14; p.eyeY = 0.53; p.gazeY = 0.05; p.smile = -0.7; p.mouthW = 0.2; p.mouthY = 0.76
        }
        return p
    }

    public static func mix(_ a: FacePose, _ b: FacePose, _ t: CGFloat) -> FacePose {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return FacePose(eyeW: m(a.eyeW, b.eyeW), eyeH: m(a.eyeH, b.eyeH), eyeGap: m(a.eyeGap, b.eyeGap), eyeY: m(a.eyeY, b.eyeY),
                        gazeX: m(a.gazeX, b.gazeX), gazeY: m(a.gazeY, b.gazeY), smile: m(a.smile, b.smile), mouthW: m(a.mouthW, b.mouthW),
                        mouthY: m(a.mouthY, b.mouthY), open: m(a.open, b.open), arcs: m(a.arcs, b.arcs), tilt: m(a.tilt, b.tilt), scale: m(a.scale, b.scale))
    }

    /// The living part: blinks, breath, the thinking glance, talking, the hop and the wink, at time
    /// `t` seconds, `since` seconds into the current mood. `seed` keeps faces from blinking together.
    public func alive(_ mood: FaceMood, t: Double, since: Double, seed: Int, wink: Double?) -> (FacePose, blink: CGFloat, winkL: CGFloat, hop: CGFloat) {
        var p = self
        // Breathing, slow and small.
        p.scale *= 1 + 0.012 * CGFloat(sin(t * 1.7 + Double(seed)))
        // A blink every 3 to 5.6 s, 0.14 s long, never while happy (the eyes are arcs).
        let period = 3.0 + Double(abs(seed) % 27) / 10
        let phase = (t + Double(abs(seed) % 13) * 0.37).truncatingRemainder(dividingBy: period)
        var blink: CGFloat = phase < 0.14 ? CGFloat(1 - abs(phase - 0.07) / 0.07) : 0
        if mood == .happy { blink = 0 }
        switch mood {
        case .thinking: // glance up-right, then up-left, every 2.4 s
            let g = sin(t * 2 * .pi / 2.4)
            p.gazeX = 0.07 * CGFloat(g)
        case .speaking: // the mouth follows a talking rhythm
            let a = abs(sin(t * 10.5)) * 0.6 + abs(sin(t * 6.3 + 1)) * 0.4
            p.open = 0.15 + 0.75 * CGFloat(a)
        case .listening: // small nods
            p.gazeY += 0.012 * CGFloat(sin(t * 3))
        case .asking: // one head tilt on arrival, then it holds
            p.tilt *= CGFloat(min(1, since / 0.35))
        case .rest: // now and then a look to one side and back (1.4 s every 7 to 9 s), never frozen
            let every = 7.0 + Double(abs(seed) % 21) / 10
            let k = (t + Double(abs(seed) % 17) * 0.53).truncatingRemainder(dividingBy: every) / 1.4
            if k < 1 { p.gazeX += 0.06 * CGFloat(sin(.pi * k)) * (abs(seed) % 2 == 0 ? 1 : -1) }
        default: break
        }
        // Happy: one hop on arrival (0.45 s).
        var hop: CGFloat = 0
        if mood == .happy, since < 0.45 { hop = CGFloat(sin(.pi * since / 0.45)) * 0.09 }
        // A tap: a wink and a little hop (0.5 s).
        var winkL: CGFloat = 0
        if let w = wink, t - w < 0.5, t >= w {
            let k = (t - w) / 0.5
            winkL = CGFloat(sin(.pi * k))
            hop = max(hop, CGFloat(sin(.pi * k)) * 0.06)
            p.smile = max(p.smile, 0.8)
        }
        return (p, blink, winkL, hop)
    }
}

/// The features only (white), drawn in a square; the caller draws the tile behind.
public struct FaceFeatures: View {
    var mood: FaceMood
    var size: CGFloat
    var seed: Int = 0
    var ink: Color = .white
    public init(mood: FaceMood, size: CGFloat, seed: Int = 0, ink: Color = .white) { self.mood = mood; self.size = size; self.seed = seed; self.ink = ink }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var from = FacePose.of(.rest)
    @State private var changed = Date.distantPast
    @State private var wink: Date?

    /// Tests and screenshots can ask for Reduce Motion: STUDIO_REDUCE_MOTION=1.
    public static let forceStill = ProcessInfo.processInfo.environment["STUDIO_REDUCE_MOTION"] == "1"

    public var body: some View {
        Group {
            if reduceMotion || Self.forceStill {
                FaceDrawing(pose: .of(mood), blink: 0, winkL: 0, hop: 0, size: size, ink: ink)
                    .animation(.easeOut(duration: 0.2), value: mood)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
                    let now = ctx.date.timeIntervalSinceReferenceDate
                    let since = ctx.date.timeIntervalSince(changed)
                    let k = CGFloat(min(1, max(0, since / 0.24)))
                    let eased = 1 - (1 - k) * (1 - k) // ease-out, 240 ms
                    let base = FacePose.mix(from, .of(mood), eased)
                    let live = base.alive(mood, t: now, since: since, seed: seed, wink: wink?.timeIntervalSinceReferenceDate)
                    FaceDrawing(pose: live.0, blink: live.blink, winkL: live.winkL, hop: live.hop, size: size, ink: ink)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { if !reduceMotion && !Self.forceStill { wink = .now } }
        .onChange(of: mood) { old, _ in
            // Start the change from where the face was (close enough: the old mood's pose).
            from = .of(old); changed = .now
        }
        .accessibilityHidden(true)
    }
}

/// One still frame.
public struct FaceDrawing: View {
    let pose: FacePose
    let blink: CGFloat, winkL: CGFloat, hop: CGFloat
    let size: CGFloat
    let ink: Color
    public init(pose: FacePose, blink: CGFloat, winkL: CGFloat, hop: CGFloat, size: CGFloat, ink: Color) { self.pose = pose; self.blink = blink; self.winkL = winkL; self.hop = hop; self.size = size; self.ink = ink }

    public var body: some View {
        Canvas { ctx, s in
            let w = s.width
            ctx.translateBy(x: w / 2, y: w / 2 - hop * w)
            ctx.rotate(by: .degrees(pose.tilt))
            ctx.scaleBy(x: pose.scale, y: pose.scale)
            ctx.translateBy(x: -w / 2, y: -w / 2)
            let cx = w / 2 + pose.gazeX * w, ey = pose.eyeY * w + pose.gazeY * w
            let line = max(1.4, w * 0.07)
            for (i, side) in [-1.0, 1.0].enumerated() {
                let x = cx + CGFloat(side) * pose.eyeGap * w / 2
                let shut = i == 0 ? max(blink, winkL) : blink
                if pose.arcs > 0.5 {
                    // ^ eyes
                    var p = Path()
                    p.move(to: CGPoint(x: x - pose.eyeW * w * 0.7, y: ey + pose.eyeH * w * 0.15))
                    p.addQuadCurve(to: CGPoint(x: x + pose.eyeW * w * 0.7, y: ey + pose.eyeH * w * 0.15),
                                   control: CGPoint(x: x, y: ey - pose.eyeH * w * 0.55))
                    ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
                } else {
                    let h = max(line * 0.9, pose.eyeH * w * (1 - shut))
                    let r = CGRect(x: x - pose.eyeW * w / 2, y: ey - h / 2, width: pose.eyeW * w, height: h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2), with: .color(ink))
                }
            }
            // The mouth: an open rounded shape when talking or laughing, a curve otherwise.
            let mx = cx, my = pose.mouthY * w + pose.gazeY * w * 0.5, mw = pose.mouthW * w
            if pose.open > 0.08 {
                let h = pose.open * w * 0.16 + line * 0.6
                var p = Path()
                p.move(to: CGPoint(x: mx - mw / 2, y: my - h * 0.2))
                p.addQuadCurve(to: CGPoint(x: mx + mw / 2, y: my - h * 0.2), control: CGPoint(x: mx, y: my - h * 0.2 - pose.smile * w * 0.04))
                p.addQuadCurve(to: CGPoint(x: mx - mw / 2, y: my - h * 0.2), control: CGPoint(x: mx, y: my + h * 1.6))
                p.closeSubpath()
                ctx.fill(p, with: .color(ink))
            } else {
                var p = Path()
                p.move(to: CGPoint(x: mx - mw / 2, y: my))
                p.addQuadCurve(to: CGPoint(x: mx + mw / 2, y: my), control: CGPoint(x: mx, y: my + pose.smile * w * 0.16))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

extension FaceMood {
    /// A stable number per agent, so faces in a list don't blink in step.
    public static func seed(_ s: String) -> Int { s.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 997 } }
}

// MARK: The chat's living pieces (2026-10-30: "lively, not dead, both on my side and on the side of the agent")

/// An agent's character: its coloured tile with the living face. Working, it bobs on its job; done, it
/// nods with a spring and smiles, then settles back to rest (blinking, glancing about); a question tilts
/// its head; a failure droops it. With Reduce Motion only the expression changes. Named, it is one
/// accessibility element ("Time, working"), identifier `agent-face`, value the mood it shows
/// ("working" while thinking), so tests can see the turn; unnamed, VoiceOver skips it.
public struct FaceTile: View {
    let color: Color, size: CGFloat, mood: FaceMood, seed: Int, name: String?
    public init(color: Color, size: CGFloat, mood: FaceMood, seed: Int = 0, name: String? = nil) {
        self.color = color; self.size = size; self.mood = mood; self.seed = seed; self.name = name
        _shown = State(initialValue: mood)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: FaceMood
    @State private var nods = 0
    private var still: Bool { reduceMotion || FaceFeatures.forceStill }

    public var body: some View {
        let working = shown == .thinking && !still
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(color)
            .frame(width: size, height: size)
            .overlay { FaceFeatures(mood: shown, size: size, seed: seed) }
            // Working: a small walk in place, the head bobbing and turning. Paused (not removed) at rest, so
            // the face keeps its state; the offset eases back to zero with the mood's spring.
            .modifier(Bob(on: working, size: size, seed: seed))
            .rotationEffect(.degrees(still || shown != .asking ? 0 : -8), anchor: .bottom)
            .offset(y: still || shown != .sad ? 0 : size * 0.05)
            .keyframeAnimator(initialValue: 1.0, trigger: nods) { v, s in v.scaleEffect(s, anchor: .bottom) } keyframes: { _ in
                SpringKeyframe(1.16, duration: 0.16, spring: .snappy)
                SpringKeyframe(0.95, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
            .animation(still ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.58), value: shown)
            .task(id: mood) {
                shown = mood
                guard mood == .happy else { return }
                if !still { nods += 1 }
                do { try await Task.sleep(for: .seconds(1.8)); shown = .rest } catch {}  // the smile, then back to rest
            }
            .accessibilityElement()
            .accessibilityLabel(name ?? "")
            .accessibilityValue(shown == .thinking ? "working" : shown.rawValue)
            .accessibilityIdentifier("agent-face")
            .accessibilityHidden(name == nil)
    }
}

private struct Bob: ViewModifier {
    let on: Bool, size: CGFloat, seed: Int
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !on)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate + Double(seed % 10)
            content
                .offset(x: on ? size * 0.05 * sin(t * 4) : 0, y: on ? -abs(sin(t * 8)) * size * 0.07 : 0)
                .rotationEffect(.degrees(on ? 4 * sin(t * 4) : 0), anchor: .bottom)
        }
    }
}

/// Three dots rising in turn: "working on it" for an agent, "still talking" on your side. Small and soft;
/// with Reduce Motion they only fade in turn, and in still screenshots they hold.
public struct ThinkingDots: View {
    var color: Color, size: CGFloat
    public init(color: Color = .secondary, size: CGFloat = 6) { self.color = color; self.size = size }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: FaceFeatures.forceStill)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.65) {
                ForEach(0..<3, id: \.self) { i in
                    let k = FaceFeatures.forceStill ? 0.5 : max(0, sin(t * 2 * .pi / 1.1 - Double(i) * 0.9))
                    Circle().fill(color).frame(width: size, height: size)
                        .opacity(0.4 + 0.6 * k)
                        .offset(y: reduceMotion ? 0 : -k * size * 0.7)
                }
            }
        }
        .frame(height: size * 2)
        .accessibilityHidden(true)
    }
}

public extension View {
    /// A chat bubble's entrance: it springs up from its corner (`.leading` for the agent, `.trailing` for
    /// you). With Reduce Motion it fades in.
    func springIn(from edge: HorizontalEdge) -> some View { modifier(SpringIn(edge: edge)) }
    /// A small pop each time `value` changes: an answer landing where "working" was.
    func settle<T: Equatable & Sendable>(on value: T) -> some View { modifier(Settle(value: value)) }
}

private struct SpringIn: ViewModifier {
    let edge: HorizontalEdge
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let still = reduceMotion || FaceFeatures.forceStill
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || still ? 1 : 0.82, anchor: edge == .leading ? .bottomLeading : .bottomTrailing)
            .offset(y: shown || still ? 0 : 12)
            .onAppear { withAnimation(still ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.6)) { shown = true } }
    }
}

private struct Settle<T: Equatable & Sendable>: ViewModifier {
    let value: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion || FaceFeatures.forceStill { content } else {
            content.keyframeAnimator(initialValue: 1.0, trigger: value) { v, s in v.scaleEffect(s, anchor: .leading) } keyframes: { _ in
                SpringKeyframe(1.045, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
        }
    }
}
