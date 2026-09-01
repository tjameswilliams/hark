import ServiceManagement
import SwiftUI

/// General tab: launch at login (SMAppService) and idle mic parking
/// (UserDefaults "micIdleMinutes", 0 = never; applied live via
/// DictationPipeline.setMicIdleMinutes).
struct GeneralSettingsView: View {
    let pipeline: DictationPipeline

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    @State private var idleEnabled: Bool =
        UserDefaults.standard.integer(forKey: "micIdleMinutes") > 0
    @State private var idleMinutes: Int = {
        let stored = UserDefaults.standard.integer(forKey: "micIdleMinutes")
        return stored > 0 ? stored : 15
    }()

    var body: some View {
        Form {
            Section {
                Toggle("Launch Hark at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } footer: {
                Text("Hark lives in the menu bar, so starting it at login keeps dictation one keypress away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause microphone when idle", isOn: $idleEnabled)
                    .onChange(of: idleEnabled) { _, newValue in
                        pipeline.setMicIdleMinutes(newValue ? idleMinutes : 0)
                    }
                if idleEnabled {
                    Stepper(value: $idleMinutes, in: 1...240) {
                        Text("After \(idleMinutes) minute\(idleMinutes == 1 ? "" : "s") without dictating")
                    }
                    .onChange(of: idleMinutes) { _, newValue in
                        pipeline.setMicIdleMinutes(newValue)
                    }
                }
            } footer: {
                Text("Hark keeps the audio engine warm for instant capture. Pausing releases the microphone (and its indicator light) after a quiet stretch; the next press wakes it in about a quarter second.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
            harkLog("launch at login \(enable ? "enabled" : "disabled").")
        } catch {
            loginError = "Couldn't \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            harkLog("launch-at-login change failed: \(error)")
            // Reflect what the system actually thinks.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
