import Foundation
import Testing
@testable import GlyphCapture
import GlyphVault

/// The real models on a made-up two-person conversation (RecordTests/make-two-voices.sh).
/// Opt in, since it downloads the speaker models once:
///   RecordTests/make-two-voices.sh /tmp/two && GLYPH_TWO_VOICES=/tmp/two swift test --filter twoVoices
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLYPH_TWO_VOICES"] != nil))
func twoVoicesAreTwoSpeakers() async throws {
    let base = ProcessInfo.processInfo.environment["GLYPH_TWO_VOICES"]!
    let audio = URL(filePath: base + ".m4a")
    let truth = try String(contentsOfFile: base + ".truth.txt", encoding: .utf8)
        .split(separator: "\n").map { $0.split(separator: " ") }
        .map { (voice: String($0[0]), start: Double($0[1])!, end: Double($0[2])!) }

    let clock = ContinuousClock.now
    let turns = try await Diarizer().turns(audio)
    let diarized = ContinuousClock.now - clock
    print("turns (\(diarized)):", turns.map { "\($0.speaker) \($0.start)-\($0.end)" })
    #expect(Set(turns.map(\.speaker)).count == 2)

    let transcript = try await Transcriber().transcribe(audio, turns: turns)
    print(transcript.plainText)
    // Every voice's turns heard as one speaker, the two voices as two speakers.
    var heard: [String: Set<String>] = [:]
    for t in truth {
        let overlap = Dictionary(grouping: transcript.segments) { $0.speaker }
            .mapValues { $0.reduce(0) { $0 + max(0, min(t.end, $1.end) - max(t.start, $1.start)) } }
        heard[t.voice, default: []].insert(overlap.max { $0.value < $1.value }!.key)
    }
    #expect(heard.values.allSatisfy { $0.count == 1 }, "\(heard)")
    #expect(Set(heard.values.flatMap { $0 }).count == 2, "\(heard)")
    let peaks = try Waveform.peaks(of: audio, count: 200)
    #expect(peaks.count == 200 && peaks.max() == 1)
}
