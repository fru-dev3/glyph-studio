@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dictate first: the one control every Glyph app uses for typing-free input. Tap to talk,
/// words appear as you speak (Apple's on-device SpeechAnalyzer, the path Glyph Jot uses; nothing
/// leaves the device, no sound is kept), tap again to stop.
///
///     TextField("How are you feeling?", text: $note).dictatable($note)   // a mic in the field
///     DictateButton { words in fill(from: words) }                       // talk to fill a form: onFinal
///     DictateButton(text: $name, onFinal: { start(project: $0) })        // both: live words and the end
///     DictateButton.hostingView { words in ... }                         // AppKit (macOS): an NSView
///
/// From AppKit code without SwiftUI, use `LiveDictation` itself: `onText` while speaking, `onFinal` on stop.
///
/// Tests and the Simulator have no speech model: set `GLYPH_DICTATION_TEXT` in the environment, or
/// the `glyphDictationText` default (launch argument `-glyphDictationText "words"`), and those words
/// are what is "heard", streamed a word at a time.
@MainActor @Observable
public final class LiveDictation {
    public private(set) var on = false
    /// Paused: the microphone is open but nothing is heard until `resume()`.
    public private(set) var paused = false
    /// After stop: the model is finishing what it heard; the final words come with `onFinal`.
    public private(set) var finishing = false
    /// The words so far: final ones, then the guess for what is being said now.
    public private(set) var text = ""
    /// A message to show (the model downloading, the microphone refused...).
    public private(set) var problem: String?
    /// 0...1, the loudness right now, for level bars.
    public private(set) var level: Double = 0
    /// Which way the words are being heard, for diagnosis ("SpeechTranscriber en_US", "SFSpeechRecognizer").
    public private(set) var route = ""
    /// When this run started, for an app that shows how long it has been listening.
    public private(set) var startedAt: Date?

    /// AppKit or any code without SwiftUI: the words as they change, and the final words on stop.
    public var onText: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?
    private var legacy: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyDone = false
    /// The words from the recognizers this take has already used up, so a take that outlives one
    /// of them reads as one piece of speech.
    private var carry = ""
    /// The results stream ended while the microphone is still on.
    private var segmentEnded = false
    /// How many recognizers this take went through, in `route`, so a short take says why.
    private var segments = 0

    public init() {}

    /// The injected transcript, when a test or the Simulator sets one.
    public static var injected: String? {
        if let words = ProcessInfo.processInfo.environment["GLYPH_DICTATION_TEXT"] { return words }
        // The launch argument, taken as given: read through defaults it is parsed as a property
        // list and loses commas and apostrophes.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-glyphDictationText"), i + 1 < args.count { return args[i + 1] }
        return UserDefaults.standard.string(forKey: "glyphDictationText")
    }

    /// A recording to hear instead of the microphone, through the real model (tests on a device):
    /// `GLYPH_DICTATION_AUDIO`, a path, or a name in the app's Documents folder.
    static var audioFile: URL? {
        guard let p = ProcessInfo.processInfo.environment["GLYPH_DICTATION_AUDIO"], !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? URL(filePath: p) : URL.documentsDirectory.appending(path: p)
    }

    public func toggle() { on ? stop() : start() }

    public func start() {
        guard !on else { return }
        problem = nil
        text = ""
        on = true
        startedAt = .now
        paused = false
        finished = false
        // Read once, for the whole take: the default behind `injected` is global, so a later
        // read can return someone else's words or none at all.
        taking = Self.injected
        if let words = taking {
            task = Task { [weak self] in
                var said: [Substring] = []
                for w in words.split(separator: " ") {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard let self, self.on else { return }
                    while self.paused { try? await Task.sleep(for: .milliseconds(50)) }
                    said.append(w)
                    self.text = said.joined(separator: " ")
                    self.onText?(self.text)
                    self.level = 0.4
                }
            }
            return
        }
        carry = ""
        segments = 0
        task = Task { await run() }
    }

    /// Stops listening for a moment; the words so far stay.
    public func pause() {
        guard on, !paused else { return }
        paused = true
        level = 0
        if engine.isRunning { engine.pause() }
    }

