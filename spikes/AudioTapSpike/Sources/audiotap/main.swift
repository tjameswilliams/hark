//
//  main.swift
//  audiotap spike
//
//  Usage: audiotap [seconds] [output.wav]
//

import CoreAudio
import Foundation

// Set from the C signal handler; sampled by the polling loop below.
nonisolated(unsafe) var gShouldStop = false

// Keep stdout ordered with the stderr log lines when output is piped.
setvbuf(stdout, nil, _IONBF, 0)

let arguments = CommandLine.arguments
let duration = arguments.count > 1 ? (Double(arguments[1]) ?? 10) : 10
let outputPath = arguments.count > 2 ? arguments[2] : "capture.wav"
let outputURL = URL(fileURLWithPath: outputPath)

print("""
audiotap spike — system audio (process tap) + microphone -> stereo WAV
  duration: \(duration)s   output: \(outputURL.path)
  channel 0 = microphone, channel 1 = system-audio mixdown

Permissions:
  * Microphone: a standard mic TCC prompt may appear (attributed to your
    terminal app). Approve it, then re-run if the first run captured silence.
  * System audio: needs "System Audio Recording Only" under
    System Settings > Privacy & Security > Screen & System Audio Recording,
    granted to your TERMINAL app (Terminal/iTerm/etc.) since this is an
    unbundled CLI. DENIAL IS SILENT: Core Audio still returns noErr and
    delivers all-zero buffers. Check the peak levels printed at exit.

Play some audio (music, a video) and speak into the mic while it records.
Press Ctrl-C to stop early.
""")

signal(SIGINT) { _ in
    gShouldStop = true
}

let recorder = Recorder()

do {
    try recorder.start()
} catch {
    log("FATAL: \(error)")
    exit(1)
}

let deadline = Date().addingTimeInterval(duration)
while !gShouldStop && Date() < deadline {
    usleep(100_000)
}
if gShouldStop { log("SIGINT received, stopping early") }

let samples = recorder.stop()

if samples.isEmpty {
    log("no audio frames were captured — the IOProc never fired.")
    log("likely causes: no default input/output device, or device creation failed.")
    exit(2)
}

do {
    try WavFile.write(
        to: outputURL,
        samples: samples,
        channels: 2,
        sampleRate: Int(recorder.sampleRate.rounded())
    )
    log("wrote \(outputURL.path) (\(samples.count / 2) frames @ \(Int(recorder.sampleRate.rounded())) Hz)")
} catch {
    log("FATAL: could not write WAV: \(error)")
    exit(1)
}

// Zero-buffer diagnostics: TCC denial for system audio is SILENT (noErr +
// all-zero buffers), so peak levels are the only reliable signal.
func describePeak(_ name: String, _ peak: Float, hint: String) {
    let db = peak > 0 ? 20 * log10(peak) : -Float.infinity
    let dbText = peak > 0 ? String(format: "%.1f dBFS", db) : "-inf dBFS"
    print(String(format: "  %-22s peak %.6f  (%@)", (name as NSString).utf8String!, peak, dbText))
    if peak < 1e-6 {
        print("    -> channel was ALL ZEROS — \(hint)")
    }
}

print("\nPeak levels:")
describePeak(
    "ch0 (microphone):", recorder.peakMic,
    hint: "likely mic permission denied, mic muted, or nobody spoke."
)
describePeak(
    "ch1 (system audio):", recorder.peakSystem,
    hint: "likely System Audio Recording permission denied for your terminal, or no audio was playing."
)

if recorder.peakMic >= 1e-6 && recorder.peakSystem >= 1e-6 {
    print("\nSUCCESS: both channels contain signal. Inspect \(outputURL.path) to verify.")
}
