import AppKit

/// Application delegate: wires the pipeline to the status item and owns the
/// app lifecycle. Hark is a menu-bar-only app (activation policy .accessory,
/// LSUIElement in Info.plist) — no dock icon, no main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: DictationPipeline?
    private var meetingController: MeetingController?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        harkLog("Hark 0.1.0 starting.")
        let pipeline = DictationPipeline()
        self.pipeline = pipeline
        // The store opens inside pipeline.start(); the provider closure keeps
        // construction order irrelevant.
        let meeting = MeetingController(storeProvider: { pipeline.store })
        self.meetingController = meeting
        self.statusController = StatusItemController(pipeline: pipeline, meeting: meeting)
        pipeline.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingController?.teardown()
        pipeline?.teardown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