    public func resume() {
        guard on, paused else { return }
        paused = false
        if taking == nil, Self.audioFile == nil { try? engine.start() }
    }

    /// Stops listening. The model then finishes what it heard (a moment), and the final words
    /// arrive with `onFinal`; injected words arrive at once.
    public func stop() {
        guard on else { return }
        if engine.isRunning || paused {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        feed?.finish()
        feed = nil
        legacy?.endAudio()
        on = false
        paused = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let words = taking { text = words; taking = nil; finish(); return }  // a test's words arrive whole
        if task == nil { finish() } else { finishing = true }  // run() finishes after the model has
    }

    private var finished = false

    /// This take's injected words, read once in `start()`.
    private var taking: String?

    /// The final words, once per take.
    private func finish() {
        finishing = false
        task = nil
        guard !finished else { return }
        finished = true
        if !text.isEmpty { onFinal?(text) }
    }

    /// Stops with a message; always ends the take (never left "finishing").
    private func fail(_ message: String) {
        problem = message
        if on { stop() }
        finish()
    }

    private func set(_ words: String) {
        text = words
        onText?(words)
    }

    // MARK: The model

    /// The language, looked up and reserved once per launch (as Glyph Jot does): on iOS 26 an app
    /// must reserve a speech locale before it may download that locale's model.
    private static var locale: Locale?

    /// Glyph Jot's choice: the long-form SpeechTranscriber when the device has it (its model is
    /// shared by every app, so it is usually already there), else DictationTranscriber.
    private func module() async -> (any SpeechModule, AsyncThrowingStream<(String, Bool), Error>)? {
        func pieces<S: AsyncSequence & Sendable>(_ results: S, _ map: @escaping @Sendable (S.Element) -> (String, Bool)) -> AsyncThrowingStream<(String, Bool), Error> {
            AsyncThrowingStream { c in
                let t = Task { do { for try await r in results { c.yield(map(r)) }; c.finish() } catch { c.finish(throwing: error) } }
                c.onTermination = { _ in t.cancel() }
            }
        }
        if SpeechTranscriber.isAvailable {
            guard let locale = await Self.resolve({ await SpeechTranscriber.supportedLocale(equivalentTo: $0) }) else { return nil }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            route = "SpeechTranscriber \(locale.identifier)"
            return (t, pieces(t.results) { (String($0.text.characters), $0.isFinal) })
        }
        guard let locale = await Self.resolve({ await DictationTranscriber.supportedLocale(equivalentTo: $0) }) else { return nil }
        let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                     reportingOptions: [.volatileResults], attributeOptions: [])
        route = "DictationTranscriber \(locale.identifier)"
        return (t, pieces(t.results) { (String($0.text.characters), $0.isFinal) })
    }

    private static func resolve(_ supported: (Locale) async -> Locale?) async -> Locale? {
        if let locale { return locale }
        var found = await supported(.current)
        if found == nil { found = await supported(Locale(identifier: "en-US")) }
        guard let found else { return nil }
        _ = try? await AssetInventory.reserve(locale: found)  // so the model may be downloaded and is kept
        locale = found
        return found
    }

