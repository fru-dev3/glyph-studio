import Foundation
import FoundationModels
import GlyphVault

// Fru's preferences, kept by Glyph Omega under ## Preferences in build/compass.md (Fru, 2026-10-30: "regardless of
// which app is working, it can always look at my preferences and then know when and how to use them"). Softer than
// goals. Every agent gets the ones in its scopes in its instructions; the Claude /understand route takes the same
// lines in its `preferences` field (`Hub.preferenceText(for:)`). Read from the vault through the hub (GET /omega),
// or the vault itself on a Mac; nothing is written in the code.

extension GlyphAgent {
    /// What every agent reads, and each agent's own scopes on top (Omega, the keeper, reads them all).
    static let everyone: Set<String> = ["agents", "writing", "general"]
    static let ownScopes: [String: Set<String>] = [
        "time": ["schedule", "health"], "well": ["food", "health"], "crm": ["people"], "jot": ["design"], "travel": ["travel", "schedule"],
    ]

    /// The preferences this agent follows, from all of them.
    public func scoped(_ prefs: [OmegaCompassEntry]) -> [OmegaCompassEntry] {
        id == "omega" ? prefs : prefs.filter { Self.everyone.union(Self.ownScopes[id] ?? []).contains($0.scope) }
    }

    /// Its instructions with the preferences it follows, and how to offer a new one.
    public func instructions(with prefs: [OmegaCompassEntry]) -> String {
        let mine = scoped(prefs)
        var s = instructions
        if !mine.isEmpty {
            s += "\n\nThe person's preferences (softer than goals: follow them where they fit; never a reason to act):\n" + OmegaFormat.preferenceLines(mine)
        }
        return s + "\nWhen they state a new preference in passing (I hate long labels), call propose_preference: it waits for their yes."
    }

    /// Its own tools and the one every agent has: propose_preference.
    public func toolkit(_ hub: Hub, _ ledger: Ledger) -> [any Tool] {
        tools(hub, ledger) + [ProposePreference(hub: hub, ledger: ledger)]
    }
}

/// Any agent: a preference said in passing, written as a proposal ("Save as a preference?"), kept only on Fru's yes in Omega.
public struct ProposePreference: Tool {
    public let name = "propose_preference"
    public let description = "Offer to save a preference the person stated in passing (I hate long labels). It waits for their yes."
    @Generable public struct Arguments {
        @Guide(description: "The preference, short, in their words, like Short labels.") public var text: String
        @Guide(description: "What it is about", .anyOf(OmegaFormat.preferenceScopes)) public var scope: String
    }
    let hub: Hub, ledger: Ledger
    public func call(arguments a: Arguments) async throws -> String {
        let d = await hub.addPreference(a.text, scope: a.scope, proposed: true); await ledger.add(d); return d.line
    }
}

/// The last preferences read, for a few minutes, so a turn doesn't fetch the vault for each agent.
actor PreferenceCache {
    static let shared = PreferenceCache()
    var kept: (at: Date, key: String, prefs: [OmegaCompassEntry])?
    func get(_ key: String, _ load: () async -> [OmegaCompassEntry]?) async -> [OmegaCompassEntry] {
        if let k = kept, k.key == key, Date().timeIntervalSince(k.at) < 300 { return k.prefs }
        guard let p = await load() else { return kept?.prefs ?? [] }
        kept = (Date(), key, p)
        return p
    }
    func clear() { kept = nil }
}

extension Hub {
    /// The preferences agents follow (neither proposed nor archived); empty when the hub can't be reached.
    public func preferences() async -> [OmegaCompassEntry] {
        await PreferenceCache.shared.get(vault?.path ?? base?.absoluteString ?? "") {
            guard let (files, _) = await omegaFiles() else { return nil }
            return OmegaFormat.preferences(files["build/compass.md"] ?? "")
        }
    }

    /// The lines for an agent ("time", "native" reads every scope), for /understand's `preferences` field.
    public func preferenceText(for agent: String) async -> String {
        let all = await preferences()
        return OmegaFormat.preferenceLines(GlyphAgent.named(agent)?.scoped(all) ?? all)
    }

    /// A preference added to Omega (a proposal waits for a yes there). Undo puts the file back.
    public func addPreference(_ said: String, scope: String = "", strong: Bool = false, proposed: Bool = false) async -> Done {
        let p = OmegaFormat.parsePreference(said)
        let words = Self.cap(OmegaFormat.clean(p.words))
        let done = await omegaEdit { files, _ in
            guard !words.isEmpty else { return .failure(.init("No preference heard", "Which preference?")) }
            let rel = "build/compass.md"
            let (text, _) = OmegaFormat.addPreference(files[rel] ?? "", words: words, scope: scope.isEmpty ? p.scope : scope, strong: strong,
                                                      proposed: proposed, from: device)
            return .success((rel, text, Done(agent: "omega", line: proposed ? "Save as a preference? \(words)" : "Preference saved in Omega: \(words)",
                                              title: words, ok: true, review: proposed, link: URL(string: "glyph-omega://preferences"))))
        }
        await PreferenceCache.shared.clear()
        return done
    }

    /// Puts away the one preference the words name. Never deleted.
    public func archivePreference(_ said: String) async -> Done {
        let done = await omegaEdit { files, _ in
            let rel = "build/compass.md", text = files[rel] ?? ""
            let all = OmegaFormat.compass(text).preferences.filter { !$0.archived }
            func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }) }
            let want = words(said)
            let best = all.map { ($0, words($0.title).intersection(want).count) }.filter { $0.1 > 0 }
            let top = best.map(\.1).max() ?? 0
            let hits = best.filter { $0.1 == top }.map(\.0)
            guard hits.count == 1, let p = hits.first else {
                return .failure(hits.isEmpty ? .init("No preference in Omega like \(said)", "No such preference")
                                             : .init("Which one: \(hits.prefix(3).map(\.title).joined(separator: " or "))?", "Which preference?"))
            }
            return .success((rel, OmegaFormat.archivePreference(text, id: p.id),
                             Done(agent: "omega", line: "Preference archived in Omega: \(p.title)", title: p.title, ok: true, link: URL(string: "glyph-omega://preferences"))))
        }
        await PreferenceCache.shared.clear()
        return done
    }
}
