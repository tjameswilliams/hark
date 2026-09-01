import SwiftUI

/// Cleanup tab: the LLM transcript-cleanup endpoint. Fields are bound to the
/// same UserDefaults keys Cleanup.swift reads (cleanupEnabled, cleanupURL,
/// cleanupModel, cleanupAPIKey, cleanupTimeoutMs, cleanupReasoning); edits
/// persist as you type and take effect on the next dictation — the pipeline
/// rebuilds its cleaner when the Settings window closes.
struct CleanupSettingsView: View {
    let pipeline: DictationPipeline

    @State private var enabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "cleanupEnabled") == nil
            ? true : defaults.bool(forKey: "cleanupEnabled")
    }()
    @State private var url: String =
        UserDefaults.standard.string(forKey: "cleanupURL") ?? ""
    @State private var model: String =
        UserDefaults.standard.string(forKey: "cleanupModel") ?? ""
    @State private var apiKey: String =
        UserDefaults.standard.string(forKey: "cleanupAPIKey") ?? ""
    @State private var timeoutMs: Int = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "cleanupTimeoutMs") == nil
            ? 3000 : defaults.integer(forKey: "cleanupTimeoutMs")
    }()
    @State private var reasoning: String =
        UserDefaults.standard.string(forKey: "cleanupReasoning") ?? "none"

    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult {
        case ok(latencyMs: Double, sample: String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts with an LLM", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "cleanupEnabled")
                    }
            } footer: {
                Text("Fixes punctuation and removes filler words via any OpenAI-compatible /chat/completions endpoint (LM Studio, Ollama, or a cloud API). Fail-open: if the server is down or slow, the raw transcript pastes unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Endpoint") {
                TextField("Base URL", text: $url, prompt: Text("http://localhost:1234/v1"))
                    .autocorrectionDisabled()
                    .onChange(of: url) { _, newValue in
                        setOrRemove(newValue, forKey: "cleanupURL")
                    }
                TextField("Model", text: $model, prompt: Text("auto-detect from the server"))
                    .autocorrectionDisabled()
                    .onChange(of: model) { _, newValue in
                        setOrRemove(newValue, forKey: "cleanupModel")
                    }
                SecureField("API key", text: $apiKey, prompt: Text("optional"))
                    .onChange(of: apiKey) { _, newValue in
                        setOrRemove(newValue, forKey: "cleanupAPIKey")
                    }
                TextField("Timeout (ms)", value: $timeoutMs, format: .number.grouping(.never))
                    .onChange(of: timeoutMs) { _, newValue in
                        UserDefaults.standard.set(max(100, newValue), forKey: "cleanupTimeoutMs")
                    }
                Picker("Reasoning effort", selection: $reasoning) {
                    Text("None (fastest)").tag("none")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Server default").tag("default")
                }
                .onChange(of: reasoning) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "cleanupReasoning")
                }
            }

            Section {
                HStack {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let testResult {
                    switch testResult {
                    case .ok(let latencyMs, let sample):
                        Label(
                            String(format: "OK — %.0f ms. \"%@\"", latencyMs, sample),
                            systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    case .failed(let why):
                        Label(why, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Sends a one-line completion to the endpoint using the settings above. Changes apply to the next dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Empty/whitespace values remove the key so Cleanup.swift's defaults
    /// (default URL, auto-detected model, no bearer token) kick back in.
    private func setOrRemove(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// The fields are already persisted, so the test exercises the exact
    /// configuration a dictation would use: TranscriptCleaner.fromDefaults()
    /// (which probes /models when no model is set) plus one tiny completion.
    private func runTest() {
        testing = true
        testResult = nil
        let wasEnabled = enabled
        Task { @MainActor in
            defer { testing = false }
            if !wasEnabled {
                // Test the endpoint even while cleanup is toggled off:
                // fromDefaults() would bail early, so flip the key around
                // the probe only.
                UserDefaults.standard.set(true, forKey: "cleanupEnabled")
            }
            let cleaner = await TranscriptCleaner.fromDefaults()
            if !wasEnabled {
                UserDefaults.standard.set(false, forKey: "cleanupEnabled")
            }
            guard let cleaner else {
                testResult = .failed("No server reachable at \(urlOrDefault) (and no model set).")
                return
            }
            let outcome = await cleaner.clean("so um this is is a test of the cleanup endpoint")
            if outcome.cleaned {
                var sample = outcome.text.replacingOccurrences(of: "\n", with: " ")
                if sample.count > 60 { sample = String(sample.prefix(60)) + "…" }
                testResult = .ok(latencyMs: outcome.elapsed.millisecondsValue, sample: sample)
            } else {
                testResult = .failed(
                    String(format: "%@ (%.0f ms) — model %@ @ %@",
                           outcome.failure ?? "unknown failure",
                           outcome.elapsed.millisecondsValue,
                           cleaner.model, cleaner.baseURL.absoluteString))
            }
        }
    }

    private var urlOrDefault: String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://localhost:1234/v1" : trimmed
    }
}
