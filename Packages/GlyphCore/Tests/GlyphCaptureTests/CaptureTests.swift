@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import GlyphCapture
import GlyphVault

func scratch(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "glyph-capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: name)
}

/// A sine tone, the shape a mic tap or ScreenCaptureKit hands over.
func tone(_ hz: Double, rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount, amplitude: Float = 0.3, offset: Int = 0) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) {
            buffer.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * hz * Double(offset + i) / rate))
        }
    }
    return buffer
}

/// Seconds of audio in a file and its RMS, read back with AVAudioFile.
func inspect(_ url: URL) throws -> (seconds: Double, rms: Float, format: AudioFormatID, rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    return (Double(file.length) / file.processingFormat.sampleRate, rms, file.fileFormat.streamDescription.pointee.mFormatID, file.fileFormat.sampleRate)
}

@Test @MainActor func recorderMixesTwoInputsIntoAnM4A() async throws {
    let url = try scratch("audio.m4a")
    let recorder = Recorder()
    let feed = try recorder.start(to: url, feeding: [.microphone, .systemAudio])
    #expect(recorder.state == .recording)
    // Two seconds from a 44.1 kHz stereo mic and a 48 kHz mono system stream.
    for i in 0..<20 {
        feed.append(tone(440, rate: 44_100, channels: 2, frames: 4_410, offset: i * 4_410), from: .microphone)
        feed.append(tone(660, rate: 48_000, channels: 1, frames: 4_800, offset: i * 4_800), from: .systemAudio)
    }
    let recording = try await recorder.stop()
    #expect(recorder.state == .idle)
    #expect(abs(recording.duration - 2) < 0.05, "\(recording.duration)")
    #expect(recorder.elapsed == recording.duration)
    let file = try inspect(url)
    #expect(file.format == kAudioFormatMPEG4AAC)
    #expect(file.rate == 48_000)
    #expect(abs(file.seconds - 2) < 0.1, "\(file.seconds)")
    #expect(file.rms > 0.25, "both tones are in the mix (one alone is about 0.21, both 0.3): \(file.rms)")
    await #expect(throws: CaptureError.notRecording) { try await recorder.stop() }
}

@Test @MainActor func pauseLeavesTheGapOut() async throws {
    let url = try scratch("audio.m4a")
    let recorder = Recorder()
    let feed = try recorder.start(to: url, feeding: [.microphone])
    #expect(throws: CaptureError.alreadyRecording) { try recorder.start(to: url, feeding: [.microphone]) }
    let second = { feed.append(tone(300, rate: 48_000, channels: 1, frames: 48_000), from: .microphone) }
    second()
    recorder.pause()
    #expect(recorder.state == .paused)
    second()
    feed.append(tone(300, rate: 48_000, channels: 1, frames: 48_000), from: .systemAudio) // not an input: ignored
    recorder.resume()
    second()
    let recording = try await recorder.stop()
    #expect(abs(recording.duration - 2) < 0.05, "\(recording.duration)")
    #expect(abs(try inspect(url).seconds - 2) < 0.1)
}

