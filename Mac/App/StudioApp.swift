import AppKit
import SwiftUI

/// Glyph Bot: the agentic harness. Your agents on the left (a team you message), what each read
/// and saved beside its reply, and the vault and the Glyph apps as Sources, over Glyph Engine.
@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Glyph Bot", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await model.refresh(); TestDriver.startIfScripted() }
        }
        .defaultSize(width: Self.windowSize.width, height: Self.windowSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }

    /// The design's window is 1396x856; STUDIO_WINDOW=WxH overrides (tests pin it).
    static var windowSize: CGSize {
        if let s = Engine.env["STUDIO_WINDOW"]?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) { return CGSize(width: w, height: h) }
        return CGSize(width: 1396, height: 856)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests and screenshots pick the look: STUDIO_APPEARANCE=dark or light.
        if let a = Engine.env["STUDIO_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        // Tests pin the window to the design's size so screenshots line up with the renders.
        if Engine.env["STUDIO_WINDOW"] != nil {
            DispatchQueue.main.async {
                guard let w = NSApp.windows.first else { return }
                let size = StudioApp.windowSize
                w.setContentSize(size)
                w.setFrameOrigin(NSPoint(x: 40, y: 40))
            }
        }
    }
}
