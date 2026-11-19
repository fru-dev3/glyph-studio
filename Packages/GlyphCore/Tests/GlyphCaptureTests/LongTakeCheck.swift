import Foundation
import Testing

@testable import GlyphCapture

/// Does a take longer than one recognizer's segment keep every word?
///
/// Fru reported a short transcript twice (2026-11-08, 2026-11-14 after a hike). The engine hands
/// over from one recognizer to the next mid-take, and the microphone is not read while that
/// handover happens, so the suspect is that whatever is said in the gap reaches nobody.
///
/// This plays a recording of 40 numbered sentences through the real model instead of the
/// microphone, which is what `GLYPH_DICTATION_AUDIO` is for, and then asks which numbers came
/// back. A gap at a handover shows up as a run of missing numbers in the middle, not as a short
/// tail. Off unless GLYPH_LONG_TAKE names the file, because it runs for about three minutes.
@Suite("A take longer than one segment")
struct LongTakeCheck {
    @Test(.timeLimit(.minutes(20)))
    func everyNumberedSentenceComesBack() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLYPH_LONG_TAKE"], !path.isEmpty else { return }
        setenv("GLYPH_DICTATION_AUDIO", path, 1)
        defer { unsetenv("GLYPH_DICTATION_AUDIO") }

        let heard: String = await withCheckedContinuation { k in
            Task { @MainActor in
                let d = LiveDictation()
                var sent = false
                d.onFinal = { words in if !sent { sent = true; k.resume(returning: words) } }
                d.start()
                // The recording plays at about the speed it was said; give it room and then stop.
                // Waits for the words to STOP growing rather than for a clock. The recording is
                // fed in 0.1s chunks with a 0.1s sleep between them plus the model's own work, so
                // it plays slower than it was said: the first run waited 200s for 173s of audio,
                // cut it off around 117s of content, and that looked exactly like a lost tail.
                var last = -1, still = 0
                while still < 20 {
                    try? await Task.sleep(for: .seconds(5))
                    let n = d.text.count
                    still = n == last ? still + 5 : 0
                    last = n
                }
                if !sent { d.stop() }
                try? await Task.sleep(for: .seconds(15))
                if !sent { sent = true; k.resume(returning: d.text) }
            }
        }

        // Which of the forty came back, and where the gaps are.
        var found = Set<Int>()
        let words = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                     "eighteen", "nineteen", "twenty"]
        let low = heard.lowercased()
        for n in 1...40 {
            var forms = ["number \(n).", "number \(n) ", "number \(n),"]
            if n < words.count { forms += ["number \(words[n])"] }
            if n > 20, n < 30 { forms += ["number twenty \(words[n - 20])", "number twenty-\(words[n - 20])"] }
            if n > 30, n < 40 { forms += ["number thirty \(words[n - 30])", "number thirty-\(words[n - 30])"] }
            if n == 30 { forms += ["number thirty"] }
            if n == 40 { forms += ["number forty"] }
            if forms.contains(where: low.contains) { found.insert(n) }
        }
        let missing = (1...40).filter { !found.contains($0) }
        print("LONG-TAKE words=\(heard.split(whereSeparator: \.isWhitespace).count) found=\(found.count)/40 missing=\(missing)")
        #expect(found.count >= 36, "numbers missing from the middle of a long take: \(missing)")
    }
}
