import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// User-visible pipeline state, mirrored into the status menu.
enum PipelineState: Equatable {
    case loadingModels
    case needsAccessibility
    case ready
    case listening
    case transcribing
    case dictationDisabled
    case failed(String)

    var label: String {
        switch self {
        case .loadingModels: return "Loading models…"
        case .needsAccessibility: return "Needs Accessibility permission"
        case .ready: return "Ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .dictationDisabled: return "Dictation disabled"
        case .failed(let why): return "Startup failed: \(why)"
        }
    }
}

/// A selectable push-to-talk key: one of the right-hand modifiers. Maps the
/// hardware keycode to the CGEventFlags bit (event tap path) and the NSEvent
/// modifier flag (global-monitor fallback path) plus the menu symbol.
struct PTTKey: Sendable, Equatable {
    let keycode: Int64
    let cgFlag: CGEventFlags
    let nsFlag: NSEvent.ModifierFlags
    /// "right ⌘" — used in the status line and tooltip.
    let symbol: String

    static let rightCommand = PTTKey(
        keycode: 0x36, cgFlag: .maskCommand, nsFlag: .command, symbol: "right ⌘")
    static let rightOption = PTTKey(
        keycode: 0x3D, cgFlag: .maskAlternate, nsFlag: .option, symbol: "right ⌥")
    static let rightControl = PTTKey(
        keycode: 0x3E, cgFlag: .maskControl, nsFlag: .control, symbol: "right ⌃")
    static let all: [PTTKey] = [.rightCommand, .rightOption, .rightControl]

    /// Unknown/unset keycodes (including the 0 an absent default yields)
    /// fall back to right ⌘.
    static func forKeycode(_ keycode: Int64) -> PTTKey {
        all.first { $0.keycode == keycode } ?? .rightCommand
    }
}

/// C-compatible tap callback. Runs on the main runloop (that's where the tap's
/// runloop source is installed), so hopping to the main actor is safe.
let pttTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let pipeline = Unmanaged<DictationPipeline>.fromOpaque(refcon).takeUnretainedValue()
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    MainActor.assumeIsolated {
        pipeline.handle(type: type, keycode: keycode, flags: flags)
    }
    // Pass every event through untouched — we only observe.
    return Unmanaged.passUnretained(event)
}

/// Orchestrates the verified dictation loop (right-modifier push-to-talk ->
/// warm mic capture -> resident Parakeet transcription -> optional LLM cleanup ->
/// clipboard-swap paste) and persists each finished dictation into the Rust
/// core's SQLite store. Persistence is fail-open: a DB error never blocks the
/// paste.
@MainActor
final class DictationPipeline: NSObject {
    /// Held shorter than this counts as a tap, not push-to-talk.
    static let tapThreshold: Duration = .milliseconds(300)

    /// The push-to-talk key (UserDefaults "pttKeycode"; default right ⌘).
    /// Loaded in start(); changed live via setPTTKeycode.
    private(set) var pttKey: PTTKey = .rightCommand

    /// Set right after tap creation; needed to re-enable a disabled tap.
    private var tapPort: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    /// NSEvent global-monitor fallback, used when tap creation fails despite
    /// a granted Accessibility permission (observed on macOS 26).
    private var globalMonitor: Any?
    /// Set once model loading completes. Presses before that are refused.
    private var transcriber: Transcriber?
    /// Optional LLM cleanup pass; nil means raw transcripts paste directly.
    private var cleaner: TranscriptCleaner?
    /// Rust-core SQLite store; nil when opening failed (fail-open — the app
    /// still dictates, it just doesn't remember).
    private(set) var store: HarkStore?

    /// User dictionary, loaded from the store at start() and re-read by
    /// reloadDictionary() after every settings mutation. Drives all three
    /// correction layers: acoustic vocabulary biasing (Transcriber), cleanup
    /// prompt injection (TranscriptCleaner), and deterministic replacements
    /// (ReplacementEngine, applied before AND after cleanup).
    private var dictionaryEntries: [DictionaryEntry] = []
    private var replacementEngine = ReplacementEngine(entries: [])

