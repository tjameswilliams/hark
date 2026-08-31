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
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let statusLine = NSMenuItem(title: PipelineState.loadingModels.label, action: nil, keyEquivalent: "")
    private let enableItem = NSMenuItem(title: "Enable Dictation", action: nil, keyEquivalent: "")
    private let recentSubmenu = NSMenu(title: "Recent Dictations")
    private let cleanupLine = NSMenuItem(title: "Cleanup: off", action: nil, keyEquivalent: "")
    private let inputSubmenu = NSMenu(title: "Input Device")

    private let relativeFormatter = RelativeDateTimeFormatter()
    private let isoParser = ISO8601DateFormatter()

    init(pipeline: DictationPipeline) {
        self.pipeline = pipeline
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // SF Symbol "bird", template so it adapts to menu bar appearance;
        // "waveform" is the fallback on systems without the bird symbol.
        let image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Hark")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hark")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Hark — hold right ⌘ to dictate"

        menu.autoenablesItems = false
        menu.delegate = self
        recentSubmenu.autoenablesItems = false

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

        let permissionsItem = NSMenuItem(
            title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Hark", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        pipeline.onStateChange = { [weak self] state in
            self?.statusLine.title = state.label
        }
        rebuildRecentSubmenu()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // Opening the menu is also a natural moment to retry the event tap
        // (e.g. the user just granted Accessibility).
        pipeline.attemptTapInstall()
        statusLine.title = pipeline.state.label
        cleanupLine.title = pipeline.cleanupDescription
        enableItem.state = pipeline.dictationEnabled ? .on : .off
        rebuildRecentSubmenu()
        rebuildInputSubmenu()
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

    @objc private func toggleDictation(_ sender: NSMenuItem) {
        pipeline.setDictationEnabled(!pipeline.dictationEnabled)
        sender.state = pipeline.dictationEnabled ? .on : .off
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
