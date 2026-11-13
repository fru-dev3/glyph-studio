@preconcurrency import AVFoundation
#if os(macOS)
import CoreGraphics
#endif

/// The privacy permissions recording needs, read without side effects so a UI can
/// explain what is missing before the person presses Record.
public enum Permissions {
    public enum Status: Sendable { case granted, denied, notDetermined }

    public static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Shows the system prompt the first time; afterwards answers at once.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    #if os(macOS)
    /// macOS does not say whether it has asked yet, so a missing permission reads as denied.
    public static var screenRecording: Status {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Shows the system prompt (once per app); the person may need to relaunch the app
    /// after allowing it.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
    #endif
}
