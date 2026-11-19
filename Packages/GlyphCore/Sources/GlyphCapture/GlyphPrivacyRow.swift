import GlyphVault
import SwiftUI

/// The one switch for what the Glyph apps count, in every app's settings.
///
/// An app that reports anything has to say so where the person can see it and turn it off, and
/// the sentence has to be the same in every app or it is not a promise, it is marketing. What is
/// counted is an event name and the app it came from; what is never counted is anything you
/// logged. See `GlyphMetrics`.
///
/// It draws nothing at all in a build with no key, because there is nothing to turn off then.
public struct GlyphPrivacyRow: View {
    @State private var on = GlyphMetrics.isOn

    public init() {}

    public var body: some View {
        if GlyphMetrics.hasKey {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Count how much I use it", isOn: $on)
                    .onChange(of: on) { _, now in GlyphMetrics.isOn = now }
                    .accessibilityIdentifier("settings.analytics")
                Text("An event name and which app it came from, nothing else. Never what you logged, never a name, a number or a word of it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
