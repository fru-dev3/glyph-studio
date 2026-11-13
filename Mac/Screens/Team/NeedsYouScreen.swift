import SwiftUI

/// Everything the team is waiting on, one card each, answered in place. A card leaves once its
/// answer has run.
struct NeedsYouScreen: View {
    @Environment(AppModel.self) private var model
    private var state: TeamState { TeamState.shared }

    var body: some View {
        let asks = state.asks
        let who = Set(asks.map(\.domain)).count
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Needs you").font(.ui(15, .semibold))
                    Text(who == 0 ? "Nobody is waiting on you" : "\(who) teammate\(who == 1 ? " is" : "s are") waiting on a yes or an answer")
                        .font(.ui(12)).foregroundStyle(Color(hex: 0x7A7F7B))
                }
                Spacer()
            }
            .padding(.horizontal, 22).frame(height: 62)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }

            if asks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Ink.green)
                    Text("Nothing is waiting on you.").font(.ui(15, .medium))
                    Text("When a teammate needs a yes or an answer, it shows up here.").font(.ui(13)).foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(asks) { a in ApprovalCard(ask: a, label: label(a), sources: false) }
                    }
                    .column()
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// "Estate · 7 min ago", "Career · a question, not a verdict".
    private func label(_ a: Ask) -> String {
        let name = model.teammate(a.domain)?.name ?? a.domain.capitalized
        if a.style == .question { return "\(name) · a question, not a verdict" }
        guard a.since > 0 else { return name }
        return "\(name) · \(Self.ago(Date(timeIntervalSince1970: a.since / 1000)))"
    }

    static func ago(_ d: Date, now: Date = AppClock.now) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return TeamActivity.stamp(d, now: now)
    }
}
