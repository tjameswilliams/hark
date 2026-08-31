import AppKit

// NOTE (carried over from the dictation spike): top-level code here is
// deliberately synchronous — no top-level await. A top-level await would turn
// this into an async main whose body runs as a MainActor task; blocking the
// main queue from inside that task starves every other MainActor task (the
// dictation and paste tasks). Here NSApplication.run() owns the main runloop
// instead of CFRunLoopRun(): it drains the main queue the same way, MainActor
// tasks (model loading, transcription, paste) run fine, and the CGEventTap
// source installed on the main runloop fires as in the spike.

// Unbuffered stdout so progress lines appear immediately even when piped.
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
// Menu-bar app: no dock icon, no app switcher entry. (LSUIElement in
// Info.plist covers bundle launches; this covers running the bare binary.)
app.setActivationPolicy(.accessory)

// Top-level `let` is a global, so the delegate outlives this scope
// (NSApplication.delegate is a weak reference).
let delegate = AppDelegate()
app.delegate = delegate

app.run()
