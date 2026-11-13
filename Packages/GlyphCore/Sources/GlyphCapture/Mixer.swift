@preconcurrency import AVFoundation
import Foundation

/// Mixes the inputs into one 48 kHz mono AAC file. Every buffer is copied on arrival
/// and handled on one serial queue, so the audio threads never wait and `finish` runs
/// after every buffer that came before it. The first input (the microphone when it is
/// one) is the clock: the others are summed in as far as they have arrived, and a lag
/// of more than half a second is dropped rather than drifting.
final class Mixer: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    struct Progress: Sendable {
        var elapsed: TimeInterval
        var levels: [Recorder.Input: Float]
    }

    private let queue = DispatchQueue(label: "glyph.record.mix", qos: .userInitiated)
    // Everything below is touched only on `queue`.
    private var file: AVAudioFile?
    private let inputs: [Recorder.Input]
    private var pending: [Recorder.Input: [Float]] = [:]
    private var converters: [Recorder.Input: AVAudioConverter] = [:]
    private var paused = false
    private var frames: Int64 = 0
    private var failure: Error?
    private let onProgress: @Sendable (Progress) -> Void

    init(url: URL, inputs: [Recorder.Input], onProgress: @escaping @Sendable (Progress) -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Mixer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        self.inputs = inputs
        self.onProgress = onProgress
    }

    /// Takes a copy of the buffer; safe from any thread, including a real-time one.
    func append(_ buffer: AVAudioPCMBuffer, from input: Recorder.Input) {
        guard buffer.frameLength > 0, let copy = Mixer.copy(buffer) else { return }
        queue.async { [self] in
            guard file != nil, !paused, inputs.contains(input), failure == nil else { return }
            do {
                pending[input, default: []] += try convert(copy, from: input)
                mix()
            } catch {
                failure = error
            }
        }
    }

    func setPaused(_ on: Bool) {
        queue.async { [self] in
            if on { mix() }
            paused = on
            pending.removeAll()
        }
    }

    /// Writes what is left and closes the file. Returns the seconds written.
    func finish() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<TimeInterval, Error>) in
            queue.async { [self] in
                mix()
                file?.close()
                file = nil
                if let failure { done.resume(throwing: failure) } else { done.resume(returning: Double(frames) / Mixer.sampleRate) }
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, from input: Recorder.Input) throws -> [Float] {
        let target = Mixer.format
        let src = buffer.format
        let converter: AVAudioConverter
        if let c = converters[input], c.inputFormat == src {
            converter = c
        } else {
            guard let c = AVAudioConverter(from: src, to: target) else { throw CaptureError.failed("Can't read audio in \(src).") }
            c.downmix = true
            converters[input] = c
            converter = c
        }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / src.sampleRate).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var given = false // the converter calls the block synchronously
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? CaptureError.failed("Audio conversion failed.") }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    private func mix() {
        guard let clock = inputs.first, var mixed = pending[clock], !mixed.isEmpty, let file else { return }
        pending[clock] = []
        var levels = [clock: Mixer.level(mixed)]
        for other in inputs.dropFirst() {
            let samples = pending[other] ?? []
            let n = min(samples.count, mixed.count)
            for i in 0..<n { mixed[i] += samples[i] }
            levels[other] = Mixer.level(Array(samples.prefix(n)))
            // ponytail: drops a lagging input's backlog over 0.5 s; align by host time if drift ever matters.
            pending[other] = Array(samples.dropFirst(n).suffix(Int(Mixer.sampleRate / 2)))
        }
        for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i])) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Mixer.format, frameCapacity: AVAudioFrameCount(mixed.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(mixed.count)
        mixed.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: mixed.count) }
        do {
            try file.write(from: buffer)
            frames += Int64(mixed.count)
            onProgress(Progress(elapsed: Double(frames) / Mixer.sampleRate, levels: levels))
        } catch {
            failure = error
        }
    }

    /// 0 (silence, -50 dBFS and below) to 1 (full scale), from the RMS.
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        return max(0, min(1, (20 * log10(rms) + 50) / 50))
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
