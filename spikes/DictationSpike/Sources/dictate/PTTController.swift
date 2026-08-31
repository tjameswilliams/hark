import AppKit
import CoreGraphics
import Foundation

/// C-compatible tap callback. Runs on the main runloop (that's where the tap's
/// runloop source is installed), so hopping to the main actor is safe.
let pttTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<PTTController>.fromOpaque(refcon).takeUnretainedValue()
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    MainActor.assumeIsolated {
        controller.handle(type: type, keycode: keycode, flags: flags)
    }
    // Pass every event through untouched — we only observe.
    return Unmanaged.passUnretained(event)
}

/// Tracks right-command press/release and drives capture -> transcribe -> paste.
@MainActor
final class PTTController {
    /// kVK_RightCommand. (Left command is 0x37.)
    static let rightCommandKeycode: Int64 = 0x36
    /// Held shorter than this counts as a tap, not push-to-talk.
    static let tapThreshold: Duration = .milliseconds(300)

    /// Set right after tap creation; needed to re-enable a disabled tap.
    var tapPort: CFMachPort?
    /// Set once model loading completes. Presses before that are refused.
    var transcriber: Transcriber?
    /// Optional LLM cleanup pass; nil means raw transcripts paste directly.
    var cleaner: TranscriptCleaner?

    private let mic: MicCapture
    private let pasteEngine = PasteEngine()
    private var isDown = false
    private var pressedAt: ContinuousClock.Instant?
    private var busy = false
    private var dictationTask: Task<Void, Never>?

    init(mic: MicCapture) {
        self.mic = mic
    }

    func handle(type: CGEventType, keycode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that stall (or when secure input kicks
            // in). Re-enabling immediately is mandatory or we go deaf forever.
            if let tapPort {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                print("[hark] event tap was disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabled.")
            }
        case .flagsChanged:
            guard keycode == Self.rightCommandKeycode else { return }
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
            print("[hark] not ready yet (models/mic still warming up) — press ignored.")
            return
        }
        guard !busy else {
            print("[hark] still processing the previous dictation — press ignored.")
            return
        }
        pressedAt = ContinuousClock.now
        mic.beginCapture()
        print("[hark] listening… (release right ⌘ to transcribe & paste)")
    }

    private func released() {
        guard let pressedAt else { return }  // press was refused; nothing to do
        let releasedAt = ContinuousClock.now
        let held = pressedAt.duration(to: releasedAt)
        self.pressedAt = nil

        let capture = mic.endCapture()

        if held < Self.tapThreshold {
            print(String(
                format: "[hark] tap ignored (%.0f ms < %d ms threshold) — audio discarded.",
                held.millisecondsValue, 300))
            return
        }

        if let firstBufferAt = capture.firstBufferAt {
            let activeAfter = pressedAt.duration(to: firstBufferAt)
            print(String(
                format: "[hark] press -> capture-active: %.1f ms (warm engine)",
                activeAfter.millisecondsValue))
        }

        let samples = capture.samples
        let captureSeconds = Double(samples.count) / AudioSpec.sampleRate
        print(String(
            format: "[hark] held %.0f ms — captured %.2f s of audio (%d samples).",
            held.millisecondsValue, captureSeconds, samples.count))

        guard samples.count >= AudioSpec.minimumSamples else {
            print("""
                [hark] capture produced almost no audio — not transcribing.
                       If this keeps happening, the microphone permission is the
                       usual culprit: System Settings > Privacy & Security >
                       Microphone -> enable your terminal app, then relaunch it.
                """)
            return
        }

        // All-silence guard: TCC-denied input often delivers buffers of zeros.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-5 else {
            print("""
                [hark] captured audio is pure silence (peak amplitude ~0) — not
                       transcribing. Check the mic permission for your terminal
                       (System Settings > Privacy & Security > Microphone) and
                       that the right input device is selected.
                """)
            return
        }

        guard let transcriber else { return }
        busy = true
        dictationTask = Task {
            do {
                let result = try await transcriber.transcribe(samples)
                print(String(
                    format: "[hark] transcribed in %.0f ms (%.1fx real-time).",
                    result.transcribeSeconds * 1000, result.rtfx))

                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    print("[hark] empty transcript — nothing to paste.")
                } else {
                    print("[hark] transcript: \"\(text)\"")
                    if let cleaner {
                        let outcome = await cleaner.clean(text)
                        if outcome.cleaned {
                            print(String(
                                format: "[hark] cleaned in %.0f ms: \"%@\"",
                                outcome.elapsed.millisecondsValue, outcome.text))
                            text = outcome.text
                        } else {
                            print(String(
                                format: "[hark] cleanup failed open (%@ after %.0f ms) — pasting raw transcript.",
                                outcome.failure ?? "unknown", outcome.elapsed.millisecondsValue))
                        }
                    }
                    // PasteEngine prints release -> paste-complete, which now
                    // includes transcription + cleanup: the end-to-end latency.
                    await pasteEngine.paste(text: text, releasedAt: releasedAt)
                }
            } catch {
                print("[hark] transcription failed: \(error)")
            }
            busy = false
        }
    }

    func teardown() {
        dictationTask?.cancel()
        mic.teardown()
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
        print("\n[hark] mic stopped, event tap torn down. bye.")
    }
}
