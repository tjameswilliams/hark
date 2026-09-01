import AppKit
import SwiftUI

// The Settings window: dictation hotkey, transcript cleanup, general app
// behavior, and the "Connect to AI tools" (MCP) walkthrough. Same pattern as
// MainWindowController: one reusable code-only NSWindowController hosting a
// SwiftUI root, shown from the status menu. The app stays .accessory — no
// Dock icon; HarkMainWindow routes the ⌘-key equivalents itself.

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let pipeline: DictationPipeline

    init(pipeline: DictationPipeline) {
        self.pipeline = pipeline
        let window = HarkMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Hark Settings"
        window.isReleasedWhenClosed = false   // one reusable window
        window.minSize = NSSize(width: 560, height: 480)
        window.center()
        window.setFrameAutosaveName("HarkSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsRootView(pipeline: pipeline))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsWindowController is code-only") }

    /// Opens (or raises) the window and brings Hark to the foreground.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Cleanup edits are written to UserDefaults as they're typed; the
        // cleaner itself is rebuilt here so changes apply on the next
        // dictation without a restart.
        pipeline.reloadCleaner()
    }
}

// MARK: - Root layout

struct SettingsRootView: View {
    let pipeline: DictationPipeline

    var body: some View {
        TabView {
            DictationSettingsView(pipeline: pipeline)
                .tabItem { Label("Dictation", systemImage: "mic") }
            CleanupSettingsView(pipeline: pipeline)
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            GeneralSettingsView(pipeline: pipeline)
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettingsView()
                .tabItem { Label("AI Tools", systemImage: "terminal") }
        }
        .frame(minWidth: 540, minHeight: 440)
    }
}
