@preconcurrency import AVFoundation
import Foundation

/// The loudness outline of a recording, for drawing it: `count` peaks from 0 to 1 (scaled to
/// the loudest), each the highest sample in its stretch of the audio.
public enum Waveform {
    public static func peaks(of file: URL, count: Int) throws -> [Float] {
        let audio = try AVAudioFile(forReading: file)
        let total = audio.length
        guard total > 0, count > 0 else { return [] }
        let perBin = max(1, Double(total) / Double(count))
        var peaks = [Float](repeating: 0, count: count)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk) else { return [] }
        var position: Int64 = 0
        while position < total {
            try audio.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for c in 0..<Int(buffer.format.channelCount) {
                let data = channels[c]
                for i in 0..<frames {
                    let bin = min(count - 1, Int(Double(position + Int64(i)) / perBin))
                    let v = abs(data[i])
                    if v > peaks[bin] { peaks[bin] = v }
                }
            }
            position += Int64(frames)
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}