    /// The model on the device, downloading it the first time (with a message while it does).
    private func installed(_ m: any SpeechModule) async -> Bool {
        switch await AssetInventory.status(forModules: [m]) {
        case .installed: route += ", installed"; return true
        case .unsupported: route += ", unsupported"; return false
        default:
            problem = "Getting the speech model ready, one moment."
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [m]) { try? await request.downloadAndInstall() }
            let ok = await AssetInventory.status(forModules: [m]) == .installed
            route += ok ? ", downloaded" : ", download failed"
            if ok { problem = nil }
            return ok
        }
    }

    // MARK: Permission

    /// Speech recognition permission, asked once and waited for. TCC answers on its own XPC
    /// queue, so this must be built outside the main actor: a closure written anywhere in this
    /// class is main-actor code (the class is `@MainActor`), and when TCC calls it from that
    /// queue Swift's isolation check traps, on the very first talk, before a word is said
    /// (`dispatch_assert_queue` in `swift_task_isCurrentExecutor`). Same reason the audio taps
    /// are built in `nonisolated static func`s. So the callback stays off the actor and hops to
    /// the main actor itself, once it has the answer, before resuming.
    ///
    /// Any other permission with a completion handler belongs here too, built the same way.
    /// The async ones (`AVAudioApplication.requestRecordPermission()`,
    /// `AVCaptureDevice.requestAccess(for:)`) bridge safely already and need no wrapper.
    nonisolated static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                let ok = status == .authorized
                Task { @MainActor in c.resume(returning: ok) }
            }
        }
    }

    /// The one problem the person can actually do something about, and the only one a tap can
    /// clear: iOS will not ask twice, so a bare sentence about Settings is a dead end. The
    /// composer matches on this exact text and draws a button that opens the right page.
    public static let micDenied = "Allow the microphone in Settings, Privacy and Security, to talk instead of type."

    private func run() async {
        let micOK = Self.audioFile != nil ? true : await AVAudioApplication.requestRecordPermission()
        guard micOK else { return fail(Self.micDenied) }
        #if os(iOS)
        do {
            // Glyph Jot's session: alongside other audio, so a song or another app's session doesn't make it "busy".
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            let e = error as NSError
            return fail("The microphone is busy (\(e.domain) \(e.code)).")
        }
        #endif
        guard on else { return finish() }
        // One take can outlast one recognizer. A results stream ends on its own: a long take, a
        // hiccup, the older recognizer's one-minute cap. When it did, nothing said so. The engine
        // kept running, the microphone stayed lit, the tap kept feeding a stream nobody was
        // reading, and every word after that moment was gone (Fru, 2026-11-08: "it doesn't seem
        // like all my dictation was captured"). So: while he is still talking, start another one
        // and carry the words across.
        while on {
            segmentEnded = false
            guard let (m, results) = await module(), await installed(m), on, await analyze(m, results) else { break }
            guard on else { return finish() }
            carry = text
            segments += 1
            route += ", again (\(segments))"
        }
        guard on else { return finish() }
        // Apple's older on-device recognizer, when the new models can't run here.
        await recognizeLegacy()
        finish()
    }

    /// SpeechAnalyzer with the microphone (or a recording). False when it couldn't start.
    private func analyze(_ m: any SpeechModule, _ results: AsyncThrowingStream<(String, Bool), Error>) async -> Bool {
        let source = Self.audioFile.flatMap { try? AVAudioFile(forReading: $0) }
        let input = source?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        route += source != nil ? ", from a recording" : ", from the microphone"
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m], considering: input),
              let converter = AVAudioConverter(from: input, to: format) else { route += ", no audio format"; return false }
        converter.primeMethod = .none
        let analyzer = SpeechAnalyzer(modules: [m])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        let carried = carry
        let reader = Task { @MainActor [weak self] in
            var done = carried
            do {
                for try await (piece, final) in results {
                    let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if final { done = done.isEmpty ? p : done + " " + p; self?.set(done) }
                    else { self?.set(done.isEmpty ? p : done + " " + p) }
                }
            } catch {}
            // Ended, either way. Said out loud rather than swallowed, so `run` can start another
            // recognizer instead of leaving a lit microphone that nobody is listening to.
            self?.segmentEnded = true
        }
        do { try await analyzer.start(inputSequence: stream) } catch { route += ", start failed: \(error.localizedDescription)"; feed.finish(); self.feed = nil; return false }
        problem = nil
        if let source {
            // A recording, at about the speed it was said.
            let frames = AVAudioFrameCount(source.processingFormat.sampleRate / 10)
            while on, let buf = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames), (try? source.read(into: buf)) != nil, buf.frameLength > 0 {
                while paused && on { try? await Task.sleep(for: .milliseconds(50)) }
                if let out = Self.convert(buf, converter, format) { feed.yield(AnalyzerInput(buffer: out)) }
                level = Self.rms(buf)
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            // The tap runs on the audio thread: its block must not be main-actor code (a closure written here
            // would be, and Swift's isolation check traps on the first buffer on a real iPhone; the Simulator's
            // injected words never reach it). Built in a nonisolated function, as Glyph Jot does.
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input,
                                        block: Self.tap(feed, converter, format) { [weak self] rms in Task { @MainActor in self?.level = rms } })
            engine.prepare()
            do { try engine.start() } catch { fail("The microphone couldn't start."); return true }
        }
        while on && !segmentEnded { try? await Task.sleep(for: .milliseconds(100)) }
        if segmentEnded, on { engine.inputNode.removeTap(onBus: 0) }  // the next recognizer installs its own
        feed.finish()
        self.feed = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await reader.value
        return true
    }

    /// SFSpeechRecognizer, on the device only (nothing is sent), the way Glyph Jot falls back.
    private func recognizeLegacy() async {
        route += route.isEmpty ? "SFSpeechRecognizer" : " -> SFSpeechRecognizer"
        let ok = await Self.speechAuthorized()
        guard ok else { return fail("Allow speech recognition in Settings, Privacy and Security, to talk instead of type.") }
        guard let r = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), r.isAvailable,
              r.supportsOnDeviceRecognition else {
            return fail("Speech recognition on this device isn't ready. Open Settings, General, Keyboard, and turn on Dictation, then try again.")
        }
        // One request at a time, and as many as the take needs. This recognizer stops on its own
        // after about a minute of audio; the tap went on feeding the dead one and the words simply
        // stopped growing, with the microphone still lit. A take is allowed to be longer than a
        // minute, so each request hands over to the next and the words carry across.
        while on {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            legacy = request
            legacyDone = false
            let carried = carry
            // Both blocks run off the main thread: made outside the main actor (as the analyzer's tap).
            legacyTask = r.recognitionTask(with: request, resultHandler: Self.legacyHandler(
                words: { [weak self] w in Task { @MainActor in self?.set(carried.isEmpty ? w : carried + " " + w) } },
                done: { [weak self] in Task { @MainActor in self?.legacyDone = true } }))
            engine.inputNode.removeTap(onBus: 0)
            let input = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input,
                                        block: Self.legacyTap(request) { [weak self] rms in Task { @MainActor in self?.level = rms } })
            engine.prepare()
            if !engine.isRunning {
                do { try engine.start() } catch { return fail("The microphone couldn't start.") }
            }
            problem = nil
            while on && !legacyDone { try? await Task.sleep(for: .milliseconds(100)) }
            guard on else { break }
            request.endAudio()
            legacyTask?.finish()
            carry = text
            segments += 1
            route += ", again (\(segments))"
        }
        // endAudio() was sent on stop; wait a little for the final words.
        for _ in 0..<30 where !legacyDone { try? await Task.sleep(for: .milliseconds(100)) }
        legacyTask?.finish()
        legacy = nil
    }

    nonisolated static func legacyTap(_ request: SFSpeechAudioBufferRecognitionRequest, _ level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            level(rms(buffer))
        }
    }

    nonisolated static func legacyHandler(words: @escaping @Sendable (String) -> Void, done: @escaping @Sendable () -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let w = result?.bestTranscription.formattedString { words(w) }
            if result?.isFinal == true || error != nil { done() }
        }
    }

    // MARK: Self-test on a device

    nonisolated(unsafe) static var selfTested = false

    /// `GLYPH_DICTATION_SELFTEST=<seconds>` in an app's launch environment: the first talk button
    /// shown starts real dictation once (the microphone, no injected words), stops after that many
    /// seconds and prints "GLYPH-SELFTEST route=... heard=..." to the console. For checking every
    /// app on a real phone (xcrun devicectl device process launch --console).
    public func selfTestIfAsked() {
        guard !Self.selfTested, let s = ProcessInfo.processInfo.environment["GLYPH_DICTATION_SELFTEST"], let secs = Double(s) else { return }
        Self.selfTested = true
        let previous = onFinal
        onFinal = { [weak self] words in
            print("GLYPH-SELFTEST route=\(self?.route ?? "") heard=\(words)"); fflush(stdout)
            previous?(words)
        }
        Task { @MainActor [weak self] in
            // As a person would: once the app is up and active (iOS won't record for an app still launching).
            try? await Task.sleep(for: .seconds(2))
            self?.start()
            try? await Task.sleep(for: .seconds(secs))
            guard let self else { return }
            print("GLYPH-SELFTEST stopping route=\(self.route) problem=\(self.problem ?? "none") sofar=\(self.text)"); fflush(stdout)
            self.stop()
            try? await Task.sleep(for: .seconds(6))
            if self.text.isEmpty { print("GLYPH-SELFTEST route=\(self.route) heard= problem=\(self.problem ?? "none")"); fflush(stdout) }
        }
    }

    /// The microphone tap's block, made outside the main actor (it runs on the realtime audio thread).
    nonisolated static func tap(_ feed: AsyncStream<AnalyzerInput>.Continuation, _ converter: AVAudioConverter, _ format: AVAudioFormat,
                                _ level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let out = convert(buffer, converter, format) { feed.yield(AnalyzerInput(buffer: out)) }
            level(rms(buffer))
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, _ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 12)
    }
}

