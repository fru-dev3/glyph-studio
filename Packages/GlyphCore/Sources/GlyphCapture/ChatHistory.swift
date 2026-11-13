import GlyphVault
import SwiftUI

/// Past chats, the same on every Glyph Chat screen: a clock button top left opens a sheet of the
/// chats this app kept (GlyphVault `ChatLog`), newest first, one line each (when, and the first few
/// words said). A tap reopens one to carry on; a swipe archives it (moved, never deleted).
///
///     ChatHistoryButton { showHistory = true }
///     .sheet(isPresented: $showHistory) { ChatHistorySheet(log: log, current: chatID, tint: .green) { chat in reopen(chat) } }
///
/// Accessibility identifiers: `chat-history`, `history-row`, `history-empty`.
public struct ChatHistoryButton: View {
    var action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Past chats").accessibilityIdentifier("chat-history")
    }
}

public struct ChatHistorySheet: View {
    let log: ChatLog
    let current: String?
    let tint: Color
    let open: (Chat) -> Void
    @State private var chats: [Chat] = []
    @Environment(\.dismiss) private var dismiss

    public init(log: ChatLog, current: String? = nil, tint: Color, open: @escaping (Chat) -> Void) {
        self.log = log; self.current = current; self.tint = tint; self.open = open
    }

    public var body: some View {
        NavigationStack {
            Group {
                if chats.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 40, weight: .regular)).foregroundStyle(tint)
                        Text("No past chats yet").font(.title3).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("history-empty")
                } else {
                    List(chats) { c in
                        Button { open(c); dismiss() } label: { row(c) }
                            .accessibilityIdentifier("history-row")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { archive(c) } label: { Label("Archive", systemImage: "archivebox") }.tint(tint)
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Past chats")
        }
        .tint(tint)
        .presentationDragIndicator(.visible)
        .onAppear { chats = log.chats().filter { $0.id != current } }
    }

    private func row(_ c: Chat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.when(c.started)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Text(Self.words(c.title)).font(.body).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func archive(_ c: Chat) {
        try? log.archive(c.id)
        withAnimation { chats.removeAll { $0.id == c.id } }
    }

    /// "9:12 AM" today, "Yesterday", "Mon" this week, "Oct 3" before.
    static func when(_ d: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(d) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: d, to: now).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The first few words, so a row never wraps.
    static func words(_ s: String) -> String {
        let w = s.split(whereSeparator: \.isWhitespace)
        return w.prefix(6).joined(separator: " ") + (w.count > 6 ? "…" : "")
    }
}
