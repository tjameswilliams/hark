import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Unbuffered stdout so progress lines appear immediately even when piped.
setvbuf(stdout, nil, _IONBF, 0)

print("""
    ┌─────────────────────────────────────────────────────────────┐
    │  hark PTT spike #2 — push-to-talk -> paste injection path   │
    ├─────────────────────────────────────────────────────────────┤
    │  HOLD  right ⌘ (Command)  … "records" while held            │
    │  RELEASE after >=0.3 s    … pastes a canned transcript      │
    │  TAP   (<0.3 s)           … ignored in this spike           │
    │  QUIT  Ctrl-C             … tears the event tap down        │
    └─────────────────────────────────────────────────────────────┘
    """)

// ── Accessibility (TCC) check ────────────────────────────────────────────────
// Event taps that see keyboard events require the Accessibility permission.
// For a plain CLI binary, TCC attributes the request to the app that spawned
// it — i.e. your *terminal* (Terminal.app, iTerm2, VS Code, …) is what must be
// granted, not the `ptt` binary itself.
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

               …then quit and relaunch the terminal and run `ptt` again.
               Attempting to create the event tap anyway…
        """)
}

// ── Event tap ────────────────────────────────────────────────────────────────
let controller = PTTController()
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

print("[hark] event tap live. Focus any text field and hold RIGHT ⌘ …")
CFRunLoopRun()
