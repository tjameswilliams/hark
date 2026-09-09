import ServiceManagement
import SwiftUI

/// General tab: launch at login (SMAppService) and idle mic parking
/// (UserDefaults "micIdleMinutes", 0 = never; applied live via
/// DictationPipeline.setMicIdleMinutes).
struct GeneralSettingsView: View {
    let pipeline: DictationPipeline

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    @State private var silenceEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: MeetingController.silenceMinutesKey) == nil
            || d.integer(forKey: MeetingController.silenceMinutesKey) > 0
    }()
    @State private var silenceMinutes: Int = {
        let stored = UserDefaults.standard.integer(forKey: MeetingController.silenceMinutesKey)
        return stored > 0 ? stored : MeetingController.defaultSilenceMinutes
    }()

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
                Toggle("Ask to stop meeting recordings after silence", isOn: $silenceEnabled)
                    .onChange(of: silenceEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue ? silenceMinutes : 0,
                                                  forKey: MeetingController.silenceMinutesKey)
                    }
                if silenceEnabled {
                    Stepper(value: $silenceMinutes, in: 1...60) {
                        Text("After \(silenceMinutes) minute\(silenceMinutes == 1 ? "" : "s") without anyone speaking")
                    }
                    .onChange(of: silenceMinutes) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: MeetingController.silenceMinutesKey)
                    }
                }
            } footer: {
                Text("When a call ends, its recording usually keeps running. Hark watches both the microphone and the system audio; once both have been quiet this long it asks whether to stop. Say yes and it makes the transcript and opens the meeting so you can name it and file it; say no and it will not ask again until sound has come and gone once more. The question withdraws itself if sound resumes. A recording with no sound at all is asked about after ten minutes.")
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
