import SwiftUI

/// Dictation tab: which right-hand modifier is the push-to-talk key.
/// Stored as the hardware keycode in UserDefaults "pttKeycode" and applied
/// live via DictationPipeline.setPTTKeycode.
struct DictationSettingsView: View {
    let pipeline: DictationPipeline

    @State private var keycode: Int = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "pttKeycode") != nil else { return 0x36 }
        let stored = defaults.integer(forKey: "pttKeycode")
        return Int(PTTKey.forKeycode(Int64(stored)).keycode)
    }()

    var body: some View {
        Form {
            Section {
                Picker("Push-to-talk key", selection: $keycode) {
                    Text("Right Command (⌘) — default").tag(0x36)
                    Text("Right Option (⌥)").tag(0x3D)
                    Text("Right Control (⌃)").tag(0x3E)
                }
                .pickerStyle(.inline)
                .onChange(of: keycode) { _, newValue in
                    pipeline.setPTTKeycode(Int64(newValue))
                }
            } footer: {
                Text("Hold the key to dictate, release to transcribe and paste. Taps shorter than 0.3 seconds are ignored, so the key still works normally in shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
