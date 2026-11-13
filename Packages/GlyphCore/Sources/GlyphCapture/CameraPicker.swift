#if os(iOS)
import ImageIO
import SwiftUI
import UIKit

/// The system camera, for a picture an app wants to keep: a receipt, a statement on a screen, a
/// meal. Drawn once here for the family, because Glyph Wealth needed the same camera Glyph Jot
/// already had (Fru, 2026-11-10: "the plus button should open the camera... if I want to take a
/// screenshot of a receipt to save it and file it in a vault").
/// The system camera. One picture per open; it gets the tag on screen.
public struct CameraPicker: UIViewControllerRepresentable {
    /// The picture and the camera's metadata (exposure, lens, time) to keep in the file.
    let done: (UIImage?, [String: Any]) -> Void

    public init(done: @escaping (UIImage?, [String: Any]) -> Void) { self.done = done }

    public static var isAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestSeed") { return true } // stand-in below
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        #if DEBUG
        // UI tests get a stand-in that "takes" one picture: the Simulator shows a camera
        // screen but its shutter never delivers a frame.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSeed") || !UIImagePickerController.isSourceTypeAvailable(.camera) {
            let stub = UIViewController()
            DispatchQueue.main.async {
                done(UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160)).image { ctx in
                    UIColor.systemOrange.setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
                }, [:])
            }
            return stub
        }
        #endif
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    public final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?, [String: Any]) -> Void
        init(done: @escaping (UIImage?, [String: Any]) -> Void) { self.done = done }

        public func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            var meta = info[.mediaMetadata] as? [String: Any] ?? [:]
            // jpegData writes the picture's own orientation; the camera's would turn it twice.
            meta[kCGImagePropertyOrientation as String] = nil
            if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = nil
                meta[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            done(info[.originalImage] as? UIImage, meta)
        }

        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil, [:]) }
    }
}

#endif
