import Foundation

/// The one vault address every Glyph app on a phone shares, kept in the App Group `group.dev.fru.glyph`.
/// Pair once in Glyph Native and they all reach it; disconnect there and they all stop.
/// An app reads it with `GlyphHub.address(fallbackKey:)`, passing the key its own Settings used before
/// ("vaultURL", "inboxURL", "inbox"), so nothing breaks before that app is rebuilt to ask for it.
public enum GlyphHub {
    public static let group = "group.dev.fru.glyph"
    static let key = "sharedHubURL"

    static func suite(_ name: String) -> UserDefaults { UserDefaults(suiteName: name) ?? .standard }

    static let offKey = "sharedHubOff"

    /// The one answer every app uses. A shared address wins; after a Disconnect in Glyph Native there is
    /// none (nil, never the app's old or built-in address); if Glyph Native never paired on this phone,
    /// `fallback` is what the app used before, so nothing breaks until then.
    public static func resolve(suiteName: String = group, fallback: () -> String?) -> String? {
        let s = suite(suiteName)
        let shared = s.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !shared.isEmpty { return shared }
        if s.bool(forKey: offKey) { return nil }
        let t = fallback()?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? nil : t
    }

    /// True when a shared address is in force (an app shows its own address field read-only then).
    public static func isShared(suiteName: String = group) -> Bool {
        !(suite(suiteName).string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
    }

    /// The shared address, else the app's own old setting (until a Disconnect), else nil.
    public static func address(fallbackKey: String, suiteName: String = group, fallback: UserDefaults = .standard) -> String? {
        resolve(suiteName: suiteName) { fallback.string(forKey: fallbackKey) }
    }

    /// Pairing succeeded: every app on this phone now reaches `address`.
    public static func setAddress(_ address: String, suiteName: String = group) {
        suite(suiteName).removeObject(forKey: offKey)
        suite(suiteName).set(address.trimmingCharacters(in: .whitespaces), forKey: key)
    }

    /// Disconnect: every app has no address until Glyph Native pairs again.
    public static func clearAddress(suiteName: String = group) {
        suite(suiteName).removeObject(forKey: key)
        suite(suiteName).set(true, forKey: offKey)
    }
}