/// The mic. Tap to talk, tap to stop. With `text`, the words go into that text as you speak
/// (added after what is there); with `onWords`, you get them when you stop (talk to fill a form).
/// `label` shows a word beside the mic ("Talk"); without it the button is just the mic.
public struct DictateButton: View {
    /// The take itself, when the screen around the button needs it too: the composer ends the take
    /// when send is pressed and waits for the model's last words before it sends them. nil means
    /// the button keeps its own take, which is what every other mic does.
    var live: LiveDictation?
    @State private var own = LiveDictation()
    private var dictation: LiveDictation { live ?? own }
    @State private var before = ""
    /// The last thing this take wrote into the field. A take goes on writing for a moment after
    /// the microphone is off, so without this its trailing words put back a sentence that has
    /// already been sent and cleared.
    @State private var wrote: String?
    var text: Binding<String>?
    var onFinal: ((String) -> Void)?
    var label: String?
    var tint: Color
    var wide = false
    /// The artboards' mic: an 80pt disc inside a 96pt halo, the level bars while it listens.
    /// CRM's chat and Well draw the capture trio around exactly this.
    var disc = false
    /// One filled circle of this size, as the composer draws it inside the bar: a white mic on the
    /// app's green, a white stop on red while it listens. No halo, no level bars, no caption.
    /// Fru, 2026-11-09, on the bare glyph this replaced: "make it a feel green so it really stands
    /// out, because it's a prominent button that I will have to click off very often."
    var circle: CGFloat?