    private let mic = MicCapture()
    private let pasteEngine = PasteEngine()
    /// Floating HUD capsule (waveform while listening, shimmer while
    /// transcribing/cleaning). Non-activating: never steals focus.
    private let indicator = IndicatorController()
    /// ISO8601DateFormatter defaults to UTC with a Z suffix.
    private let isoFormatter = ISO8601DateFormatter()

    private var isDown = false
    private var pressedAt: ContinuousClock.Instant?
    /// Wall-clock press time + frontmost app, captured at PRESS time for the
    /// persisted record (by release time focus may have moved).
    private var pressedDate: Date?
    private var pressedAppContext: String?
    private var busy = false
    private var capturing = false
    private var dictationTask: Task<Void, Never>?
    private var axRetryTimer: Timer?
    private var modelsReady = false
    private var startupFailure: String?

    /// Idle mic parking (UserDefaults "micIdleMinutes"; 0 = never park).
    /// When the timer expires the warm engine is torn down; the next press
    /// warms it back up inline (~250 ms) before capturing.
    private var micIdleMinutes = 0
    private var micParked = false {
        didSet { if micParked != oldValue { onStateChange?(state) } }
    }
    private var idleTimer: Timer?

    /// The "Enable Dictation" menu checkbox state.
    private(set) var dictationEnabled = true

    /// Menu line: "Cleanup: <model> @ <host>" or "Cleanup: off".
    private(set) var cleanupDescription = "Cleanup: off"

    /// Fires on every state change; the status item mirrors it into the menu.
    var onStateChange: ((PipelineState) -> Void)?
    /// Fires after a dictation is persisted (used to kick background indexing).
    var onDictationStored: (() -> Void)?
    private(set) var state: PipelineState = .loadingModels {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var accessibilityGranted: Bool { tapPort != nil || globalMonitor != nil }

    /// Status-line text for the menu: the state label, with the ready line
    /// carrying the configured hotkey ("Ready — hold right ⌘") and the parked
    /// mic surfaced explicitly.
    var statusLabel: String {
        guard state == .ready else { return state.label }
        if micParked { return "Mic paused (press \(pttKey.symbol) to wake)" }
        return "Ready — hold \(pttKey.symbol)"
    }

    /// Tooltip for the status-item button.
    var tooltip: String { "Hark — hold \(pttKey.symbol) to dictate" }

    // MARK: - Startup

    func start() {
        openStore()
        loadDictionary()
        // Meetings get the same deterministic replacements as dictations.
        // The provider reads the store fresh at process time, so dictionary
        // edits apply to the next meeting without extra plumbing (HarkStore
        // is Sendable — its DB handle is mutex-guarded in Rust).
        if let store {
            MeetingProcessor.replacementProvider = { (try? store.listDictionary()) ?? [] }
        }
        mic.pinnedDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        pttKey = PTTKey.forKeycode(Int64(UserDefaults.standard.integer(forKey: "pttKeycode")))
        micIdleMinutes = UserDefaults.standard.integer(forKey: "micIdleMinutes")

        // Accessibility (TCC) check, with the system prompt on first launch.
        // Note: the literal key equals kAXTrustedCheckOptionPrompt; the
        // imported C global is a `var` and trips Swift 6 strict concurrency
        // if referenced from main-actor code.
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        if !trusted {
            harkLog("""
                Accessibility permission not granted (yet). Grant Hark in
                System Settings > Privacy & Security > Accessibility; the
                event tap will be retried automatically every 5 s.
                """)
        }
        attemptTapInstall()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            harkLog("microphone permission: granted.")
        case .notDetermined:
            harkLog("microphone permission: not determined — expect a prompt at mic warm-up.")
        case .denied, .restricted:
            harkLog("""
                microphone permission: DENIED. Capture will yield silence. Fix:
                System Settings > Privacy & Security > Microphone -> enable Hark.
                """)
        @unknown default:
            harkLog("microphone permission: unknown status.")
        }

        // Async startup: load models once, warm the mic, then announce ready.
        Task { @MainActor in
            do {
                harkLog("loading Parakeet TDT v3 (cached at ~/Library/Application Support/FluidAudio/Models) …")
                let loadStart = ContinuousClock.now
                let transcriber = try await Transcriber.load()
                harkLog(String(
                    format: "models loaded & resident in %.2f s.",
                    (ContinuousClock.now - loadStart).secondsValue))

                // Block on the mic prompt BEFORE starting the engine: an
                // AVAudioEngine started pre-grant delivers silence forever
                // even after the user grants (observed in the field).
                let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
                if !micGranted {
                    harkLog("microphone permission denied — Hark can't hear until it's enabled in System Settings > Privacy & Security > Microphone.")
                }

                let warmupMs = try mic.warmUp()
                harkLog(String(
                    format: "mic engine warm in %.0f ms (%@); it stays running between dictations.",
                    warmupMs, mic.inputDescription))

                self.transcriber = transcriber
                // Vocabulary biasing initializes in the background: the CTC
                // model download (dictionary non-empty only) must not delay
                // readiness, and a failure inside just means plain
                // transcription (logged in setVocabulary).
                let dictionarySnapshot = self.dictionaryEntries
                if !dictionarySnapshot.filter(\.enabled).isEmpty {
                    Task { await transcriber.setVocabulary(dictionarySnapshot) }
                }
                let cleaner = await TranscriptCleaner.fromDefaults()
                self.cleaner = cleaner
                self.cleanupDescription = cleaner.map { "Cleanup: \($0.menuDescription)" } ?? "Cleanup: off"
                self.modelsReady = true
                harkLog("ready — hold \(self.pttKey.symbol) and speak")
                self.scheduleIdleTimer()
                refreshState()
            } catch {
                harkLog("startup failed: \(error)")
                self.startupFailure = "\(error)"
                refreshState()
            }
        }
    }

