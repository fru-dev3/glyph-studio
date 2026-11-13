#if os(macOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// The Mac's own sound through ScreenCaptureKit, without this app's sound. The stream
/// asks for the smallest possible video, since ScreenCaptureKit only captures audio
/// alongside a display.
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "glyph.record.system-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onStop: (@Sendable (Error) -> Void)?

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onStop: @escaping @Sendable (Error) -> Void) async throws {
        self.onBuffer = onBuffer
        self.onStop = onStop
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw CaptureError.failed("No display to record the Mac's sound from.") }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.failed("The Mac's sound didn't start recording: \(error.localizedDescription)")
        }
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, let buffer = SystemAudio.pcm(sample) else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    static func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription, var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
#endif