    /// Whether it is listening, for a bar that has to keep the mic on screen while it is (the
    /// composer swaps the mic for a send arrow the moment there are words, and the words now
    /// arrive while the mic is still running).
    var recording: Binding<Bool>?
    /// The mic's own identifier. Set it here, not on the view: while it listens the mic has a pause
    /// beside it inside this same view, and an identifier on the wrapper hides that pause from a
    /// check (`glyph.pause` could not be found until this moved onto the button itself).
    var micIdentifier: String?
    /// What a tap does, when this app's mic is not dictation. Glyph Jot's opens the recording
    /// screen, because a jot keeps its audio and its transcript, not just the words. nil dictates
    /// into `text`, which is what every other mic does. Passing an action rather than drawing a
    /// second mic is the point: there were three near-identical mic treatments at once before this.
    var instead: (() -> Void)?
    /// Why it is not hearing anything, for a bar that can show it. `.help` is a Mac tooltip and
    /// draws nothing on a phone, so without this a refused microphone, or a speech model still
    /// downloading, is a mic you tap that silently does nothing (Fru, 2026-11-09: "make sure these
    /// buttons actually work").
    var problem: Binding<String?>?

    /// Live words into `text` (after what is there); `onFinal` gets this take's words on stop.
    /// `wide`: one long full-width button, only the mic (live level bars while talking), no words.
    /// `circle`: one filled disc of that size, with the level bars and a pause beside it while it
    /// listens, which is how the composer draws it.
    public init(text: Binding<String>, label: String? = nil, tint: Color = .accentColor, wide: Bool = false,
                circle: CGFloat? = nil, recording: Binding<Bool>? = nil, micIdentifier: String? = nil,
                problem: Binding<String?>? = nil, instead: (() -> Void)? = nil,
                live: LiveDictation? = nil, onFinal: ((String) -> Void)? = nil) {
        self.text = text; self.label = label; self.tint = tint; self.onFinal = onFinal; self.wide = wide
        self.circle = circle; self.recording = recording; self.micIdentifier = micIdentifier
        self.problem = problem; self.instead = instead; self.live = live
    }
    /// Talk to fill: `onFinal` gets the words when you stop.
    public init(label: String? = "Talk", tint: Color = .accentColor, wide: Bool = false, disc: Bool = false,
                circle: CGFloat? = nil, onFinal: @escaping (String) -> Void) {
        self.onFinal = onFinal; self.label = label; self.tint = tint; self.wide = wide; self.disc = disc
        self.circle = circle
    }

