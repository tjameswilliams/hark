import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

// NOTE: top-level code here is deliberately synchronous (no top-level await).
// A top-level await would turn this into an async main whose body runs as a
// MainActor task; calling CFRunLoopRun() from inside that task would occupy
// the main queue and starve every other MainActor task (the dictation and
// paste tasks). With synchronous top-level code + CFRunLoopRun(), the runloop
// drains the main queue and MainActor tasks run fine — this is the pattern
// the PTT spike verified on this machine.

// Unbuffered stdout so progress lines appear immediately even when piped.
setvbuf(stdout, nil, _IONBF, 0)

// ── Single-instance guard ────────────────────────────────────────────────────
// Two concurrent instances each own an event tap and a mic stream, so one
// dictation gets transcribed and pasted twice (with slightly different
// capture windows). An exclusive flock on a well-known path prevents it; the
// lock releases automatically when the process exits, however it exits.
// Headless runs (HARK_NO_TAP=1: smoke tests, selftests) have no event tap and
// can't double-paste, so they may coexist with a live instance.
let lockPath = NSString(string: "~/.hark-dictate.lock").expandingTildeInPath
let headless = ProcessInfo.processInfo.environment["HARK_NO_TAP"] == "1"
let lockFD = headless ? -1 : open(lockPath, O_CREAT | O_RDWR, 0o644)
if !headless, lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    let otherPID = (try? String(contentsOfFile: lockPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    print("""
        [hark] another `dictate` instance is already running (pid \(otherPID)) —
               a second one would paste every dictation twice. Exiting.
               (Find it with `pgrep -fl dictate`; quit it with Ctrl-C or `kill`.)
        """)
    exit(1)
}
ftruncate(lockFD, 0)
_ = String(ProcessInfo.processInfo.processIdentifier).withCString {
    write(lockFD, $0, strlen($0))
}

print("""
    ┌──────────────────────────────────────────────────────────────┐
    │  hark dictation spike — the real headline loop               │
    ├──────────────────────────────────────────────────────────────┤
    │  HOLD  right ⌘ (Command)  … captures the default microphone  │
    │  RELEASE after >=0.3 s    … Parakeet transcribes -> pastes   │
    │  TAP   (<0.3 s)           … ignored                          │
    │  QUIT  Ctrl-C             … clean teardown                   │
    └──────────────────────────────────────────────────────────────┘
    """)

// ── Accessibility (TCC) check ────────────────────────────────────────────────
// Event taps that see keyboard events require the Accessibility permission.
// For a plain CLI binary, TCC attributes the request to the app that spawned
// it — i.e. your *terminal* (Terminal.app, iTerm2, VS Code, …) is what must be
// granted, not the `dictate` binary itself.
// Set HARK_NO_AX_PROMPT=1 to check without popping the system dialog.
let promptForAX = ProcessInfo.processInfo.environment["HARK_NO_AX_PROMPT"] != "1"
let trusted: Bool =
    if promptForAX {
        // Note: the literal key equals kAXTrustedCheckOptionPrompt; the imported
        // C global is a `var` and trips Swift 6 strict concurrency if referenced
        // from main-actor top-level code.
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    } else {
        AXIsProcessTrusted()
    }

if !trusted {
    print("""
        [hark] Accessibility permission NOT granted (yet).
               Because this is a CLI, macOS attributes the permission to the app
               that launched it — your terminal. To fix:

                 System Settings > Privacy & Security > Accessibility
                 -> enable (or add via "+") your terminal app
                 (Terminal.app / iTerm2 / VS Code / Ghostty / …)

               …then quit and relaunch the terminal and run `dictate` again.
               Attempting to create the event tap anyway…
        """)
}

// ── Microphone (TCC) status ──────────────────────────────────────────────────
// The mic prompt fires when the audio engine first starts (during warm-up
// below) and is likewise attributed to the terminal.
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    print("[hark] microphone permission: granted.")
case .notDetermined:
    print("[hark] microphone permission: not determined — expect a prompt (grant it to your terminal).")
case .denied, .restricted:
    print("""
        [hark] microphone permission: DENIED for this terminal. Capture will
               yield silence. Fix: System Settings > Privacy & Security >
               Microphone -> enable your terminal, then relaunch it.
        """)
@unknown default:
    print("[hark] microphone permission: unknown status.")
}

