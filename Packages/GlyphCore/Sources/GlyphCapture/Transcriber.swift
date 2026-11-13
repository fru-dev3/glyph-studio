@preconcurrency import AVFoundation
import Foundation
import GlyphVault
import Speech
import Synchronization

/// Why a transcript could not be made. The message is ready to show.
public enum TranscriptionError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unsupportedLanguage
    /// The model download finished but the model is still missing: the process has lost
    /// the speech service (XPC 4099). Only relaunching the app reconnects.
    case serviceLost
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available on this device."
        case .unsupportedLanguage: "Speech recognition doesn't support this language."
        case .serviceLost: "Speech recognition stopped answering. Quit and reopen the app."
        case .timedOut: "Speech recognition didn't answer in time."
        case .failed(let message): message
        }
    }
}

/// Apple's on-device speech recognition (SpeechAnalyzer + SpeechTranscriber). Nothing
/// leaves the device. The model is part of the OS but downloaded on first use; the
/// transcriber fetches it and reports the download.
///
/// ```swift
/// let transcript = try await Transcriber().transcribe(audioURL, names: vault.knownNames()) { event in
///     if case .downloadingModel(let done) = event { print("model \(Int(done * 100))%") }
/// }
/// try vault.writeTranscript(transcript, for: id)
/// ```
public struct Transcriber: Sendable {
    public enum Event: Sendable, Equatable {
        /// 0...1 of the speech model download.
        case downloadingModel(Double)
        /// 0...1 of the audio heard so far.
        case transcribing(Double)
    }

    public enum Status: Sendable, Equatable { case ready, needsDownload, unsupported }

    /// The language to hear; falls back to US English when the model doesn't know it.
    public var locale: Locale

    public init(locale: Locale = .current) { self.locale = locale }

    /// Whether the model is on this device, without downloading anything.
    public func status() async -> Status {
        guard SpeechTranscriber.isAvailable, let module = try? await module() else { return .unsupported }
        return switch await AssetInventory.status(forModules: [module]) {
        case .installed: .ready
        case .unsupported: .unsupported
        default: .needsDownload
        }
    }

    /// Downloads the speech model if it is missing. `transcribe` calls this too; call it
    /// ahead (at launch) so the first recording doesn't wait.
    public func prepare(progress: @escaping @Sendable (Event) -> Void = { _ in }) async throws {
        try await install(module(), progress)
    }

    /// Transcribes an audio file into segments with start and end seconds. `names`
    /// (people, accounts and their aliases) help it spell them right. With `turns` (from
    /// `Diarizer`), each segment is split where the speaker changes and carries its speaker.
    public func transcribe(_ file: URL, names: [String] = [], turns: [SpeakerTurn] = [], progress: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> Transcript {
        let transcriber = try await module()
        try await install(transcriber, progress)
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch {
            throw TranscriptionError.failed("Can't read the recording: \(error.localizedDescription)")
        }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        do {
            let collect = Task {
                var segments: [Transcript.Segment] = []
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let end = result.range.end.seconds
                    if duration > 0, end.isFinite { progress(.transcribing(min(1, end / duration))) }
                    guard !text.isEmpty else { continue }
                    let segment = Transcript.Segment(start: result.range.start.seconds, end: end, text: text)
                    segments += Transcript.split(segment, words: Self.words(result.text), turns: turns)
                }
                return segments
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let words = Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            if !words.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = words
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
            let segments = try await collect.value
            progress(.transcribing(1))
            return Transcript(language: locale.identifier(.bcp47), model: "apple-speech", segments: segments)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failed("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func module() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        // Looking the language up has been seen to hang; give it a bound.
        let wanted = locale
        let found = try await withTimeout(.seconds(15)) { () async -> Locale? in
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return l }
            return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let found else { throw TranscriptionError.unsupportedLanguage }
        return SpeechTranscriber(locale: found, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// The words of a result with their times. A run with no time (punctuation) joins the word before.
    static func words(_ text: AttributedString) -> [TimedWord] {
        var out: [TimedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let r = run.audioTimeRange, r.start.seconds.isFinite, r.end.seconds.isFinite {
                out.append(TimedWord(text: piece, start: r.start.seconds, end: r.end.seconds))
            } else if !out.isEmpty {
                out[out.count - 1].text += piece
            } else {
                out.append(TimedWord(text: piece, start: 0, end: 0))
            }
        }
        // A leading untimed run takes the first timed word's time.
        if out.count > 1, out[0].end == 0 { out[1].text = out[0].text + out[1].text; out.removeFirst() }
        return out
    }

    private func install(_ module: SpeechTranscriber, _ progress: @escaping @Sendable (Event) -> Void) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return
        case .unsupported: throw TranscriptionError.unsupportedLanguage
        default: break
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                progress(.downloadingModel(0))
                let watch = request.progress.observe(\.fractionCompleted) { p, _ in progress(.downloadingModel(p.fractionCompleted)) }
                defer { watch.invalidate() }
                try await request.downloadAndInstall()
                progress(.downloadingModel(1))
            }
        } catch {
            throw TranscriptionError.failed("The speech model didn't download: \(error.localizedDescription)")
        }
        if await AssetInventory.status(forModules: [module]) != .installed { throw TranscriptionError.serviceLost }
    }
}

/// Runs `work`, or throws `TranscriptionError.timedOut` after `limit`. A task group
/// would wait for a hung child before returning; this returns and leaves it behind.
func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
        let once = Mutex<CheckedContinuation<T, Error>?>(done)
        let finish = { @Sendable (result: Result<T, Error>) in once.withLock { $0.take() }?.resume(with: result) }
        Task { do { finish(.success(try await work())) } catch { finish(.failure(error)) } }
        Task { try? await Task.sleep(for: limit); finish(.failure(TranscriptionError.timedOut)) }
    }
}
