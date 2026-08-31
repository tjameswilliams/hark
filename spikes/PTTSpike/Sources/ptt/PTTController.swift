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

/// Tracks right-command press/release and drives the paste sequence.
@MainActor
final class PTTController {
    /// kVK_RightCommand. (Left command is 0x37.)
    static let rightCommandKeycode: Int64 = 0x36
    /// Held shorter than this counts as a tap, not push-to-talk.
    static let tapThreshold: Duration = .milliseconds(300)

    /// Set right after tap creation; needed to re-enable a disabled tap.
    var tapPort: CFMachPort?

    private let engine = PasteEngine()
    private var isDown = false
    private var pressedAt: ContinuousClock.Instant?
    private var pasteTask: Task<Void, Never>?

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
                pressedAt = ContinuousClock.now
                print("[hark] listening… (release right-command to paste)")
            } else if !commandDown, isDown {
                isDown = false
                released()
            }
        default:
            break
        }
    }

    private func released() {
        guard let pressedAt else { return }
        let releasedAt = ContinuousClock.now
        let held = pressedAt.duration(to: releasedAt)
        self.pressedAt = nil

        if held < Self.tapThreshold {
            print("[hark] tap ignored (toggle mode not in this spike)")
            return
        }

        let heldMs = Double(held.components.seconds) * 1000
            + Double(held.components.attoseconds) / 1e15
        print(String(format: "[hark] held %.0f ms — pasting…", heldMs))

        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        let text = "[hark] dictated at \(timestamp)"
        pasteTask = Task { [engine] in
            await engine.paste(text: text, releasedAt: releasedAt)
        }
    }

    func teardown() {
        pasteTask?.cancel()
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
        print("\n[hark] event tap torn down. bye.")
    }
}
