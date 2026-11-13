import SwiftUI
import Testing
@testable import GlyphCapture

/// The composer's mic writes into the field rather than sending what it heard, so the thing most
/// likely to be subtly wrong is whether a second take appends or replaces the first.
@MainActor
struct DictateAppendTests {
    @Test func takesAppendRatherThanReplace() {
        // One take, nothing in the field before it.
        #expect(DictateButton.joined(before: "", take: "call Ken") == "call Ken")
        // A second take, after the first take's words are in the field.
        #expect(DictateButton.joined(before: "call Ken", take: "about the roof") == "call Ken about the roof")
        // Edited by hand between takes: the edit is what is kept, not the first take.
        #expect(DictateButton.joined(before: "Call Ken Lee", take: "tomorrow") == "Call Ken Lee tomorrow")
        // A take that heard nothing leaves the field as it was.
        #expect(DictateButton.joined(before: "call Ken", take: "   ") == "call Ken")
        #expect(DictateButton.joined(before: "  ", take: "call Ken") == "call Ken")
    }

    /// The model writes the end of a take after the microphone is off. Those late words must not
    /// land in a field that has been sent and cleared in the meantime: that put the sentence back,
    /// which reads as a submit that did not happen, and the next tap logged it twice.
    @Test func lateWordsNeverRefillAFieldThatWasSent() {
        // While the take runs, each change replaces what this take wrote last.
        #expect(DictateButton.fill(field: "", wrote: nil, before: "", take: "fufu") == "fufu")
        #expect(DictateButton.fill(field: "fufu", wrote: "fufu", before: "", take: "fufu corn") == "fufu corn")
        // Sent: the field was cleared by somebody else, so the take's last words are dropped.
        #expect(DictateButton.fill(field: "", wrote: "fufu corn", before: "", take: "fufu corn and plantain") == nil)
        // Typed into mid-take: the typing stands, the take does not overwrite it.
        #expect(DictateButton.fill(field: "my own words", wrote: "fufu", before: "", take: "fufu corn") == nil)
        // A take that starts after all that writes again (`wrote` is cleared when a take starts).
        #expect(DictateButton.fill(field: "", wrote: nil, before: "", take: "plantain") == "plantain")
    }

    /// A pause is inside one take: the words so far stay and the next words continue them, so the
    /// field never loses what was said before the pause.
    @Test func pauseKeepsTheWordsSoFar() async throws {
        // The injected transcript is read from defaults, which is how the UI checks set it.
        UserDefaults.standard.set("call Ken about the roof", forKey: "glyphDictationText")
        defer { UserDefaults.standard.removeObject(forKey: "glyphDictationText") }
        #expect(LiveDictation.injected != nil)
        let d = LiveDictation()
        d.start()
        // Wait for words rather than for a stretch of clock: the injected take streams on the main
        // actor, which the rest of the suite shares, so a fixed sleep passes alone and fails beside
        // a test that holds the actor (this one did, on 2026-11-09).
        try await until("nothing was heard before the pause") { !d.text.isEmpty }
        d.pause()
        let heardBeforePause = d.text
        #expect(d.on && d.paused, "a pause is not a stop")
        try await Task.sleep(for: .milliseconds(80))
        #expect(d.text == heardBeforePause, "it kept listening through the pause")
        d.resume()
        try await until("resuming heard nothing more") { d.text.count > heardBeforePause.count }
        #expect(d.text.hasPrefix(heardBeforePause), "resuming replaced the words instead of continuing them")
        d.stop()
    }

    /// Polls until the condition holds, up to `within`. Fails with `why` if it never does.
    private func until(_ why: String, within: Duration = .seconds(5), _ holds: () -> Bool) async throws {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if holds() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Bool(false), "\(why) (waited \(within))")
    }
}
