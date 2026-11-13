import AppKit
import SwiftUI
import Vision

/// Studio's own test driver, for running UI tests with nobody at the Mac. macOS UI tests need
/// Automation Mode (a password) and outside scripting needs Accessibility permission; an app
/// driving itself needs neither. With STUDIO_SCRIPT=<steps.json>, Studio runs the steps, writes
/// STUDIO_REPORT and quits (exit 0 only if every step passed).
///
/// Two honest mechanisms, because SwiftUI only builds its accessibility tree for a real assistive
/// client:
/// - Seeing is reading the screen. `see`/`absent` draw the window and read it with on-device text
///   recognition (Vision), so a check only passes if the words are really visible.
/// - Pressing goes through the control. Every control registers what it does under its id while it
///   is on screen (`.probe(_:action:)`; the shared buttons do it themselves), so `press` runs
///   exactly what a click runs, and fails if that control isn't showing.
///
/// Steps: {"go": "domain:wealth"} {"press": "<id>"} {"type": "<id>", "text": "..."} {"submit": "<id>"}
/// {"wait": "<id>"} {"gone": "<id>"} {"see": "<text>"} {"absent": "<text>"} {"call": "<words>"}
/// {"noCall": "<words>"} {"file": "<vault path>", "contains": "<text>"} {"lacks": "<text>"}
/// {"snap": "<name>"} {"sleep": <ms>} {"reload": true} {"vault": "gone"|"back"}
@MainActor
enum TestDriver {
    static var active: Bool { Engine.env["STUDIO_SCRIPT"] != nil }

    struct Step: Decodable {
        var attach: String?
        var go, press, type, text, submit, wait, gone, see, absent, call, noCall, file, contains, lacks, snap, note: String?
        var vault: String?      // "gone" moves the vault aside, "back" returns it
        var sleep: Int?
        var timeout: Double?
        var reload: Bool?
    }

    static var report: [[String: String]] = []
    static var failed = false
    private static var started = false

