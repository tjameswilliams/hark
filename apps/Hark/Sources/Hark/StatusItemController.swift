import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Owns the menu-bar status item and its menu. All content that can go stale
/// (status line, cleanup line, recent dictations) is refreshed each time the
/// menu opens (menuNeedsUpdate); the status line additionally updates live
/// via the pipeline's onStateChange callback.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let pipeline: DictationPipeline
    private let meeting: MeetingController
    private let mainWindow: MainWindowController
    private let settingsWindow: SettingsWindowController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let statusLine = NSMenuItem(title: PipelineState.loadingModels.label, action: nil, keyEquivalent: "")
    private let enableItem = NSMenuItem(title: "Enable Dictation", action: nil, keyEquivalent: "")
    private let recentSubmenu = NSMenu(title: "Recent Dictations")
    private let cleanupLine = NSMenuItem(title: "Cleanup: off", action: nil, keyEquivalent: "")
    private let inputSubmenu = NSMenu(title: "Input Device")

    private let meetingStatusLine = NSMenuItem(title: "Recording meeting…", action: nil, keyEquivalent: "")
    private let meetingToggleItem = NSMenuItem(title: "Start Meeting Recording", action: nil, keyEquivalent: "")
    private let meetingsSubmenu = NSMenu(title: "Recent Meetings")
    /// 1 s tick that refreshes the elapsed-time line; runs only while a
    /// meeting recording is in progress.
    private var meetingTimer: Timer?

    private let relativeFormatter = RelativeDateTimeFormatter()
    private let isoParser = ISO8601DateFormatter()

    init(
        pipeline: DictationPipeline, meeting: MeetingController,
        mainWindow: MainWindowController, settingsWindow: SettingsWindowController
    ) {
        self.pipeline = pipeline
        self.meeting = meeting
        self.mainWindow = mainWindow
        self.settingsWindow = settingsWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // The Hark mark (docs/brand.md §2.1) as a template image, so it takes
        // the menu bar's appearance; build-app.sh copies MenuBarIcon.png and
        // its @2x into Contents/Resources. SF Symbols are the fallback if the
        // resource is missing (e.g. a bare `swift run`).
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "bird", accessibilityDescription: "Hark")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hark")
        image?.isTemplate = true
        image?.accessibilityDescription = "Hark"
        statusItem.button?.image = image
        statusItem.button?.toolTip = pipeline.tooltip

        menu.autoenablesItems = false
        menu.delegate = self
        recentSubmenu.autoenablesItems = false

        // Management window (browse/search/ask), above the dictation status.
        let openItem = NSMenuItem(
            title: "Open Hark…", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        enableItem.action = #selector(toggleDictation(_:))
        enableItem.target = self
        enableItem.state = .on
        menu.addItem(enableItem)

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentItem.submenu = recentSubmenu
        menu.addItem(recentItem)

        cleanupLine.isEnabled = false
        menu.addItem(cleanupLine)

        let inputItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        inputSubmenu.autoenablesItems = false
        inputItem.submenu = inputSubmenu
        menu.addItem(inputItem)

        // Meeting recording group.
        menu.addItem(.separator())
        meetingStatusLine.isEnabled = false
        meetingStatusLine.isHidden = true
        menu.addItem(meetingStatusLine)
        meetingToggleItem.action = #selector(toggleMeetingRecording(_:))
        meetingToggleItem.target = self
        menu.addItem(meetingToggleItem)
        let meetingsItem = NSMenuItem(title: "Recent Meetings", action: nil, keyEquivalent: "")
        meetingsSubmenu.autoenablesItems = false
        meetingsItem.submenu = meetingsSubmenu
        menu.addItem(meetingsItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(
            title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Hark", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        pipeline.onStateChange = { [weak self] _ in
            guard let self else { return }
            // statusLabel folds in the configured hotkey and mic parking;
            // the callback also fires on hotkey/parking changes.
            self.statusLine.title = self.pipeline.statusLabel
            self.statusItem.button?.toolTip = self.pipeline.tooltip
        }
        meeting.onStateChange = { [weak self] state in
            self?.meetingStateChanged(state)
        }
        rebuildRecentSubmenu()
        rebuildMeetingsSubmenu()
        refreshMeetingItems()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // Opening the menu is also a natural moment to retry the event tap
        // (e.g. the user just granted Accessibility).
        pipeline.attemptTapInstall()
        statusLine.title = pipeline.statusLabel
        statusItem.button?.toolTip = pipeline.tooltip
        cleanupLine.title = pipeline.cleanupDescription
        enableItem.state = pipeline.dictationEnabled ? .on : .off
        rebuildRecentSubmenu()
        rebuildInputSubmenu()
        rebuildMeetingsSubmenu()
        refreshMeetingItems()
    }

    // MARK: - Meeting recording

    private func meetingStateChanged(_ state: MeetingState) {
        switch state {
        case .recording:
            // .common mode so the tick fires while the menu is open
            // (menu tracking runs the runloop in a non-default mode).
            // Target/selector, not the block API — the @Sendable block would
            // need to capture this non-Sendable MainActor object.
            if meetingTimer == nil {
                let timer = Timer(
                    timeInterval: 1, target: self, selector: #selector(meetingTimerTick),
                    userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                meetingTimer = timer
            }
        case .idle:
            meetingTimer?.invalidate()
            meetingTimer = nil
        }
        refreshMeetingItems()
    }

    @objc private func meetingTimerTick() {
        refreshMeetingItems()
    }

    /// Mirrors the meeting state into the toggle title and the (hidden while
    /// idle) elapsed-time status line.
    private func refreshMeetingItems() {
        switch meeting.state {
        case .recording(let startedAt):
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            meetingStatusLine.title = String(
                format: "Recording meeting — %02d:%02d", elapsed / 60, elapsed % 60)
            meetingStatusLine.isHidden = false
            meetingToggleItem.title = "Stop Meeting Recording"
        case .idle:
            if meeting.isProcessing {
                meetingStatusLine.title = "Processing meeting… (appears in Recent Meetings when done)"
                meetingStatusLine.isHidden = false
            } else {
                meetingStatusLine.isHidden = true
            }
            meetingToggleItem.title = "Start Meeting Recording"
        }
    }

    private func rebuildMeetingsSubmenu() {
        meetingsSubmenu.removeAllItems()
        let records = meeting.recentMeetings(limit: 10)
        guard !records.isEmpty else {
            let none = NSMenuItem(title: "(none yet)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            meetingsSubmenu.addItem(none)
            return
        }
        for record in records {
            let title = record.title ?? "Meeting #\(record.id)"
            let when: String
            if let date = isoParser.date(from: record.startedAt) {
                when = relativeFormatter.localizedString(for: date, relativeTo: Date())
            } else {
                when = record.startedAt
            }
            let speakers = "\(record.speakerCount) speaker\(record.speakerCount == 1 ? "" : "s")"
            let item = NSMenuItem(
                title: "\(title) — \(when) — \(speakers)",
                action: #selector(copyMeetingTranscript(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
            item.toolTip = "Click to copy the transcript"
            meetingsSubmenu.addItem(item)
        }
    }

    private func rebuildInputSubmenu() {
        inputSubmenu.removeAllItems()

        let current = NSMenuItem(title: pipeline.inputDeviceDescription, action: nil, keyEquivalent: "")
        current.isEnabled = false
        inputSubmenu.addItem(current)
        inputSubmenu.addItem(.separator())

        let pinned = pipeline.pinnedInputUID
        let systemDefault = NSMenuItem(
            title: "Follow System Default", action: #selector(selectInput(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.state = pinned == nil ? .on : .off
        inputSubmenu.addItem(systemDefault)

        for device in pipeline.availableInputDevices() {
            let item = NSMenuItem(
                title: device.name, action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = pinned == device.uid ? .on : .off
            inputSubmenu.addItem(item)
        }
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        pipeline.selectInputDevice(uid: sender.representedObject as? String)
    }

    private func rebuildRecentSubmenu() {
        recentSubmenu.removeAllItems()
        let records = pipeline.recentDictations(limit: 10)
        guard !records.isEmpty else {
            let none = NSMenuItem(title: "(none yet)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentSubmenu.addItem(none)
            return
        }
        for record in records {
            let best = record.cleanedText ?? record.rawText
            var snippet = best
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.count > 48 {
                snippet = String(snippet.prefix(48)) + "…"
            }
            let when: String
            if let date = isoParser.date(from: record.startedAt) {
                when = relativeFormatter.localizedString(for: date, relativeTo: Date())
            } else {
                when = record.startedAt
            }
            let item = NSMenuItem(
                title: "\(snippet) — \(when)",
                action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = best
            item.toolTip = "Click to copy"
            recentSubmenu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        mainWindow.show()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func toggleDictation(_ sender: NSMenuItem) {
        pipeline.setDictationEnabled(!pipeline.dictationEnabled)
        sender.state = pipeline.dictationEnabled ? .on : .off
    }

    @objc private func toggleMeetingRecording(_ sender: NSMenuItem) {
        if meeting.isRecording {
            meeting.stopRecording()
        } else {
            meeting.startRecording()
        }
        refreshMeetingItems()
    }

    @objc private func copyMeetingTranscript(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64,
              let transcript = meeting.transcript(id: id)
        else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
        harkLog("copied the transcript of meeting #\(id) to the clipboard.")
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        harkLog("copied a recent dictation to the clipboard.")
    }

    @objc private func showPermissions() {
        let axGranted = AXIsProcessTrusted()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micMark: String
        switch micStatus {
        case .authorized: micMark = "✅"
        case .notDetermined: micMark = "❌ (not requested yet)"
        default: micMark = "❌"
        }

        let alert = NSAlert()
        alert.messageText = "Hark Permissions"
        alert.informativeText = """
            \(axGranted ? "✅" : "❌") Accessibility — needed for the right-⌘ hotkey and the ⌘V paste
            \(micMark) Microphone — needed to hear you

            Grant both to Hark in System Settings > Privacy & Security.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Microphone Settings")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .alertThirdButtonReturn:
            openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        default:
            break
        }
    }

    private func openSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        // applicationWillTerminate performs the pipeline teardown.
        NSApp.terminate(nil)
    }
}