// ── Event tap ────────────────────────────────────────────────────────────────
let mic = MicCapture()
let controller = PTTController(mic: mic)

// HARK_NO_TAP=1 skips event-tap creation entirely: a headless smoke test of
// model load + mic warm-up in environments without Accessibility (e.g. CI or
// a sandboxed shell). No hotkey works in this mode.
if ProcessInfo.processInfo.environment["HARK_NO_TAP"] == "1" {
    print("[hark] HARK_NO_TAP=1 — skipping event tap (headless smoke test; hotkey disabled).")
    // Without the tap's runloop source, CFRunLoopRun() would return as soon
    // as the startup Task finishes and the process would exit. A far-future
    // timer keeps the runloop alive so Ctrl-C teardown is still exercised.
    let keepAlive = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 0, 0, 0
    ) { _ in }
    CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, .commonModes)
} else {
    let refcon = Unmanaged.passUnretained(controller).toOpaque()
    let mask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: pttTapCallback,
        userInfo: refcon
    ) else {
        print("""
            [hark] FAILED to create the CGEventTap.
                   This is almost always missing Accessibility permission (see above).
                   Grant it to your terminal, restart the terminal, and re-run.
                   Exiting.
            """)
        exit(1)
    }
    controller.tapPort = tap

    guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        print("[hark] FAILED to create runloop source for the tap. Exiting.")
        exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[hark] event tap live.")
}

// ── Clean Ctrl-C teardown ────────────────────────────────────────────────────
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    MainActor.assumeIsolated {
        controller.teardown()
    }
    exit(0)
}
sigintSource.resume()

// ── Async startup: load models once, warm the mic, then announce ready ──────
// (Scheduled on the main actor; runs as soon as CFRunLoopRun() below spins.)
Task { @MainActor in
    do {
        print("[hark] loading Parakeet TDT v3 (cached at ~/Library/Application Support/FluidAudio/Models) …")
        let loadStart = ContinuousClock.now
        let transcriber = try await Transcriber.load()
        print(String(
            format: "[hark] models loaded & resident in %.2f s.",
            (ContinuousClock.now - loadStart).secondsValue))

        let warmupMs = try mic.warmUp()
        print(String(
            format: "[hark] mic engine warm in %.0f ms (%@); it stays running between dictations.",
            warmupMs, mic.inputDescription))

        controller.transcriber = transcriber
        let cleaner = await TranscriptCleaner.fromEnvironment()
        controller.cleaner = cleaner

        // HARK_SELFTEST=<audio-file>: transcribe a file through the exact
        // samples-API path a live dictation uses (cleanup included when
        // configured), print the result, and exit. Verifies the
        // resident-model pipeline without a hotkey press.
        if let testPath = ProcessInfo.processInfo.environment["HARK_SELFTEST"] {
            print("[hark] selftest: transcribing \(testPath) via the samples API …")
            let samples = try loadSamples16k(from: URL(fileURLWithPath: testPath))
            let result = try await transcriber.transcribe(samples)
            print(String(
                format: "[hark] selftest: %.2f s audio -> %.0f ms transcription (%.1fx real-time)",
                result.audioSeconds, result.transcribeSeconds * 1000, result.rtfx))
            print("[hark] selftest transcript: \"\(result.text)\"")
            if let cleaner {
                let outcome = await cleaner.clean(result.text)
                print(String(
                    format: "[hark] selftest cleanup (%@, %.0f ms): \"%@\"",
                    outcome.cleaned ? "ok" : "failed open: \(outcome.failure ?? "?")",
                    outcome.elapsed.millisecondsValue, outcome.text))
            }
            controller.teardown()
            exit(0)
        }

        print("[hark] ready — hold right ⌘ and speak")
    } catch {
        print("[hark] startup failed: \(error)")
        controller.teardown()
        exit(1)
    }
}

CFRunLoopRun()
// Only reachable if the runloop runs out of sources/timers — should not
// happen in normal operation (the tap source or keep-alive timer pins it).
print("[hark] runloop exited unexpectedly — shutting down.")
