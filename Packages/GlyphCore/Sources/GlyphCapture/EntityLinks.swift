import GlyphVault
import SwiftUI

/// Turning the entities named in a piece of text into links you can tap.
///
/// Fru, 2026-11-14, reading a chat answer on his phone: "You're not highlighting proper nouns and
/// hashtags and people and things in the CRM with the links so I can interact with them. You
/// should do that both on the desktop and on the mobile."
///
/// `EntityScan` finds them; this draws them. Drawn once here so an answer, a note and a dictation
/// mark the same words the same way, and so the thing a tap opens is decided in one place.
public enum EntityLinks {
    /// The scheme a tap opens. Glyph CRM holds the pages, so a tap goes there, and every app that
    /// shows a link hands it the same URL: `glyph-crm://entity/people/john-ryan`.
    public static let scheme = "glyph-crm"

    /// Where a tap on this entity goes.
    public static func url(_ id: String) -> URL? {
        URL(string: "\(scheme)://entity/" + id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
    }

    /// The entity id in a link this made, or nil for any other URL. An app uses it to answer its
    /// own `onOpenURL` without parsing the string twice.
    public static func entity(in url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "entity" else { return nil }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path.removingPercentEncoding ?? path
    }

    /// The text with each entity's first mention turned into a tappable link.
    ///
    /// First mention only: 796 entities over a real notebook marked 202 times, and the three most
    /// marked were entities whose names are words he writes constantly. One link to a page is a
    /// way in; sixty is a page that is hard to read.
    ///
    /// Nothing is added and nothing is reworded. The characters are the answer's own, so a reader
    /// sees what was said and an underline under the parts that go somewhere.
    public static func attributed(_ text: String, scan: EntityScan?, tint: Color? = nil) -> AttributedString {
        var out = AttributedString(text)
        guard let scan else { return out }
        for hit in scan.firstMentions(in: text) {
            guard let link = url(hit.id) else { continue }
            // By character count, because a String.Index does not carry across to an
            // AttributedString: both are built from the same characters, so the counts line up.
            let from = text.distance(from: text.startIndex, to: hit.range.lowerBound)
            let length = text.distance(from: hit.range.lowerBound, to: hit.range.upperBound)
            let start = out.index(out.startIndex, offsetByCharacters: from)
            let end = out.index(start, offsetByCharacters: length)
            let range = start..<end
            out[range].link = link
            // The name keeps its weight and takes the app's colour, so a marked name reads as part
            // of the sentence rather than as a button dropped into it.
            if let tint { out[range].foregroundColor = tint }
            out[range].underlineStyle = .single
        }
        return out
    }
}
