import AppKit

/// Application delegate: wires the pipeline to the status item and owns the
/// app lifecycle. Hark is a menu-bar-only app (activation policy .accessory,
/// LSUIElement in Info.plist) — no dock icon, no main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: DictationPipeline?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        harkLog("Hark 0.1.0 starting.")
        let pipeline = DictationPipeline()
        self.pipeline = pipeline
        self.statusController = StatusItemController(pipeline: pipeline)
        pipeline.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.teardown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
