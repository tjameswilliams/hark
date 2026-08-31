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
        case .ready: return "Ready — hold right ⌘"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .dictationDisabled: return "Dictation disabled"
        case .failed(let why): return "Startup failed: \(why)"
        }
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

/// Orchestrates the verified dictation loop (right-⌘ push-to-talk -> warm mic
/// capture -> resident Parakeet transcription -> optional LLM cleanup ->
/// clipboard-swap paste) and persists each finished dictation into the Rust
/// core's SQLite store. Persistence is fail-open: a DB error never blocks the
/// paste.
@MainActor
final class DictationPipeline: NSObject {
    /// kVK_RightCommand. (Left command is 0x37.)
    static let rightCommandKeycode: Int64 = 0x36
    /// Held shorter than this counts as a tap, not push-to-talk.
    static let tapThreshold: Duration = .milliseconds(300)

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

    private let mic = MicCapture()
    private let pasteEngine = PasteEngine()
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

    /// The "Enable Dictation" menu checkbox state.
    private(set) var dictationEnabled = true

    /// Menu line: "Cleanup: <model> @ <host>" or "Cleanup: off".
    private(set) var cleanupDescription = "Cleanup: off"

    /// Fires on every state change; the status item mirrors it into the menu.
    var onStateChange: ((PipelineState) -> Void)?
    private(set) var state: PipelineState = .loadingModels {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var accessibilityGranted: Bool { tapPort != nil || globalMonitor != nil }

    // MARK: - Startup

    func start() {
        openStore()
        mic.pinnedDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID")

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
                let cleaner = await TranscriptCleaner.fromDefaults()
                self.cleaner = cleaner
                self.cleanupDescription = cleaner.map { "Cleanup: \($0.menuDescription)" } ?? "Cleanup: off"
                self.modelsReady = true
                harkLog("ready — hold right ⌘ and speak")
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
            let commandDown = event.modifierFlags.contains(.command)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationEnabled else { return }
                    self.handle(
                        type: .flagsChanged,
                        keycode: keycode,
                        flags: commandDown ? .maskCommand : [])
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
        }
        harkLog("dictation \(enabled ? "enabled" : "disabled").")
        refreshState()
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
            guard dictationEnabled, keycode == Self.rightCommandKeycode else { return }
            let commandDown = flags.contains(.maskCommand)
            if commandDown, !isDown {
                isDown = true
                pressed()
            } else if !commandDown, isDown {
                isDown = false
                released()
            }
        default:
            break
        }
    }

    private func pressed() {
        guard transcriber != nil, mic.isWarm else {
            harkLog("not ready yet (models/mic still warming up) — press ignored.")
            return
        }
        guard !busy else {
            harkLog("still processing the previous dictation — press ignored.")
            return
        }
        pressedAt = ContinuousClock.now
        pressedDate = Date()
        // App context at PRESS time: the app the user is dictating into.
        pressedAppContext = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        capturing = true
        mic.beginCapture()
        harkLog("listening… (release right ⌘ to transcribe & paste)")
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
            refreshState()
            return
        }

        guard let transcriber else { return }
        busy = true
        refreshState()
        dictationTask = Task {
            do {
                let result = try await transcriber.transcribe(samples)
                harkLog(String(
                    format: "transcribed in %.0f ms (%.1fx real-time).",
                    result.transcribeSeconds * 1000, result.rtfx))

                let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawText.isEmpty {
                    harkLog("empty transcript — nothing to paste.")
                } else {
                    harkLog("transcript: \"\(rawText)\"")
                    var text = rawText
                    var cleanedForStore: String?
                    if let cleaner {
                        let outcome = await cleaner.clean(rawText)
                        if outcome.cleaned {
                            harkLog(String(
                                format: "cleaned in %.0f ms: \"%@\"",
                                outcome.elapsed.millisecondsValue, outcome.text))
                            text = outcome.text
                            // Persist the cleaned text only when it differs.
                            if outcome.text != rawText { cleanedForStore = outcome.text }
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
            busy = false
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
        dictationTask?.cancel()
        axRetryTimer?.invalidate()
        axRetryTimer = nil
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
