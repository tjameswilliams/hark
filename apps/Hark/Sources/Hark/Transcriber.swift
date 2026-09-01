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
///
/// When the user dictionary has enabled entries, a CTC vocabulary-boosting
/// session (FluidAudio's `VocabularyBoostingSession`: parakeet-ctc-110m
/// keyword spotter + acoustic rescorer, the "Approach 2" pipeline from
/// Documentation/ASR/CustomVocabulary.md) runs after each plain transcription
/// and corrects dictionary terms the TDT decoder misspelled — gated on
/// acoustic evidence, so "Aisha" becomes "Ayesha" only when the audio
/// supports it. With an empty dictionary the session is nil and the
/// transcribe path is byte-for-byte the plain one.
final class Transcriber: Sendable {
    private let manager: AsrManager
    private let decoderLayers: Int

    /// Lock-guarded vocabulary state: swapped live by setVocabulary(), read
    /// per-transcription. The CTC models are cached across dictionary edits
    /// so a settings tweak doesn't reload ~97.5 MB of CoreML.
    private final class VocabularyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: VocabularyBoostingSession?
        private var _ctcModels: CtcModels?
        private var _generation = 0

        var session: VocabularyBoostingSession? {
            lock.withLock { _session }
        }
        var cachedModels: CtcModels? {
            lock.withLock { _ctcModels }
        }
        /// Bumps the generation and returns the token a later commit must
        /// present — stale async rebuilds are dropped.
        func beginUpdate() -> Int {
            lock.withLock {
                _generation += 1
                return _generation
            }
        }
        /// Returns false when a newer update superseded this one.
        @discardableResult
        func commit(_ session: VocabularyBoostingSession?, models: CtcModels?, generation: Int) -> Bool {
            lock.withLock {
                guard generation == _generation else { return false }
                _session = session
                if let models { _ctcModels = models }
                return true
            }
        }
    }

    private let vocabulary = VocabularyBox()

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

    // MARK: - Custom vocabulary (user dictionary)

    /// Rebuilds the vocabulary-boosting session from the user dictionary.
    /// Lazy and failure-tolerant: the CTC model download only happens when
    /// there are enabled entries, and any failure just leaves plain
    /// transcription in place (dictation must never break because of the
    /// dictionary). Safe to call repeatedly; concurrent calls resolve to the
    /// newest.
    func setVocabulary(_ entries: [DictionaryEntry]) async {
        let generation = vocabulary.beginUpdate()
        let enabled = entries.filter(\.enabled)
        guard !enabled.isEmpty else {
            if vocabulary.commit(nil, models: nil, generation: generation),
               vocabulary.cachedModels != nil {
                harkLog("dictionary: vocabulary biasing off (no enabled entries).")
            }
            return
        }
        do {
            let ctcModels: CtcModels
            if let cached = vocabulary.cachedModels {
                ctcModels = cached
            } else {
                harkLog("""
                    dictionary: loading CTC vocabulary-boosting models \
                    (parakeet-ctc-110m, ~97.5 MB download on first use)…
                    """)
                let start = ContinuousClock.now
                ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                harkLog(String(
                    format: "dictionary: CTC models ready in %.2f s.",
                    (ContinuousClock.now - start).secondsValue))
            }
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
            let terms = enabled.compactMap { entry -> CustomVocabularyTerm? in
                let tokenIds = tokenizer.encode(entry.term)
                guard !tokenIds.isEmpty else { return nil }
                return CustomVocabularyTerm(
                    text: entry.term,
                    aliases: entry.aliases.isEmpty ? nil : entry.aliases,
                    ctcTokenIds: tokenIds)
            }
            guard !terms.isEmpty else {
                vocabulary.commit(nil, models: ctcModels, generation: generation)
                harkLog("dictionary: no tokenizable terms — vocabulary biasing off.")
                return
            }
            // Disable the spotter-anchored acoustic rescue (FluidAudio #724):
            // with a small personal dictionary over ordinary dictation it
            // over-fires badly (verified on the fixture: "The quick brown"
            // -> "Ayesha"). The similarity-gated rescoring path still fires
            // on real mishearings (string similarity + stronger CTC
            // evidence), and Layers 2/3 (cleanup prompt, deterministic
            // aliases) cover heavily-mangled cases deterministically.
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms),
                ctcModels: ctcModels,
                config: VocabularyRescorer.Config(spotterRescueEnabled: false))
            if vocabulary.commit(session, models: ctcModels, generation: generation) {
                harkLog("dictionary: vocabulary biasing active for \(terms.count) term(s).")
            }
        } catch {
            vocabulary.commit(nil, models: nil, generation: generation)
            harkLog("""
                dictionary: vocabulary biasing unavailable (\(error)) — \
                plain transcription continues.
                """)
        }
    }

    // MARK: - Transcription

    /// Transcribes raw 16 kHz mono Float32 samples via FluidAudio 0.15.x's
    /// direct samples API:
    ///   AsrManager.transcribe(_ audioSamples: [Float],
    ///                         decoderState: inout TdtDecoderState)
    /// A fresh decoder state per call — each dictation is an independent
    /// utterance. When a vocabulary session is active, the transcript is then
    /// rescored against CTC acoustic evidence (session.rescore is fail-open:
    /// it logs and returns nil on any internal error).
    func transcribe(_ samples: [Float]) async throws -> DictationResult {
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let start = ContinuousClock.now
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        var text = result.text

        if let session = vocabulary.session,
           let timings = result.tokenTimings, !timings.isEmpty {
            if let rescored = await session.rescore(
                text: text, tokenTimings: timings, audioSamples: samples),
               rescored.wasModified {
                for replacement in rescored.replacements where replacement.shouldReplace {
                    harkLog(
                        "dictionary (acoustic): \(replacement.originalWord) -> \(replacement.replacementWord ?? "?")"
                    )
                }
                text = rescored.text
            }
        }

        let elapsed = (ContinuousClock.now - start).secondsValue
        return DictationResult(
            text: text,
            audioSeconds: Double(samples.count) / AudioSpec.sampleRate,
            transcribeSeconds: elapsed
        )
    }
}
