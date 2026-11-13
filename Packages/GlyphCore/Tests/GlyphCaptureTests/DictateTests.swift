import Foundation
import Testing
@testable import GlyphCapture

/// The shared dictate control's engine, through its injected transcript (no microphone or model).
@MainActor @Suite(.serialized)
struct DictateTests {
    @Test func injectedWordsStreamAndFinish() async throws {
        UserDefaults.standard.set("feeling pretty low tired after a bad night", forKey: "glyphDictationText")
        defer { UserDefaults.standard.removeObject(forKey: "glyphDictationText") }
        let d = LiveDictation()
        var live: [String] = [], final: String?
        d.onText = { live.append($0) }
        d.onFinal = { final = $0 }
        d.start()
        #expect(d.on)
        for _ in 0..<60 where d.text != "feeling pretty low tired after a bad night" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(d.text == "feeling pretty low tired after a bad night")
        #expect(live.count >= 3 && live.first == "feeling")
        d.stop()
        #expect(!d.on && final == "feeling pretty low tired after a bad night")
    }

    @Test func stoppingEarlyStillGivesTheWords() async {
        UserDefaults.standard.set("type four this morning", forKey: "glyphDictationText")
        defer { UserDefaults.standard.removeObject(forKey: "glyphDictationText") }
        let d = LiveDictation()
        var final: String?
        d.onFinal = { final = $0 }
        d.start(); d.stop()
        #expect(final == "type four this morning")
    }
}

extension DictateTests {
    @Test func pauseHoldsTheWordsAndResumeGoesOn() async throws {
        UserDefaults.standard.set("one two three four five six seven eight", forKey: "glyphDictationText")
        defer { UserDefaults.standard.removeObject(forKey: "glyphDictationText") }
        let d = LiveDictation()
        d.start()
        for _ in 0..<40 where d.text.split(separator: " ").count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        d.pause()
        #expect(d.paused)
        let held = d.text
        try await Task.sleep(for: .milliseconds(300))
        #expect(d.text == held)
        d.resume()
        for _ in 0..<60 where d.text != "one two three four five six seven eight" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(d.text == "one two three four five six seven eight" && !d.paused)
        d.stop()
    }
}

/// The real on-device model, hearing a spoken recording made with `say` (no injected words).
/// Opt in: GLYPH_REAL_SPEECH=1 swift test --filter RealSpeechTests (the model may download first).
@MainActor @Suite(.serialized)
struct RealSpeechTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLYPH_REAL_SPEECH"] == "1"))
    func aRecordingBecomesText() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "glyph-real-speech.m4a")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=aac", "this is a glyph well talk test"]
        try say.run(); say.waitUntilExit()
        setenv("GLYPH_DICTATION_AUDIO", file.path, 1)
        defer { unsetenv("GLYPH_DICTATION_AUDIO") }
        let d = LiveDictation()
        var final: String?
        d.onFinal = { final = $0 }
        d.start()
        for _ in 0..<300 where d.text.split(separator: " ").count < 5 { try await Task.sleep(for: .milliseconds(100)) }
        print("route: \(d.route) heard so far: \(d.text) problem: \(d.problem ?? "none")")
        d.stop()
        for _ in 0..<100 where final == nil { try await Task.sleep(for: .milliseconds(100)) }
        print("final: \(final ?? "nothing")")
        #expect(final?.lowercased().contains("test") == true)
    }
}
