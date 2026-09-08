import AppKit

/// Application delegate: wires the pipeline to the status item and owns the
/// app lifecycle. Hark is a menu-bar app (activation policy .accessory,
/// LSUIElement in Info.plist) — never a Dock icon: the management and
/// settings windows open with the app still in .accessory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: DictationPipeline?
    private var meetingController: MeetingController?
    private var statusController: StatusItemController?
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var meetingReviewController: MeetingReviewWindowController?
    private var knowledge: RealKnowledgeService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        harkLog("Hark 0.1.0 starting.")
        let pipeline = DictationPipeline()
        self.pipeline = pipeline
        // The store opens inside pipeline.start(); the provider closures keep
        // construction order irrelevant.
        let meeting = MeetingController(storeProvider: { pipeline.store })
        self.meetingController = meeting
        let knowledge = RealKnowledgeService(storeProvider: { pipeline.store })
        self.knowledge = knowledge
        let mainWindow = MainWindowController(knowledge: knowledge)
        self.mainWindowController = mainWindow
        let settingsWindow = SettingsWindowController(pipeline: pipeline)
        self.settingsWindowController = settingsWindow
        self.statusController = StatusItemController(
            pipeline: pipeline, meeting: meeting, mainWindow: mainWindow,
            settingsWindow: settingsWindow)
        // Every stopped recording opens the review window: processing first,
        // then name it and file it under a project.
        let review = MeetingReviewWindowController(filer: meeting)
        self.meetingReviewController = review
        meeting.onMeetingFinished = { [weak review] session in review?.show(session) }
        // Embed anything new shortly after each store, so search stays fresh.
        pipeline.onDictationStored = { [weak knowledge] in knowledge?.indexSoon() }
        meeting.onMeetingStored = { [weak knowledge] in knowledge?.indexSoon() }
        pipeline.start()
        // Index whatever accumulated while the app was closed.
        knowledge.indexSoon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingController?.teardown()
        pipeline?.teardown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
