#if os(macOS)
import AppKit
import SwiftUI

/// The top of every Glyph Mac app's sidebar: the app's icon, its name, and the gear.
///
/// Fru, 2026-10-31, with Glyph Jot and Glyph CRM side by side: "Why is one app branded like this? But yet, Glyph
/// CRM doesn't have the logo to the top left side... have a kind of a consistent layout and view with that left
/// side bar and then the mid, and then everything else so that it's very, very quick and easy to just tell that,
/// oh, this is a Glyph family of apps... You cannot be making them so inconsistent."
///
/// So: change the block here, never per app, the way `GlyphChat` holds the chat screen for all of them.
///
/// One line, and no tagline. The icon and the name already say which app you are in; a line of prose under
/// something that explains itself is the text density Fru keeps striking out, and in a 200pt column anything
/// longer than two words wraps and turns a one-line header into three (Fru on Glyph Well's wrapped tagline,
/// 2026-10-31: "this is too much text. come on. can you do good design?").
///
/// The gear runs whatever the app gives it, and is deliberately not a `SettingsLink`: that opens the Settings
/// scene in a floating window, and configuration is a place you go to, not a thing that appears over you
/// (Fru, 2026-10-31: "I don't want pop-up config pages... All these stupid pop-ups you're doing"). Each app
/// shows its own settings in its content pane, like any other screen.
///
/// It goes above the sidebar's own list, so the list scrolls under it and no row ever sits above the brand:
/// ```swift
/// List(selection: $place) { ... }
///     .safeAreaInset(edge: .top, spacing: 0) {
///         GlyphSidebarHeader(name: "Glyph CRM") { place = .settings }
///     }
/// ```
public struct GlyphSidebarHeader: View {
    private let name: String
    private let action: () -> Void

    /// - Parameters:
    ///   - name: the app as the family names it, "Glyph CRM". The same string as its `FamilyApp.name`.
    ///   - action: what the gear does. Show settings in the app's own content pane, never a window or a sheet.
    public init(name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 30, height: 30)
            Text(name).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: action) {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("settings")
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
    }
}
#endif