    static func startIfScripted() {
        guard !started, let path = Engine.env["STUDIO_SCRIPT"] else { return }
        started = true
        Task { @MainActor in
            do {
                let steps = try JSONDecoder().decode([Step].self, from: Data(contentsOf: URL(filePath: path)))
                NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(800))
                for (i, s) in steps.enumerated() {
                    let (ok, detail) = await run(s)
                    print("driver: \(i + 1) \(describe(s)) -> \(ok ? "ok" : "FAIL") \(detail)"); fflush(stdout)
                    report.append(["step": "\(i + 1)", "what": describe(s), "ok": ok ? "yes" : "no", "detail": detail])
                    if !ok { _ = snap("FAILED-\(URL(filePath: path).deletingPathExtension().lastPathComponent)"); failed = true; break }
                }
            } catch {
                report.append(["step": "0", "what": "read script", "ok": "no", "detail": error.localizedDescription]); failed = true
            }
            finish()
        }
    }

    private static func describe(_ s: Step) -> String {
        let parts: [String?] = [s.note, s.go.map { "go \($0)" }, s.press.map { "press \($0)" }, s.type.map { "type into \($0)" }, s.submit.map { "submit \($0)" },
                                s.wait.map { "wait \($0)" }, s.gone.map { "gone \($0)" }, s.see.map { "see \($0)" }, s.absent.map { "absent \($0)" },
                                s.call.map { "call \($0)" }, s.noCall.map { "no call \($0)" }, s.file.map { "file \($0)" }, s.snap.map { "snap \($0)" },
                                s.sleep.map { "sleep \($0)" }, s.reload.map { _ in "reload" }]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private static func run(_ s: Step) async -> (Bool, String) {
        let timeout = s.timeout ?? 8
        if let r = s.go { AppModel.shared.go(AppModel.parse(r)); try? await Task.sleep(for: .milliseconds(600)); return (true, "") }
        if s.reload == true { await AppModel.shared.refresh(); return (true, "") }
        // the owner's vault invariant: a test may take the vault away under the running app and give it back.
        if let v = s.vault {
            // Only ever a vault the run was explicitly handed (drive.sh copies DemoVault to /tmp per
            // run). Without this a stray script could move the owner's real one.
            guard Engine.env["STUDIO_VAULT"] != nil else { return (false, "the vault step needs STUDIO_VAULT, a throwaway copy") }
            let dir = Vault.root, aside = URL(filePath: dir.path() + "-gone")
            let from = v == "gone" ? dir : aside, to = v == "gone" ? aside : dir
            do { try FileManager.default.moveItem(at: from, to: to) }
            catch { return (false, "vault \(v): \(error.localizedDescription)") }
            return (true, "")
        }
        if let ms = s.sleep { try? await Task.sleep(for: .milliseconds(ms)); return (true, "") }
        if let id = s.press {
            // Studio's own controls register what they do; a shared one (Glyph's mic) is clicked where it sits.
            if let action = await poll(min(timeout, 1.5), { Probe.actions[id] }) { action() }
            else if await poll(timeout, { Self.click(id) ? true : nil }) == nil {
                return (false, "no control \"\(id)\" on screen; showing: \(Probe.showing)")
            }
            try? await Task.sleep(for: .milliseconds(500))
            return (true, "")
        }
        if let id = s.attach {
            // {"attach": "composer", "text": "receipt-photo.png"}: a file from the fixtures, as if picked.
            guard let sink = await poll(timeout, { Probe.attachers[id] }) else { return (false, "no composer \"\(id)\" to attach to") }
            let dir = Engine.env["STUDIO_FIXTURES"].map { URL(filePath: $0) } ?? URL(filePath: ".")
            sink(dir.appending(path: s.text ?? ""))
            try? await Task.sleep(for: .milliseconds(300))
            return (true, "")
        }
        if let id = s.type {
            guard let field = await poll(timeout, { Probe.fields[id] }) else { return (false, "no field \"\(id)\" on screen; showing: \(Probe.showing)") }
            field.wrappedValue = s.text ?? ""
            try? await Task.sleep(for: .milliseconds(300))
            return (true, "")
        }
        if let id = s.submit {
            guard let action = await poll(timeout, { Probe.submits[id] }) else { return (false, "no field \"\(id)\" to submit") }
            action()
            try? await Task.sleep(for: .milliseconds(500))
            return (true, "")
        }
        if let id = s.wait { return await poll(timeout, { Probe.present.contains(id) ? true : nil }) != nil ? (true, "") : (false, "\"\(id)\" never appeared; showing: \(Probe.showing)") }
        if let id = s.gone { return await poll(timeout, { Probe.present.contains(id) ? nil : true }) != nil ? (true, "") : (false, "\"\(id)\" is still on screen") }
        if let text = s.see {
            var last: [String] = []
            let hit = await pollAsync(timeout) { () async -> Bool? in
                last = await screenText()
                return last.contains(where: { normalized($0).contains(normalized(text)) }) ? true : nil
            }
            return hit != nil ? (true, "") : (false, "never saw \"\(text)\" on screen; read: \((last.first ?? "").prefix(3000).replacingOccurrences(of: "\n", with: " | "))")
        }
        if let text = s.absent {
            var last: [String] = []
            let hit = await pollAsync(timeout) { () async -> Bool? in
                last = await screenText()
                return last.contains(where: { normalized($0).contains(normalized(text)) }) ? nil : true
            }
            return hit != nil ? (true, "") : (false, "\"\(text)\" is still on screen")
        }
        if let words = s.call {
            let w = words.split(separator: " ").map(String.init)
            let hit = await poll(timeout, { calls().first { c in w.allSatisfy { c.contains($0) } } })
            return hit != nil ? (true, String(hit!.prefix(200))) : (false, "no engine call with \(words); last calls: \(calls().suffix(6).joined(separator: " | "))")
        }
        if let words = s.noCall {
            let w = words.split(separator: " ").map(String.init)
            let hit = calls().first { c in w.allSatisfy { c.contains($0) } }
            return hit == nil ? (true, "") : (false, "unexpected engine call: \(hit!)")
        }
        if let rel = s.file {
            let url = Vault.root.appending(path: rel)
            let want = s.contains ?? "", not = s.lacks
            let hit = await poll(timeout, { (try? String(contentsOf: url, encoding: .utf8)).flatMap { t in
                (want.isEmpty || t.contains(want)) && (not.map { !t.contains($0) } ?? true) ? t : nil } })
            return hit != nil ? (true, "") : (false, "\(rel) does not contain \"\(want)\"\(not.map { " without \"\($0)\"" } ?? "")")
        }
        if let name = s.snap { return snap(name) }
        return (false, "empty step")
    }

    private static func poll<T>(_ seconds: Double, _ f: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let v = f() { return v }
            try? await Task.sleep(for: .milliseconds(150))
        } while Date() < end
        return nil
    }

    private static func pollAsync<T>(_ seconds: Double, _ f: () async -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let v = await f() { return v }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < end
        return nil
    }

    // MARK: reading the screen

    /// Lowercased, punctuation and bullets turned into spaces, spaces collapsed, on both sides of a check:
    /// text recognition reads typography loosely ("No.goals yet" for "No goals yet", "•" for "·"),
    /// but a missing or different word still fails.
    static func normalized(_ s: String) -> String {
        let loose = CharacterSet(charactersIn: ".,:;!?\u{00B7}\u{2022}'\u{2018}\u{2019}\"\u{201C}\u{201D}()")
        return String(s.lowercased().unicodeScalars.map { loose.contains($0) ? " " : Character($0) })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }


    /// Everything the window shows, read by on-device text recognition.
    /// Both readings of the window: Vision's own order first, then row-major. A `see` holds if the
    /// words are in either; an `absent` has to hold in both.
    static func screenText() async -> [String] {
        guard let cg = windowImage()?.cgImage else { return [""] }
        return await withCheckedContinuation { c in
            let req = VNRecognizeTextRequest { r, _ in
                let obs = r.results as? [VNRecognizedTextObservation] ?? []
                // Two readings of the same screen, because neither order is right on its own and a
                // `see` only has to hold in one of them (2026-11-07, drive.sh).
                //   Vision's own order groups a column together but can hand back a wrapped sentence
                //   backwards: "of 5. Working on: ... Step 3" never matches the sentence, although
                //   every word of it is on screen (teammate-watch).
                //   Row-major puts a wrap back together, but reads a two-column screen straight
                //   across, so one column's lines land between the halves of the other's
                //   (more-decisions).
                // Rows are bucketed before sorting so the comparison stays a total order on
                // (row, x): a same-row test written inline is not transitive, and Swift's sort
                // traps on a comparator that is not a strict weak ordering.
                let own: [String] = obs.compactMap { $0.topCandidates(1).first?.string }
                // Vision's origin is bottom left, so a larger midY is higher up the window.
                var placed: [(row: Int, x: CGFloat, text: String)] = []
                for o in obs {
                    guard let t = o.topCandidates(1).first?.string else { continue }
                    let box: CGRect = o.boundingBox
                    let row = Int(((1 - box.midY) * 120).rounded())
                    placed.append((row: row, x: box.minX, text: t))
                }
                placed.sort { $0.row == $1.row ? $0.x < $1.x : $0.row < $1.row }
                let rowMajor: [String] = placed.map(\.text)
                c.resume(returning: [own.joined(separator: "\n"), rowMajor.joined(separator: "\n")])
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            DispatchQueue.global().async { try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
        }
    }

    /// The window's content, drawn by Studio itself (no screen-recording permission needed).
    static func windowImage() -> NSBitmapImageRep? {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // macOS draws the window buttons in their own layer, which cacheDisplay leaves out: draw the
        // window's real buttons where they sit (none are drawn if the window has none).
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            // Their colour comes from a system layer that cacheDisplay leaves out (it paints them black),
            // so fill each at its real frame in the colour macOS shows: red, yellow, green when the
            // window is in front, grey when not.
            let active: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
            for (i, b) in visibleWindowButtons(window).enumerated() {
                let f = b.convert(b.bounds, to: view)
                let d = min(f.width, f.height) - 2
                let dot = NSRect(x: f.midX - d / 2, y: f.midY - d / 2, width: d, height: d)
                (window.isKeyWindow ? NSColor(Color(hex: active[min(i, 2)])) : NSColor(Color(hex: 0xDDDDDC))).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // In sRGB, as the design renders are (otherwise #008000 saves as a duller green).
        return rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    }

    /// Clicks a shared control (Glyph's mic) where it sits: a real mouse down and up sent to the window,
    /// at the frame the control reported (`.probeFrame`). No permission needed; it stays in the app.
    static func click(_ id: String) -> Bool {
        guard Probe.present.contains(id), let r = Probe.frames[id],
              let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView else { return false }
        let p = NSPoint(x: r.midX, y: content.bounds.height - r.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(e)
        }
        return true
    }

    static func visibleWindowButtons(_ w: NSWindow) -> [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }.filter { !$0.isHidden && $0.window != nil }
    }

    static func snap(_ name: String) -> (Bool, String) {
        guard let dir = Engine.env["STUDIO_SHOTS"] else { return (false, "no STUDIO_SHOTS") }
        guard let rep = windowImage(), let png = rep.representation(using: .png, properties: [:]) else { return (false, "could not draw the window") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try png.write(to: URL(filePath: dir).appending(path: "\(name).png")) } catch { return (false, error.localizedDescription) }
        let buttons = NSApp.windows.first(where: { $0.isVisible }).map { visibleWindowButtons($0).count } ?? 0
        let key = NSApp.windows.first(where: { $0.isVisible })?.isKeyWindow == true
        return (true, "\(rep.pixelsWide)x\(rep.pixelsHigh), window buttons \(buttons), app active \(NSApp.isActive), window key \(key)")
    }

    // MARK: evidence

    private static func calls() -> [String] {
        guard let fx = Engine.fixtures else { return [] }
        return ((try? String(contentsOf: fx.appending(path: "calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func finish() {
        if let out = Engine.env["STUDIO_REPORT"], let data = try? JSONSerialization.data(withJSONObject: ["ok": !failed, "steps": report], options: [.prettyPrinted]) {
            try? data.write(to: URL(filePath: out))
        }
        exit(failed ? 1 : 0)
    }
}

/// What is on screen and what it does, for the test driver. Registered by `.probe` while a control
/// is visible and removed when it goes; only kept when a test script is running.
@MainActor
enum Probe {
    static var actions: [String: () -> Void] = [:]
    static var frames: [String: CGRect] = [:]
    /// Where `attach` steps put a file (a composer's pending files).
    static var attachers: [String: (URL) -> Void] = [:]
    static var submits: [String: () -> Void] = [:]
    static var fields: [String: Binding<String>] = [:]
    static var counts: [String: Int] = [:]
    static var present: Set<String> { Set(counts.filter { $0.value > 0 }.keys) }
    static var showing: String { present.sorted().prefix(40).joined(separator: ", ") }

    static func appear(_ id: String) { counts[id, default: 0] += 1 }
    static func disappear(_ id: String) {
        counts[id, default: 1] -= 1
        if counts[id] == 0 { actions[id] = nil; fields[id] = nil; submits[id] = nil }
    }
}

extension View {
    /// Names a control for tests (and accessibility), and registers what pressing it does.
    func probe(_ id: String, action: (() -> Void)? = nil) -> some View {
        accessibilityIdentifier(id)
            .onAppear { guard TestDriver.active else { return }; Probe.appear(id); if let action { Probe.actions[id] = action } }
            .onDisappear { guard TestDriver.active else { return }; Probe.disappear(id) }
    }

    /// Reports where a control sits, so `press` can click it (for controls whose action is not ours).
    func probeFrame(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            guard TestDriver.active else { return }
            Probe.frames[id] = r; Probe.appear(id)
        }
        .onDisappear { guard TestDriver.active else { return }; Probe.disappear(id) } // the frame stays: a new screen's copy may have reported first
    }

    /// Names a text field for tests: `type` writes through the binding, `submit` runs what return does.
    func probeField(_ id: String, text: Binding<String>, submit: (() -> Void)? = nil) -> some View {
        accessibilityIdentifier(id)
            .onAppear {
                guard TestDriver.active else { return }
                Probe.appear(id); Probe.fields[id] = text
                if let submit { Probe.submits[id] = submit }
            }
            .onDisappear { guard TestDriver.active else { return }; Probe.disappear(id) }
    }
}
