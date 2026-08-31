// InferenceSpike: prove out NVIDIA Parakeet TDT v3 via FluidAudio for Hark.
// Usage: swift run inference <path-to-audio-file>

import AVFoundation
import FluidAudio
import Foundation

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: inference <audio-file>\n".utf8))
    exit(64)
}
let audioURL = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: audioURL.path) else {
    FileHandle.standardError.write(Data("error: no such file: \(audioURL.path)\n".utf8))
    exit(66)
}

do {
    // Audio duration (for real-time factor).
    let audioFile = try AVAudioFile(forReading: audioURL)
    let audioDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

    print("audio file:       \(audioURL.path)")
    print(String(format: "audio duration:   %.2f s", audioDuration))

    // Model download + load (Parakeet TDT v3, multilingual).
    print("model cache:      \(AsrModels.defaultCacheDirectory(for: .v3).path)")
    print("loading models (downloads on first run; cached afterwards)...")
    let loadStart = ContinuousClock.now
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let loadTime = seconds(ContinuousClock.now - loadStart)
    print(String(format: "model load time:  %.2f s (includes download on first run)", loadTime))

    let asrManager = AsrManager(config: .default)
    try await asrManager.loadModels(models)

    // Transcribe. As of FluidAudio 0.15.x the caller owns the decoder state.
    var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
    let transcribeStart = ContinuousClock.now
    let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)
    let transcribeTime = seconds(ContinuousClock.now - transcribeStart)

    print("")
    print("transcript:")
    print("  \(result.text)")
    print("")
    print(String(format: "transcription:    %.3f s wall time", transcribeTime))
    print(String(format: "real-time factor: %.1fx (audio duration / transcribe time)",
                 audioDuration / transcribeTime))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
