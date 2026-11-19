import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How much the Glyph apps are used, and nothing else.
///
/// Fru, 2026-11-15: "Can you instrument all the apps with PostHog? I have that in my vault, and
/// you can get the key there." It is the same project his websites report to, so the apps and the
/// sites answer one question together.
///
/// What goes out is an event name and the app it came from. What never goes out: anything he
/// logged, any name, place, amount, file, transcript or tag, and anything that identifies the
/// person. The id is a random one made on this device the first time, kept in UserDefaults, and
/// it is the only thing tying two events together.
///
/// The key is not in the code. It comes from the build (Info.plist `PostHogKey`, written from a
/// machine-local env file the way `GlyphVaultURL` already is) or from `GLYPH_POSTHOG_KEY` in the
/// environment. Without a key, nothing is sent and nothing is kept: a build anyone else makes
/// from the public source reports nowhere.
public enum GlyphMetrics {
    /// Off switch, honoured everywhere and before anything is built. Settings writes this.
    public static let offKey = "glyph.analytics.off"
    public static var isOn: Bool {
        get { !UserDefaults.standard.bool(forKey: offKey) && key != nil }
        set { UserDefaults.standard.set(!newValue, forKey: offKey) }
    }

    /// Whether this build can report at all, for a Settings row that tells the truth.
    public static var hasKey: Bool { key != nil }

    static var key: String? {
        if let k = ProcessInfo.processInfo.environment["GLYPH_POSTHOG_KEY"], k.hasPrefix("phc_") { return k }
        if let k = Bundle.main.object(forInfoDictionaryKey: "PostHogKey") as? String, k.hasPrefix("phc_") { return k }
        return nil
    }

    /// This device, as a random id and nothing more. Made once, kept here, never sent anywhere else.
    static var person: String {
        let k = "glyph.analytics.id"
        if let id = UserDefaults.standard.string(forKey: k) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: k)
        return id
    }

    static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return "iphone"
        #endif
    }

    /// The app was opened. Call it once, when the first window or screen appears.
    public static func opened(_ app: String) {
        send("app_opened", ["app": app])
    }

    /// Something was used: the feature's name, in the family's own words ("tags", "chat",
    /// "record"). Never what it was used on.
    public static func used(_ feature: String, app: String) {
        send("feature_used", ["feature": feature, "app": app])
    }

    /// Fire and forget. Anything that fails is dropped: this is never allowed to slow an app down
    /// or to queue up on disk, because what is being counted is not worth keeping.
    static func send(_ event: String, _ properties: [String: String]) {
        guard isOn, let key, let url = URL(string: "https://us.i.posthog.com/i/v0/e/") else { return }
        var props = properties
        props["$lib"] = "glyph"
        props["platform"] = platform
        props["version"] = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let body: [String: Any] = ["api_key": key, "event": event, "distinct_id": person,
                                   "properties": props,
                                   "timestamp": ISO8601DateFormatter().string(from: .now)]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// What a check calls instead of the network: the body that would be sent, so a test can read
    /// it without anything leaving the machine.
    public static func bodyForCheck(_ event: String, _ properties: [String: String]) -> [String: Any] {
        var props = properties
        props["$lib"] = "glyph"
        props["platform"] = platform
        return ["event": event, "properties": props]
    }
}
