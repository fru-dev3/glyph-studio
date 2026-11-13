import SwiftUI

/// The family's one progress ring: a thick office-green arc on a faint track, brighter with a soft
/// glow at its leading end, over a dark disc.
///
/// Lifted out of Glyph Time's `RunningVisual` on 2026-11-09, where it was the running timer's ring
/// and the idle screen had nothing. Fru's governing rule that day: "one constant model... you just
/// want to have one constant model that is interacting so that you're not changing the design,
/// you're not changing the dimensions". So the ring owns its own diameter, its line width, its
/// track and its glow, and a caller passes only how full it is and what stands in the middle.
/// Nobody hands it a size.
public struct GlyphRing<Center: View>: View {
    private let progress: CGFloat
    private let tint: Color
    private let dim: Bool
    private let center: Center

    /// - Parameters:
    ///   - progress: 0 to 1, how much of the arc is drawn.
    ///   - tint: the app's green.
    ///   - dim: paused, or waiting to start: the arc holds back and the glow goes out.
    ///   - center: what stands inside, the subject of the ring.
    public init(progress: CGFloat, tint: Color = .officeGreen, dim: Bool = false,
                @ViewBuilder center: () -> Center) {
        self.progress = max(0, min(1, progress))
        self.tint = tint
        self.dim = dim
        self.center = center()
    }

    // The ring's own geometry. Never a parameter.
    private static var diameter: CGFloat { 206 }
    private static var width: CGFloat { 9 }

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    /// The brighter cut at the arc's leading end.
    private var lead: Color { dark ? Color(red: 0.55, green: 1.0, blue: 0.66) : Color(red: 0.10, green: 0.68, blue: 0.14) }

    public var body: some View {
        let d = Self.diameter, w = Self.width
        let arc = d - w
        let g = dim ? tint.opacity(0.45) : tint
        let tip = dim ? tint.opacity(0.5) : lead
        return ZStack {
            if dark { Circle().fill(tint.opacity(dim ? 0.07 : 0.12)).frame(width: d * 0.92).blur(radius: 30) }
            Circle().fill(dark ? Color(white: 0.07) : Color(white: 0.96)).frame(width: arc - w)
            ZStack {
                Circle().stroke(tint.opacity(dark ? 0.14 : 0.11), lineWidth: w)
                // Full: one solid ring. The gradient's bright end is for an arc that is still
                // growing; at 1 it wraps back past 12 and leaves a pale patch beside the start cap.
                Circle().trim(from: 0, to: progress)
                    .stroke(progress >= 1
                            ? AnyShapeStyle(g)
                            : AnyShapeStyle(AngularGradient(stops: [.init(color: g.opacity(dim ? 1 : 0.9), location: 0),
                                                                    .init(color: g, location: max(0.01, progress * 0.7)),
                                                                    .init(color: tip, location: max(0.02, progress))], center: .center)),
                            style: StrokeStyle(lineWidth: w, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // The start cap solid, so the gradient's seam never shows at 12 o'clock.
                if progress > 0 { Circle().fill(g.opacity(dim ? 1 : 0.9)).frame(width: w, height: w).offset(y: -arc / 2) }
                if !dim && progress > 0 && progress < 1 {
                    // The leading end: a soft glow and a brighter cap.
                    let a = (Double(progress) * 360 - 90) * .pi / 180
                    let pt = CGSize(width: cos(a) * arc / 2, height: sin(a) * arc / 2)
                    Circle().fill(tip.opacity(dark ? 0.55 : 0.18)).frame(width: w * 2.4, height: w * 2.4).blur(radius: dark ? 9 : 6).offset(pt)
                    Circle().fill(tip).frame(width: w, height: w).offset(pt)
                }
            }
            .frame(width: arc, height: arc)
            center.padding(.horizontal, d * 0.13)
        }
        .frame(width: d, height: d)
    }
}
