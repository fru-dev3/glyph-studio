import Foundation

/// One stretch of one voice, from a diarizer: `S1` from 12.4 to 15.9 seconds. Speakers are
/// numbered in the order they first speak; a diarizer knows voices, never names.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    /// Cleans a diarizer's raw turns: sorted, voices with less than `minimumShare` of the
    /// talking dropped (a cough, a laugh, a stray echo), the rest renamed `S1`, `S2`... in the
    /// order they first speak.
    public static func normalized(_ raw: [SpeakerTurn], minimumShare: Double = 0.02) -> [SpeakerTurn] {
        let turns = raw.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var talk: [String: Double] = [:]
        for t in turns { talk[t.speaker, default: 0] += t.end - t.start }
        let total = talk.values.reduce(0, +)
        let kept = turns.filter { total == 0 || talk[$0.speaker, default: 0] / total >= minimumShare }
        var names: [String: String] = [:]
        return kept.map { t in
            if names[t.speaker] == nil { names[t.speaker] = "S\(names.count + 1)" }
            return SpeakerTurn(speaker: names[t.speaker]!, start: t.start, end: t.end)
        }
    }

    /// The speaker of the turn that overlaps `start...end` most; in a gap, the nearest turn's.
    static func speaker(from start: Double, to end: Double, in turns: [SpeakerTurn]) -> String {
        var best = "", bestOverlap = 0.0, nearest = "", nearestGap = Double.infinity
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap { best = t.speaker; bestOverlap = overlap }
            let gap = max(t.start - end, start - t.end, 0)
            if gap < nearestGap { nearest = t.speaker; nearestGap = gap }
        }
        return bestOverlap > 0 ? best : nearest
    }
}

/// A word (or a run of words) the transcriber heard, on the recording's clock. `text` keeps
/// its own spacing, so words join back with nothing between them.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

extension Transcript {
    /// One heard sentence as segments, split wherever the speaker changes. Each word goes to
    /// the turn it overlaps most (in a gap, the nearest). With no words, the whole segment goes
    /// to one speaker; with no turns, it comes back as it was.
    public static func split(_ segment: Segment, words: [TimedWord], turns: [SpeakerTurn]) -> [Segment] {
        guard !turns.isEmpty else { return [segment] }
        guard !words.isEmpty else {
            var s = segment
            s.speaker = SpeakerTurn.speaker(from: segment.start, to: segment.end, in: turns)
            return [s]
        }
        var out: [Segment] = []
        for w in words {
            // A sentence's first word is timed from the silence before it (it took "Four" from
            // the next speaker): judge a word by its last 0.6 seconds at most.
            let who = SpeakerTurn.speaker(from: max(w.start, w.end - 0.6), to: w.end, in: turns)
            if let last = out.last, last.speaker == who {
                out[out.count - 1].text += w.text
                out[out.count - 1].end = max(last.end, w.end)
            } else {
                out.append(Segment(start: w.start, end: w.end, speaker: who, text: w.text))
            }
        }
        return out.compactMap { s in
            var s = s
            s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.text.isEmpty ? nil : s
        }
    }

    /// What to call a speaker: the name you gave, else "Speaker 2" for `S2`, else the id.
    public func name(of speaker: String) -> String {
        if let name = speakers[speaker], !name.isEmpty { return name }
        if speaker.hasPrefix("S"), let n = Int(speaker.dropFirst()) { return "Speaker \(n)" }
        return speaker
    }

    /// Every speaker in the order they first speak, with how long they talked.
    public var talkTime: [(speaker: String, seconds: Double)] {
        var order: [String] = [], total: [String: Double] = [:]
        for s in segments where !s.speaker.isEmpty {
            if total[s.speaker] == nil { order.append(s.speaker) }
            total[s.speaker, default: 0] += max(0, s.end - s.start)
        }
        return order.map { ($0, total[$0]!) }
    }
}