@Test @MainActor func stopUnderLoadStillFinishesTheFile() async throws {
    let url = try scratch("audio.m4a")
    let recorder = Recorder()
    let feed = try recorder.start(to: url, feeding: [.microphone, .systemAudio])
    let flood = Task.detached {
        for i in 0..<2_000 {
            feed.append(tone(220, rate: 48_000, channels: 2, frames: 480, offset: i * 480), from: i % 2 == 0 ? .microphone : .systemAudio)
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    let recording = try await recorder.stop()
    await flood.value // feeding after stop is ignored, not a crash
    let file = try inspect(url)
    #expect(file.format == kAudioFormatMPEG4AAC)
    #expect(abs(file.seconds - recording.duration) < 0.1, "a finished, readable file: \(file.seconds) vs \(recording.duration)")
}

@Test @MainActor func missingPermissionsAreReportedNotCrashed() async throws {
    let recorder = Recorder()
    let url = try scratch("audio.m4a")
    await #expect(throws: CaptureError.self) { try await recorder.start(to: url, capturing: []) }
    print("microphone permission: \(Permissions.microphone), screen recording: \(Permissions.screenRecording)")
    // Live capture is never started here: it would prompt, or record the Mac.
    if Permissions.screenRecording != .granted {
        await #expect(throws: CaptureError.screenRecordingDenied) { try await recorder.start(to: url, capturing: [.systemAudio]) }
        #expect(recorder.state == .idle)
    }
    #expect(CaptureError.microphoneDenied.errorDescription?.contains("System Settings") == true)
}

@Test func mixerLevelsAreZeroToOne() {
    #expect(Mixer.level([]) == 0)
    #expect(Mixer.level([0, 0]) == 0)
    #expect(Mixer.level([1, -1]) == 1)
    #expect(Mixer.level([0.001]) < 0.25)
}

/// A spoken file (`say`), fed through the recorder into an m4a, then transcribed with
/// Apple's on-device speech recognition and the names as context.
@Test(.timeLimit(.minutes(10))) @MainActor func transcribesARecordingOfSpeech() async throws {
    let aiff = try scratch("speech.aiff")
    let line = "Ken Lee from Acme will send the signed order form on Friday."
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", aiff.path, line]
    try say.run()
    say.waitUntilExit()
    #expect(say.terminationStatus == 0)

    // Feed the file through the recorder, as an import would.
    let m4a = aiff.deletingLastPathComponent().appending(path: "audio.m4a")
    let recorder = Recorder()
    let feed = try recorder.start(to: m4a, feeding: [.microphone])
    let source = try AVAudioFile(forReading: aiff)
    while source.framePosition < source.length {
        let chunk = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4_096)!
        try source.read(into: chunk)
        feed.append(chunk, from: .microphone)
    }
    let recording = try await recorder.stop()
    #expect(recording.duration > 2)

    let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
    let status = await transcriber.status()
    print("speech model status: \(status)")
    if status == .unsupported { try Test.cancel("Speech recognition isn't available on this Mac.") }
    let events = EventLog()
    let transcript: Transcript
    do {
        transcript = try await transcriber.transcribe(m4a, names: ["Ken Lee", "Acme", "Kenny"]) { events.add($0) }
    } catch TranscriptionError.serviceLost, TranscriptionError.unavailable {
        try Test.cancel("Speech assets are unavailable on this Mac.")
    }
    let text = transcript.segments.map(\.text).joined(separator: " ")
    print("transcript: \(text) | events: \(events.count)")
    #expect(!transcript.segments.isEmpty)
    #expect(transcript.model == "apple-speech" && transcript.language == "en-US")
    #expect(text.lowercased().contains("order form"))
    #expect(text.contains("Acme"))
    // Apple's recognizer writes "Ken Lee" as "Kenley", one word, and the `names:` it was given
    // does not override it - "Acme" comes through because it would anyway. This is a real gap in
    // the vocabulary hint, not a quirk of the fixture: a person whose first and last name run
    // together as a plausible word is mis-spelled in a meeting the same way, and that lands in
    // his notes. It is a known issue rather than a dropped assertion so that the day the hint
    // works, or someone makes it work, this test goes red and the comment is deleted with it.
    withKnownIssue("Ken Lee is heard as Kenley; the names: hint does not force the spelling") {
        #expect(text.contains("Ken Lee"))
    }
    #expect(transcript.segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= recording.duration + 1 })
    #expect(events.last == .transcribing(1))
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Transcriber.Event] = []
    func add(_ e: Transcriber.Event) { lock.withLock { events.append(e) } }
    var count: Int { lock.withLock { events.count } }
    var last: Transcriber.Event? { lock.withLock { events.last } }
}
