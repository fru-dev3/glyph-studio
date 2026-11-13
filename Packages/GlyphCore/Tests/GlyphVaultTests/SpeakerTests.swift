import Foundation
import Testing
@testable import GlyphVault

/// Who spoke when: a diarizer's turns cleaned, and heard words split by speaker.
@Test func turnsAreRenumberedAndStrayVoicesDropped() {
    let raw = [
        SpeakerTurn(speaker: "7", start: 6, end: 12),
        SpeakerTurn(speaker: "3", start: 0, end: 5.5),
        SpeakerTurn(speaker: "9", start: 12.1, end: 12.2), // a cough: under 2%
        SpeakerTurn(speaker: "3", start: 13, end: 20),
    ]
    let turns = SpeakerTurn.normalized(raw)
    #expect(turns.map(\.speaker) == ["S1", "S2", "S1"])
    #expect(turns.map(\.start) == [0, 6, 13])
}

@Test func aSentenceSplitsWhereTheSpeakerChanges() {
    let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 2.0), SpeakerTurn(speaker: "S2", start: 2.3, end: 5)]
    let words = [
        TimedWord(text: "Is", start: 0.1, end: 0.3), TimedWord(text: " it", start: 0.3, end: 0.5),
        TimedWord(text: " ready?", start: 0.5, end: 1.9),
        TimedWord(text: " Yes,", start: 2.15, end: 2.6), // mostly in the gap and S2's turn
        TimedWord(text: " it", start: 2.7, end: 2.9), TimedWord(text: " is.", start: 2.9, end: 3.2),
    ]
    let heard = Transcript.Segment(start: 0, end: 3.2, text: "Is it ready? Yes, it is.")
    let out = Transcript.split(heard, words: words, turns: turns)
    #expect(out.map(\.speaker) == ["S1", "S2"])
    #expect(out.map(\.text) == ["Is it ready?", "Yes, it is."])
    #expect(out[1].start == 2.15 && out[1].end == 3.2)
    // No turns: as it was. No words: the speaker who overlaps it most.
    #expect(Transcript.split(heard, words: words, turns: []) == [heard])
    #expect(Transcript.split(.init(start: 2.5, end: 4, text: "Sure."), words: [], turns: turns).first?.speaker == "S2")
    // A first word timed from the silence before it still goes to who said it.
    let late = [TimedWord(text: "Four", start: 20.0, end: 21.1), TimedWord(text: " beds.", start: 21.1, end: 21.6)]
    let turns2 = [SpeakerTurn(speaker: "S1", start: 15, end: 20.36), SpeakerTurn(speaker: "S2", start: 20.98, end: 27)]
    #expect(Transcript.split(.init(start: 20, end: 21.6, text: "Four beds."), words: late, turns: turns2).map(\.speaker) == ["S2"])
    // In a gap, the nearest turn.
    #expect(Transcript.split(.init(start: 9, end: 10, text: "Bye."), words: [], turns: turns).first?.speaker == "S2")
}

@Test func speakersHaveNamesAndTalkTime() {
    var t = Transcript(language: "en-US", model: "test", segments: [
        .init(start: 0, end: 4, speaker: "S1", text: "Hello."),
        .init(start: 4, end: 10, speaker: "S2", text: "Hi there."),
        .init(start: 10, end: 12, speaker: "S1", text: "Shall we start?"),
    ])
    #expect(t.name(of: "S2") == "Speaker 2")
    #expect(t.plainText.contains("[00:04] Speaker 2: Hi there."))
    t.speakers["S2"] = "Ken Lee"
    #expect(t.plainText.contains("[00:04] Ken Lee: Hi there."))
    #expect(t.talkTime.map(\.speaker) == ["S1", "S2"])
    #expect(t.talkTime.map(\.seconds) == [6, 6])
}
