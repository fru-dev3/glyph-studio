import FluidAudio
import Foundation
import GlyphVault

/// Who spoke when, on this device: FluidAudio's offline pipeline (pyannote Community-1
/// segmentation, WeSpeaker embeddings, VBx clustering) on Core ML. No audio leaves the Mac;
/// the models (CC-BY-4.0, by pyannote) download once from Hugging Face and are kept in
/// Application Support.
///
/// ```swift
/// let turns = try await Diarizer().turns(audioURL)      // [S1 0.0-6.5, S2 7.1-14.6, ...]
/// let transcript = try await Transcriber().transcribe(audioURL, turns: turns)
/// ```
public struct Diarizer: Sendable {
    public init() {}

    /// The speaker turns in an audio file, cleaned (`SpeakerTurn.normalized`).
    public func turns(_ file: URL) async throws -> [SpeakerTurn] {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        let result = try await manager.process(file)
        let raw = result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return SpeakerTurn.normalized(raw)
    }
}
