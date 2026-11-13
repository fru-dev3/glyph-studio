import Foundation

/// A reply as it should read in a bubble: Markdown inline (bold, italic, code, links), bullets and
/// headings by line, and paragraphs reflowed: a model's hard wraps and leading spaces ("  May to
/// September...") join back into one paragraph; a blank line still breaks one.
enum ReplyText {
    static func reflow(_ s: String) -> String {
        var out: [String] = []
        var para = ""
        func flush() { if !para.isEmpty { out.append(para); para = "" } }
        for raw in s.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); if out.last != "" { out.append("") }; continue }
            let isBullet = t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ")
            let isNumbered = t.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
            if t.hasPrefix("#") {
                flush(); let h = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces); if !h.isEmpty { out.append("**\(h)**") }
            } else if isBullet {
                flush(); para = String(repeating: "    ", count: min(indent / 2, 3)) + "•  " + t.dropFirst(2)
            } else if isNumbered {
                flush(); para = t
            } else if t.hasPrefix("|") || t.hasPrefix("```") {
                flush(); out.append(t)
            } else {
                para = para.isEmpty ? t : para + " " + t
            }
        }
        flush()
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func attributed(_ s: String) -> AttributedString {
        let md = reflow(s)
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    }
}