    public var body: some View {
        HStack(spacing: 8) {
        // In a bar: pause, the level bars, then the mic (which is a stop while it listens). The
        // bar keeps one height, so nothing moves when talking starts (Fru, 2026-11-09: "Why don't
        // I see the waveform showing when I'm recording... And I should be able to record and
        // pause and record and pause").
        if let circle, dictation.on {
            Button { dictation.paused ? dictation.resume() : dictation.pause() } label: {
                Image(systemName: dictation.paused ? "mic.fill" : "pause.fill")
                    .font(.system(size: circle * 0.42, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: circle, height: circle)
                    .background(Color.white.opacity(0.18), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dictation.paused ? "Resume" : "Pause")
            .accessibilityIdentifier("glyph.pause")
            levelBars(height: circle * 0.6, count: 5, width: 3)
        }
        Button { if let instead { instead() } else { toggle() } } label: {
            if let circle { circleLabel(circle) } else if disc { discLabel } else if wide { wideLabel } else { smallLabel }
        }
        .buttonStyle(.plain)
        // The disc is the family's talk control, so it answers to what TalkButton said: "Talk".
        // Glyph Well asserts exactly one button with that label, and the inline mic beside a field
        // is a different thing that should not be counted as one.
        .accessibilityLabel(dictation.on ? "Stop talking"
                            : instead != nil ? "Record"
                            : (disc ? "Talk" : "Talk instead of typing"))
        .accessibilityIdentifier(micIdentifier ?? "glyph.mic")
        .help(dictation.problem ?? (dictation.on ? "Tap to stop" : "Tap and say it"))
        .onChange(of: dictation.text) { _, words in
            guard let text, dictation.on || !words.isEmpty else { return }
            guard let now = Self.fill(field: text.wrappedValue, wrote: wrote, before: before, take: words) else { return }
            wrote = now
            text.wrappedValue = now
        }
        .onAppear { if let onFinal { dictation.onFinal = { onFinal($0) } }; dictation.selfTestIfAsked() }
        .onChange(of: dictation.on) { _, on in recording?.wrappedValue = on }
        .onChange(of: dictation.problem) { _, p in problem?.wrappedValue = p }
            if wide && dictation.on {
                Button { dictation.paused ? dictation.resume() : dictation.pause() } label: {
                    Image(systemName: dictation.paused ? "play.fill" : "pause.fill").font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.paused ? "Resume" : "Pause")
                .accessibilityIdentifier("glyph.pause")
            }
        }
    }

    /// The waveform: the live input level, the same bars wherever the mic is drawn. Flat and
    /// still while paused, so a pause reads as one.
    func levelBars(height: CGFloat, count: Int, width: CGFloat) -> some View {
        let shape: [Double] = count == 5 ? [0.5, 0.85, 1.0, 0.85, 0.5]
                                         : [0.45, 0.7, 0.9, 1.0, 0.85, 1.0, 0.9, 0.7, 0.45]
        return HStack(spacing: width) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(.white.opacity(dictation.paused ? 0.4 : 1))
                    .frame(width: width, height: max(width * 1.5, height * min(1, dictation.level * 1.6 + 0.12) * shape[i]))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: dictation.level)
        .accessibilityHidden(true)
    }

    /// Jot's composer mic: one circle, red while listening, no halo.
    func circleLabel(_ d: CGFloat) -> some View {
        Image(systemName: dictation.on ? "stop.fill" : "mic.fill")
            .font(.system(size: d * 0.47, weight: .semibold)).foregroundStyle(.white)
            .frame(width: d, height: d)
            // Red is a running recording and nothing else, which is what this is.
            .background(dictation.on ? Color(red: 0.898, green: 0.282, blue: 0.302) : tint, in: Circle())
            // The disc is drawn at `d` and tapped at 44. The composer's trade was stated as a
            // smaller target than the trio's 80pt one, and it did not have to be: what Fru chose
            // was the look of a compact bar, not a 34pt touch area, which is under the 44 a finger
            // needs. The bar's own padding comes down by the same amount, so the row is the same
            // height it has always been and nothing above it moves.
            .frame(width: max(d, GlyphComposer.touch), height: max(d, GlyphComposer.touch))
            .contentShape(Circle())
    }

    /// The 96pt halo and 80pt disc the phone artboards draw, with the same level bars as `wideLabel`
    /// while it listens, so talking looks the same wherever the mic is.
    var discLabel: some View {
        ZStack {
            Circle().fill((dictation.on ? Color.red : tint).opacity(0.14)).frame(width: 96, height: 96)
            Circle().fill(dictation.on ? Color.red.opacity(0.85) : tint).frame(width: 80, height: 80)
            if dictation.on {
                levelBars(height: 30, count: 5, width: 4)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 96, height: 96)
        .contentShape(Circle())
    }

    var wideLabel: some View {
        ZStack {
            if dictation.on {
                levelBars(height: 30, count: 9, width: 4)
            } else {
                Image(systemName: "mic.fill").font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(dictation.on ? Color.red.opacity(0.85) : tint, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    var smallLabel: some View {
            HStack(spacing: 6) {
                Image(systemName: dictation.on ? "stop.fill" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: dictation.on)
                if let label { Text(dictation.on ? "Done" : label).fontWeight(.semibold) }
            }
            .font(label == nil ? .body : .body.weight(.semibold))
            .foregroundStyle(label == nil && !dictation.on ? tint : .white)
            .padding(.horizontal, label == nil ? 8 : 14)
            .frame(minWidth: 36, minHeight: 36)
            .background(label == nil && !dictation.on ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(dictation.on ? Color.red.opacity(0.85) : tint), in: .capsule)
            .contentShape(.capsule)
    }

    /// What the field holds while a take runs: what was in it before this take, then this take's
    /// words. A take is everything from tap to stop, pauses and all: `LiveDictation` keeps its
    /// `text` across `pause()` and `resume()` and only clears it on the next `start()`, which is
    /// where `before` is taken again. So each take appends and none replaces the last.
    /// What the field becomes when this take's words change, or nil when it must be left alone:
    /// somebody else has changed the field since this take last wrote to it, which is what sending
    /// does when it clears the field. The model keeps writing for a moment after the microphone is
    /// off, and those late words were putting the sent sentence straight back, so a submit looked
    /// as though it had not happened and the next one logged the same thing twice (Fru,
    /// 2026-11-10: "When I record here and I hit submit, it's not actually submitting correctly.
    /// I have to do it 2 or 3 times").
    static func fill(field: String, wrote: String?, before: String, take: String) -> String? {
        guard wrote == nil || field == wrote else { return nil }
        return joined(before: before, take: take)
    }

    static func joined(before: String, take: String) -> String {
        let b = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = take.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return t }
        if t.isEmpty { return b }
        return b + " " + t
    }

    func toggle() {
        if !dictation.on {
            before = text?.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            wrote = nil  // a new take may write again, whatever happened to the field before it
        }
        dictation.toggle()
    }
}

#if os(macOS)
public extension DictateButton {
    /// For AppKit: the button in an NSView, e.g. an NSAlert's `accessoryView` or beside a field.
    @MainActor static func hostingView(label: String? = "Talk", tint: Color = .accentColor, onFinal: @escaping (String) -> Void) -> NSView {
        let v = NSHostingView(rootView: DictateButton(label: label, tint: tint, onFinal: onFinal).padding(4))
        v.setFrameSize(v.fittingSize)
        return v
    }
}
#endif

public extension View {
    /// A mic at the trailing edge of a text field or editor: tap and talk, the words land in `text`.
    func dictatable(_ text: Binding<String>, tint: Color = .accentColor) -> some View {
        HStack(alignment: .center, spacing: 6) {
            self
            DictateButton(text: text, tint: tint)
        }
    }
}
