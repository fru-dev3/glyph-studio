import Foundation

/// Where a Glyph Mac app's chat sends what you said, so the family's one chat screen works on the
/// Mac the way it works on the iPhone.
///
/// The iPhone has an app group and Glyph Native shares the hub address through it (`GlyphHub`).
/// A Mac app has no such group, and each app that wanted a chat grew its own address field in its
/// own settings instead (Glyph Wealth's "Chat http://"). There is already one place where the
/// address is written down on a Mac: `~/.config/glyph/env`, the file Glyph Native and the install
/// scripts write, and the Mac apps already read for everything else.
///
/// Fru, 2026-11-15: "The input model that you use to get input from the user is a consistent model
/// you're reusing across all of them."
public enum GlyphMacHub {
    /// The env file, overridable for a check (`GLYPH_NATIVE_ENV`, the same name Glyph Native uses).
    static var file: URL {
        URL(filePath: ProcessInfo.processInfo.environment["GLYPH_NATIVE_ENV"]
            ?? (NSHomeDirectory() + "/.config/glyph/env"))
    }

    /// `GLYPH_VAULT_URL` as written in that file, or nil when there is none. An app shows chat
    /// answers as away rather than guessing an address.
    public static var address: String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("GLYPH_VAULT_URL=") else { continue }
            var v = String(l.dropFirst("GLYPH_VAULT_URL=".count)).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
            return v.hasPrefix("http") ? v : nil
        }
        return nil
    }

    public static var url: URL? { address.flatMap { URL(string: $0) } }
}
