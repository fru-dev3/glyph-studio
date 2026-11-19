import GlyphVault
import SwiftUI

/// Past chats, the same on every Glyph Chat screen: a clock button top left opens a sheet of the
/// chats this app kept (GlyphVault `ChatLog`), newest first, one line each (when, and its name, or
/// the first few words said). A tap reopens one to carry on; a swipe archives it (moved, never
/// deleted) or names it.
///
/// A chat can be given a name and come back to under it (Fru, 2026-11-14: "I want to give a
/// different name to the different chat sessions and come back to them so that the chat sessions
/// don't just disappear"). The name is a line in the chat's own file, so it is in the vault with
/// everything else and the same on every device that reads it.
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
    /// The chat being named, and the name being typed into the alert.
    @State private var naming: Chat?
    @State private var typed = ""
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
                                // Archive is the full swipe because it is the common one; naming is
                                // deliberate, so it is a tap on the shorter swipe or a long press.
                                Button { archive(c) } label: { Label("Archive", systemImage: "archivebox") }.tint(tint)
                                Button { startNaming(c) } label: { Label("Name", systemImage: "pencil") }
                                    .tint(.gray)
                                    .accessibilityIdentifier("history-name")
                            }
                            .contextMenu {
                                Button("Name this chat", systemImage: "pencil") { startNaming(c) }
                                Button("Archive", systemImage: "archivebox", role: .destructive) { archive(c) }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Past chats")
        }
        .tint(tint)
        .presentationDragIndicator(.visible)
        // The chat you are in is in the list too, marked, because naming the one you are in is the
        // common case: you give it a name once it is about something.
        .onAppear { chats = log.chats() }
        .alert("Name this chat", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("What is it about?", text: $typed).accessibilityIdentifier("history-name-field")
            Button("Save") { saveName() }.accessibilityIdentifier("history-name-save")
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("It keeps this name wherever you read it. Leave it empty to go back to its first words.")
        }
    }

    private func row(_ c: Chat) -> some View {
        let named = c.name?.isEmpty == false
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.when(c.started)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            // A name is shown whole and in the app's own weight: it was chosen, so it is not cut
            // to six words the way an opening line is.
            Text(named ? c.title : Self.words(c.title))
                .font(named ? .body.weight(.semibold) : .body)
                .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if c.id == current {
                Text("This chat").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("history-current")
            }
        }
        .padding(.vertical, 6).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func startNaming(_ c: Chat) {
        typed = c.name ?? ""
        naming = c
    }

    private func saveName() {
        guard let c = naming else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        try? log.rename(c.id, to: name)
        naming = nil
        typed = ""
        withAnimation { chats = log.chats() }
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
