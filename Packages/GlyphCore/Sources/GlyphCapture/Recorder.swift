@preconcurrency import AVFoundation
import Foundation
import Observation

/// Why recording could not start or stopped early. The message is ready to show.
public enum CaptureError: LocalizedError, Equatable, Sendable {
    case microphoneDenied
    case screenRecordingDenied
    case noMicrophone
    case alreadyRecording
    case notRecording
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Glyph can't hear the microphone. Allow it in System Settings > Privacy & Security > Microphone."
        case .screenRecordingDenied: "Glyph can't hear the Mac's sound. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .noMicrophone: "No microphone is connected."
        case .alreadyRecording: "A recording is already running."
        case .notRecording: "Nothing is recording."
        case .failed(let message): message
        }
    }
}

/// Records the microphone and, optionally, the Mac's own sound (a call in the browser,
/// Zoom, FaceTime) into one AAC `.m4a`, with live levels for a meter, pause and resume.
///
/// ```swift
/// let recorder = Recorder()
/// try await recorder.start(to: folder.appending(path: "audio.m4a"), capturing: [.microphone, .systemAudio])
/// recorder.levels[.microphone]   // 0...1, for a meter
/// recorder.elapsed               // seconds recorded, pauses left out
/// let recording = try await recorder.stop()
/// ```
///
/// Tests and imports hand it buffers instead: `start(to:feeding:)` returns a `Feed`.
@MainActor @Observable
public final class Recorder {
    public enum Input: String, Hashable, Sendable, CaseIterable {
        case microphone, systemAudio
    }

    public enum State: Equatable, Sendable { case idle, recording, paused }

    /// A finished file.
    public struct Recording: Equatable, Sendable {
        public var url: URL
        public var duration: TimeInterval
    }

    public private(set) var state = State.idle
    /// Seconds written so far; a pause does not count.
    public private(set) var elapsed: TimeInterval = 0
    /// 0 (silence) to 1 (full scale) per input, updated about ten times a second.
    public private(set) var levels: [Input: Float] = [:]
    /// Set when an input stops on its own (system audio lost); the rest keeps recording.
    public private(set) var warning: String?

    @ObservationIgnored private var mixer: Mixer?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var microphone: Microphone?
    #if os(macOS)
    @ObservationIgnored private var systemAudio: SystemAudio?
    #endif

    public init() {}

    /// Starts recording the inputs into `url` (`.m4a`), replacing any file there.
    /// Throws `CaptureError.microphoneDenied` / `.screenRecordingDenied` when a
    /// permission is missing, before anything starts.
    public func start(to url: URL, capturing inputs: Set<Input>) async throws {
        guard state == .idle else { throw CaptureError.alreadyRecording }
        guard !inputs.isEmpty else { throw CaptureError.failed("Choose something to record.") }
        if inputs.contains(.microphone), Permissions.microphone != .granted {
            guard await Permissions.requestMicrophone() else { throw CaptureError.microphoneDenied }
        }
        #if os(macOS)
        if inputs.contains(.systemAudio), Permissions.screenRecording != .granted { throw CaptureError.screenRecordingDenied }
        #else
        if inputs.contains(.systemAudio) { throw CaptureError.failed("Only a Mac can record its own sound.") }
        #endif

        let mixer = try begin(url, Input.allCases.filter(inputs.contains))
        do {
            if inputs.contains(.microphone) {
                let mic = Microphone()
                try await mic.start { buffer in mixer.append(buffer, from: .microphone) }
                microphone = mic
            }
            #if os(macOS)
            if inputs.contains(.systemAudio) {
                let sys = SystemAudio()
                try await sys.start(onBuffer: { buffer in mixer.append(buffer, from: .systemAudio) }, onStop: { [weak self] error in
                    Task { @MainActor in self?.warning = "The Mac's sound stopped recording: \(error.localizedDescription)" }
                })
                systemAudio = sys
            }
            #endif
        } catch {
            _ = try? await stop()
            throw error
        }
    }

    /// Starts a recording that takes its sound from the returned `Feed` instead of
    /// devices (tests, imports). The first input in `Input` order is the clock.
    @discardableResult
    public func start(to url: URL, feeding inputs: Set<Input>) throws -> Feed {
        guard state == .idle else { throw CaptureError.alreadyRecording }
        return Feed(mixer: try begin(url, Input.allCases.filter(inputs.contains)))
    }

    /// Hands sound to a recording, from any thread. Sound after `stop` is ignored.
    public struct Feed: Sendable {
        let mixer: Mixer
        public func append(_ buffer: AVAudioPCMBuffer, from input: Input) { mixer.append(buffer, from: input) }
    }

    public func pause() {
        guard state == .recording else { return }
        mixer?.setPaused(true)
        state = .paused
        levels = [:]
    }

    public func resume() {
        guard state == .paused else { return }
        mixer?.setPaused(false)
        state = .recording
    }

    /// Stops the inputs, writes every buffer already captured and closes the file.
    /// Safe to call at any moment; the file is complete when it returns.
    @discardableResult
    public func stop() async throws -> Recording {
        guard let mixer, let url else { throw CaptureError.notRecording }
        microphone?.stop()
        microphone = nil
        #if os(macOS)
        await systemAudio?.stop()
        systemAudio = nil
        #endif
        self.mixer = nil
        self.url = nil
        state = .idle
        levels = [:]
        let duration = try await mixer.finish()
        elapsed = duration
        return Recording(url: url, duration: duration)
    }

    private func begin(_ url: URL, _ inputs: [Input]) throws -> Mixer {
        let mixer = try Mixer(url: url, inputs: inputs) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.elapsed = progress.elapsed
                self.levels = progress.levels
            }
        }
        self.mixer = mixer
        self.url = url
        elapsed = 0
        warning = nil
        state = .recording
        return mixer
    }
}

/// The microphone through AVAudioEngine. Starting it can block for seconds, so it
/// starts off the main actor.
final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        let engine = engine
        try await Task.detached(priority: .userInitiated) {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in onBuffer(buffer) }
            engine.prepare()
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                throw CaptureError.failed("The microphone didn't start: \(error.localizedDescription)")
            }
        }.value
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
