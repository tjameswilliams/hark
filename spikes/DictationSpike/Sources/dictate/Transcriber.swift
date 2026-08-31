import FluidAudio
import Foundation

struct DictationResult {
    let text: String
    let audioSeconds: Double
    let transcribeSeconds: Double

    /// Real-time factor: audio duration / transcription wall time.
    var rtfx: Double { audioSeconds / max(transcribeSeconds, 1e-9) }
}

/// Wraps a resident FluidAudio AsrManager (Parakeet TDT v3). Models are
/// loaded once at startup and reused for every dictation.
final class Transcriber: Sendable {
    private let manager: AsrManager
    private let decoderLayers: Int

    private init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// Downloads (first run only — already cached on this machine) and loads
    /// the Parakeet TDT v3 CoreML models, then keeps the AsrManager resident.
    static func load() async throws -> Transcriber {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        return Transcriber(manager: manager, decoderLayers: layers)
    }

    /// Transcribes raw 16 kHz mono Float32 samples via FluidAudio 0.15.x's
    /// direct samples API:
    ///   AsrManager.transcribe(_ audioSamples: [Float],
    ///                         decoderState: inout TdtDecoderState)
    /// A fresh decoder state per call — each dictation is an independent
    /// utterance.
    func transcribe(_ samples: [Float]) async throws -> DictationResult {
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let start = ContinuousClock.now
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let elapsed = (ContinuousClock.now - start).secondsValue
        return DictationResult(
            text: result.text,
            audioSeconds: Double(samples.count) / AudioSpec.sampleRate,
            transcribeSeconds: elapsed
        )
    }
}