    private func openStore() {
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0]
            let dir = appSupport.appendingPathComponent("Hark", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbURL = dir.appendingPathComponent("hark.sqlite")
            let store = try HarkStore.open(path: dbURL.path)
            let count = (try? store.dictationCount()) ?? 0
            harkLog("store open at \(dbURL.path) (\(count) dictation(s) on record).")
            self.store = store
        } catch {
            harkLog("WARNING: could not open the dictation store — history disabled: \(error)")
        }
    }

    // MARK: - Event tap install / retry

    /// Creates the CGEventTap if it doesn't exist yet. Safe to call
    /// repeatedly — the Accessibility retry timer and menu-open hook both
    /// funnel through here until the tap is live.
    func attemptTapInstall() {
        guard tapPort == nil, globalMonitor == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: pttTapCallback,
            userInfo: refcon
        ) else {
            if AXIsProcessTrusted() {
                // The macOS 26-era failure mode: permission granted, tap
                // creation still refused (worst with ad-hoc signing / after
                // in-place re-grants). Fall back to an NSEvent global
                // monitor — same Accessibility gate, different plumbing.
                harkLog("""
                    event tap creation FAILED even though Accessibility is \
                    granted — falling back to an NSEvent global monitor.
                    """)
                installGlobalMonitorFallback()
            } else {
                // Missing Accessibility permission; keep retrying.
                scheduleAXRetry()
            }
            refreshState()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            harkLog("FAILED to create runloop source for the event tap.")
            CFMachPortInvalidate(tap)
            scheduleAXRetry()
            refreshState()
            return
        }
        tapPort = tap
        tapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: dictationEnabled)
        axRetryTimer?.invalidate()
        axRetryTimer = nil
        harkLog("event tap live.")
        refreshState()
    }

    /// Same Accessibility gate as the tap, different delivery plumbing. The
    /// monitor observes only (can't consume events) — which is all PTT needs.
    private func installGlobalMonitorFallback() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keycode = Int64(event.keyCode)
            let nsFlags = event.modifierFlags
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationEnabled else { return }
                    // Translate the NSEvent modifier state into the CGEventFlags
                    // bit handle() matches for the configured hotkey.
                    let down = nsFlags.contains(self.pttKey.nsFlag)
                    self.handle(
                        type: .flagsChanged,
                        keycode: keycode,
                        flags: down ? self.pttKey.cgFlag : [])
                }
            }
        }
        if globalMonitor != nil {
            axRetryTimer?.invalidate()
            axRetryTimer = nil
            harkLog("global monitor live (fallback hotkey path).")
        } else {
            harkLog("global monitor installation ALSO failed — will keep retrying the tap.")
            scheduleAXRetry()
        }
    }

    private func scheduleAXRetry() {
        guard axRetryTimer == nil else { return }
        // Target/selector (not the block API): the @Sendable block would need
        // to capture this non-Sendable MainActor object. The timer fires on
        // the main runloop, so the @objc @MainActor selector is safe.
        axRetryTimer = Timer.scheduledTimer(
            timeInterval: 5, target: self, selector: #selector(axRetryTick),
            userInfo: nil, repeats: true)
    }

    @objc private func axRetryTick() {
        attemptTapInstall()
    }

    // MARK: - Input device selection

    var pinnedInputUID: String? {
        UserDefaults.standard.string(forKey: "inputDeviceUID")
    }

    /// "Input: <device>" line for the menu.
    var inputDeviceDescription: String {
        "Input: \(mic.activeDeviceName)\(pinnedInputUID == nil ? " (system default)" : "")"
    }

    func availableInputDevices() -> [AudioInputDevice] {
        AudioInputDevices.list()
    }

    /// Pins capture to a device (nil = follow the system default) and
    /// restarts the audio engine so the change takes effect immediately.
    func selectInputDevice(uid: String?) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
        } else {
            UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
        }
        mic.pinnedDeviceUID = uid
        guard mic.isWarm else { return }
        mic.teardown()
        do {
            let ms = try mic.warmUp()
            harkLog(String(
                format: "input device changed — engine rebound in %.0f ms (%@).",
                ms, mic.inputDescription))
        } catch {
            harkLog("FAILED to restart the audio engine on the new input device: \(error)")
        }
        refreshState()
    }

    // MARK: - Enable/disable

    func setDictationEnabled(_ enabled: Bool) {
        guard enabled != dictationEnabled else { return }
        dictationEnabled = enabled
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: enabled)
        }
        if !enabled, isDown {
            // Mid-hold disable: drop the capture on the floor.
            isDown = false
            pressedAt = nil
            pressedDate = nil
            pressedAppContext = nil
            capturing = false
            _ = mic.endCapture()
            indicator.hide()
        }
        harkLog("dictation \(enabled ? "enabled" : "disabled").")
        refreshState()
    }

    // MARK: - Settings (hotkey, idle parking, cleanup reload)

    /// Live hotkey change from the Settings window. Persists "pttKeycode"
    /// and swaps the matched keycode/flag immediately — no restart needed.
    func setPTTKeycode(_ keycode: Int64) {
        let key = PTTKey.forKeycode(keycode)
        UserDefaults.standard.set(Int(key.keycode), forKey: "pttKeycode")
        guard key != pttKey else { return }
        if isDown {
            // Mid-hold change (can only happen via the settings UI): drop the
            // capture on the floor rather than strand a stuck "listening".
            isDown = false
            pressedAt = nil
            pressedDate = nil
            pressedAppContext = nil
            capturing = false
            _ = mic.endCapture()
            indicator.hide()
        }
        pttKey = key
        harkLog("push-to-talk key changed to \(key.symbol).")
        refreshState()
        onStateChange?(state)  // state may be unchanged but the label isn't
    }

    /// Live idle-parking change from the Settings window (0 = never park).
    func setMicIdleMinutes(_ minutes: Int) {
        let clamped = max(0, minutes)
        UserDefaults.standard.set(clamped, forKey: "micIdleMinutes")
        micIdleMinutes = clamped
        if clamped == 0, micParked {
            // Feature switched off while parked: wake the mic now so the
            // status line doesn't advertise a pause that can't recur.
            _ = wakeParkedMic()
        }
        scheduleIdleTimer()
    }

    /// Re-reads the cleanup UserDefaults (cleanupEnabled/URL/Model/APIKey/
    /// TimeoutMs/Reasoning) and swaps the cleaner; called when the Settings
    /// window closes or applies. Takes effect on the next dictation.
    func reloadCleaner() {
        Task { @MainActor in
            let cleaner = await TranscriptCleaner.fromDefaults()
            self.cleaner = cleaner
            self.cleanupDescription = cleaner.map { "Cleanup: \($0.menuDescription)" } ?? "Cleanup: off"
            harkLog("cleanup settings reloaded — \(self.cleanupDescription.lowercased()).")
        }
    }

    /// Reads the dictionary from the store and rebuilds the deterministic
    /// ReplacementEngine. Fail-open: a store problem means an empty
    /// dictionary, never a broken pipeline.
    private func loadDictionary() {
        guard let store else { return }
        do {
            dictionaryEntries = try store.listDictionary()
            replacementEngine = ReplacementEngine(entries: dictionaryEntries)
            let enabled = dictionaryEntries.filter(\.enabled).count
            if enabled > 0 {
                harkLog("dictionary: \(enabled) enabled term(s) loaded.")
            }
        } catch {
            harkLog("WARNING: could not read the dictionary: \(error)")
            dictionaryEntries = []
            replacementEngine = ReplacementEngine(entries: [])
        }
    }

    /// Re-reads the dictionary and re-informs every layer: the replacement
    /// engine (immediately), the transcriber's vocabulary-boosting session
    /// (async — may download CTC models on first use), and the cleanup
    /// prompt (picked up on the next dictation via dictionaryEntries).
    /// The Dictionary settings tab calls this after every mutation.
    func reloadDictionary() {
        loadDictionary()
        if let transcriber {
            let snapshot = dictionaryEntries
            Task { await transcriber.setVocabulary(snapshot) }
        }
    }

    /// (Re)starts the one-shot idle timer. Called after every dictation and
    /// whenever the setting changes; a 0/parked/cold mic means no timer.
    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard micIdleMinutes > 0, !micParked else { return }
        // Target/selector, not the block API (same Swift 6 pattern as the
        // Accessibility retry timer): fires on the main runloop.
        idleTimer = Timer.scheduledTimer(
            timeInterval: Double(micIdleMinutes) * 60, target: self,
            selector: #selector(idleTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func idleTimerFired() {
        guard micIdleMinutes > 0, !micParked, mic.isWarm else { return }
        guard !capturing, !busy else {
            // Mid-dictation expiry: not idle after all — rearm.
            scheduleIdleTimer()
            return
        }
        mic.teardown()
        micParked = true
        harkLog("mic paused after \(micIdleMinutes) min idle — press \(pttKey.symbol) to wake it.")
    }

    /// Warms the parked engine back up inline (~250 ms — the press handler is
    /// synchronous and the audio loss is the pre-speech beat, not words).
    /// Returns false when the warm-up failed; the press should be refused.
    private func wakeParkedMic() -> Bool {
        do {
            let ms = try mic.warmUp()
            micParked = false
            harkLog(String(format: "mic woken from idle pause in %.0f ms.", ms))
            return true
        } catch {
            harkLog("FAILED to wake the paused mic: \(error) — press ignored. It will be retried on the next press.")
            return false
        }
    }

    // MARK: - State

    private func refreshState() {
        if let startupFailure {
            state = .failed(startupFailure)
        } else if !dictationEnabled {
            state = .dictationDisabled
        } else if busy {
            state = .transcribing
        } else if capturing {
            state = .listening
        } else if tapPort == nil {
            state = .needsAccessibility
        } else if !modelsReady {
            state = .loadingModels
        } else {
            state = .ready
        }
    }

    // MARK: - Hotkey handling (verified in the dictation spike)

    func handle(type: CGEventType, keycode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that stall (or when secure input kicks
            // in). Re-enabling immediately is mandatory or we go deaf forever.
            if let tapPort, dictationEnabled {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                harkLog("event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabled.")
            }
        case .flagsChanged:
            guard dictationEnabled, keycode == pttKey.keycode else { return }
            let modifierDown = flags.contains(pttKey.cgFlag)
            if modifierDown, !isDown {
                isDown = true
                pressed()
            } else if !modifierDown, isDown {
                isDown = false
                released()
            }
        default:
            break
        }
    }

    private func pressed() {
        guard transcriber != nil else {
            harkLog("not ready yet (models still loading) — press ignored.")
            return
        }
        guard !busy else {
            harkLog("still processing the previous dictation — press ignored.")
            return
        }
        if micParked {
            // Idle-parked engine: warm it back up inline before capturing.
            guard wakeParkedMic() else { return }
        }
        guard mic.isWarm else {
            harkLog("not ready yet (mic still warming up) — press ignored.")
            return
        }
        scheduleIdleTimer()
        pressedAt = ContinuousClock.now
        pressedDate = Date()
        // App context at PRESS time: the app the user is dictating into.
        pressedAppContext = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        capturing = true
        mic.beginCapture()
        indicator.show(.listening) { [mic] in mic.currentLevel() }
        harkLog("listening… (release \(pttKey.symbol) to transcribe & paste)")
        refreshState()
    }

    private func released() {
        guard let pressedAt else { return }  // press was refused; nothing to do
        let releasedAt = ContinuousClock.now
        let held = pressedAt.duration(to: releasedAt)
        let startedDate = pressedDate ?? Date()
        let endedDate = Date()
        let appContext = pressedAppContext
        self.pressedAt = nil
        self.pressedDate = nil
        self.pressedAppContext = nil

        capturing = false
        let capture = mic.endCapture()

        if held < Self.tapThreshold {
            harkLog(String(
                format: "tap ignored (%.0f ms < %d ms threshold) — audio discarded.",
                held.millisecondsValue, 300))
            indicator.hide()
            refreshState()
            return
        }

        if let firstBufferAt = capture.firstBufferAt {
            let activeAfter = pressedAt.duration(to: firstBufferAt)
            harkLog(String(
                format: "press -> capture-active: %.1f ms (warm engine)",
                activeAfter.millisecondsValue))
        }

        let samples = capture.samples
        let captureSeconds = Double(samples.count) / AudioSpec.sampleRate
        harkLog(String(
            format: "held %.0f ms — captured %.2f s of audio (%d samples).",
            held.millisecondsValue, captureSeconds, samples.count))

        guard samples.count >= AudioSpec.minimumSamples else {
            harkLog("""
                capture produced almost no audio — not transcribing.
                If this keeps happening, the microphone permission is the
                usual culprit: System Settings > Privacy & Security >
                Microphone -> enable Hark.
                """)
            indicator.hide()
            refreshState()
            return
        }

        // All-silence guard: TCC-denied input often delivers buffers of zeros.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-5 else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                // Permission IS granted, so this engine was almost certainly
                // started before the grant landed — a pre-grant AVAudioEngine
                // delivers zeros forever. Restart it; the next hold hears.
                harkLog("""
                    captured audio is pure silence but the mic permission is
                    granted — restarting the audio engine (it was likely
                    started before the grant). Try dictating again.
                    """)
                mic.teardown()
                if let ms = try? mic.warmUp() {
                    harkLog(String(format: "audio engine restarted, warm in %.0f ms.", ms))
                } else {
                    harkLog("audio engine restart FAILED — try quitting and reopening Hark.")
                }
            } else {
                harkLog("""
                    captured audio is pure silence (peak amplitude ~0) — not
                    transcribing. Check Hark's microphone permission (System
                    Settings > Privacy & Security > Microphone) and that the
                    right input device is selected.
                    """)
            }
            indicator.hide()
            refreshState()
            return
        }

        guard let transcriber else {
            indicator.hide()
            return
        }
        busy = true
        indicator.transition(to: .transcribing)
        refreshState()
        dictationTask = Task {
            do {
                let result = try await transcriber.transcribe(samples)
                harkLog(String(
                    format: "transcribed in %.0f ms (%.1fx real-time).",
                    result.transcribeSeconds * 1000, result.rtfx))

                var rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawText.isEmpty {
                    harkLog("empty transcript — nothing to paste.")
                } else {
                    harkLog("transcript: \"\(rawText)\"")
                    // Deterministic dictionary replacements on the raw
                    // transcript BEFORE cleanup (the LLM sees corrected
                    // input) …
                    let pre = replacementEngine.applyReporting(rawText)
                    for hit in pre.fired {
                        harkLog("dictionary: \(hit.alias) -> \(hit.term)")
                    }
                    rawText = pre.text
                    var text = rawText
                    var cleanedForStore: String?
                    if let cleaner {
                        indicator.transition(to: .cleaning)
                        let outcome = await cleaner.clean(rawText, dictionary: dictionaryEntries)
                        if outcome.cleaned {
                            // … and on the cleanup output AFTER, so the LLM
                            // can never regress a dictionary rule.
                            let post = replacementEngine.applyReporting(outcome.text)
                            for hit in post.fired {
                                harkLog("dictionary: \(hit.alias) -> \(hit.term)")
                            }
                            harkLog(String(
                                format: "cleaned in %.0f ms: \"%@\"",
                                outcome.elapsed.millisecondsValue, post.text))
                            text = post.text
                            // Persist the cleaned text only when it differs.
                            if post.text != rawText { cleanedForStore = post.text }
                        } else {
                            harkLog(String(
                                format: "cleanup failed open (%@ after %.0f ms) — pasting raw transcript.",
                                outcome.failure ?? "unknown", outcome.elapsed.millisecondsValue))
                        }
                    }
                    // PasteEngine reports release -> paste-complete, which now
                    // includes transcription + cleanup: the end-to-end latency.
                    await pasteEngine.paste(text: text, releasedAt: releasedAt)

                    // Persist AFTER the paste so a DB problem can never delay
                    // or lose the dictation itself (fail-open, like cleanup).
                    persist(
                        raw: rawText, cleaned: cleanedForStore, appContext: appContext,
                        startedAt: startedDate, endedAt: endedDate,
                        durationMs: Int64(held.millisecondsValue.rounded()))
                }
            } catch {
                harkLog("transcription failed: \(error)")
            }
            // One hide for every task outcome: paste done, empty transcript,
            // or transcription error.
            indicator.hide()
            busy = false
            // The dictation just finished — restart the idle countdown.
            scheduleIdleTimer()
            refreshState()
        }
    }

    // MARK: - Persistence

    private func persist(
        raw: String, cleaned: String?, appContext: String?,
        startedAt: Date, endedAt: Date, durationMs: Int64
    ) {
        guard let store else { return }
        do {
            let id = try store.recordDictation(
                rawText: raw,
                cleanedText: cleaned,
                appContext: appContext,
                startedAt: isoFormatter.string(from: startedAt),
                endedAt: isoFormatter.string(from: endedAt),
                durationMs: durationMs)
            harkLog("dictation #\(id) stored.")
            onDictationStored?()
        } catch {
            harkLog("WARNING: failed to store dictation (paste unaffected): \(error)")
        }
    }

    /// Last `limit` dictations, newest first; empty on any store problem.
    func recentDictations(limit: UInt32) -> [DictationRecord] {
        guard let store else { return [] }
        do {
            return try store.recentDictations(limit: limit)
        } catch {
            harkLog("WARNING: could not read recent dictations: \(error)")
            return []
        }
    }

    // MARK: - Teardown

    func teardown() {
        indicator.hide()
        dictationTask?.cancel()
        axRetryTimer?.invalidate()
        axRetryTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        mic.teardown()
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
            self.tapRunLoopSource = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        harkLog("mic stopped, event tap torn down. bye.")
    }
}
