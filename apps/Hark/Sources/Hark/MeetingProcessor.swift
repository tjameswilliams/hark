@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Offline meeting processing: diarization (FluidAudio OfflineDiarizerManager,
/// falling back to the streaming DiarizerManager) + transcription (FluidAudio
/// AsrManager, Parakeet TDT v3), merged into speaker-attributed utterances,
/// plus a voiceprint per speaker for cross-meeting identity.
///
/// The whole file is self-contained apart from the types in MeetingTypes.
/// Progress is reported solely through the `progress` closure.
@MainActor
final class MeetingProcessor {

    /// Injectable dictionary source for deterministic replacements on
    /// utterance texts — meetings deserve correct names too. Set once at
    /// startup (DictationPipeline.start() points it at the store); nil means
    /// no replacements. Written once before any processing happens and read
    /// from the pipeline task, hence nonisolated(unsafe); the closure itself
    /// must be @Sendable.
    nonisolated(unsafe) static var replacementProvider: (@Sendable () -> [DictionaryEntry])?

    /// Processes a recorded meeting audio file (WAV; 16 kHz 16-bit mono
    /// expected, but any AVAudioFile-readable format/rate/channel-count is
    /// converted — stereo is averaged to mono) into speaker-attributed,
    /// time-stamped utterances and one profile per speaker label.
    ///
    /// `replacements` overrides the dictionary-backed default engine; the
    /// default (nil) consults `replacementProvider`, so existing callers get
    /// dictionary corrections with no signature change.
    static func process(
        fileURL: URL,
        replacements: ReplacementEngine? = nil,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> MeetingProcessingResult {
        let result = try await runPipeline(fileURL: fileURL, progress: progress)
        let engine = replacements ?? Self.replacementProvider.map { ReplacementEngine(entries: $0()) }
        guard let engine, !engine.isEmpty else { return result }
        let corrected = result.utterances.map { utterance in
            let corrected = engine.applyReporting(utterance.text)
            for hit in corrected.fired {
                harkLog("dictionary (meeting): \(hit.alias) -> \(hit.term)")
            }
            guard corrected.text != utterance.text else { return utterance }
            return MeetingUtterance(
                speakerLabel: utterance.speakerLabel,
                tStartMs: utterance.tStartMs,
                tEndMs: utterance.tEndMs,
                text: corrected.text,
                confidence: utterance.confidence
            )
        }
        return MeetingProcessingResult(utterances: corrected, speakers: result.speakers)
    }

    // MARK: - Pipeline (off the main actor)

    private nonisolated static func runPipeline(
        fileURL: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> MeetingProcessingResult {
        progress("reading audio…")
        let audio = try loadMono16kSamples(from: fileURL)
        let samples = audio.samples
        guard !samples.isEmpty else { return MeetingProcessingResult(utterances: [], speakers: []) }

        // --- Diarization -----------------------------------------------------
        let diarization = try await diarize(samples, progress: progress)
        let segments = diarization.segments

        // --- ASR -------------------------------------------------------------
        progress("loading speech models…")
        let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(asrModels)
        let decoderLayers = await asr.decoderLayerCount

        progress("transcribing…")
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let asrResult = try await asr.transcribe(samples, decoderState: &decoderState)

        // --- Merge -----------------------------------------------------------
        progress("merging transcript with speakers…")

        let labels = speakerLabels(for: segments)
        let words = wordSpans(from: asrResult.tokenTimings ?? [])

        if segments.isEmpty {
            // No diarization segments at all: attribute everything to one speaker.
            let text = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return MeetingProcessingResult(utterances: [], speakers: []) }
            return MeetingProcessingResult(
                utterances: [
                    MeetingUtterance(
                        speakerLabel: "SPEAKER_00",
                        tStartMs: 0,
                        tEndMs: Int64(Double(samples.count) / Double(sampleRate) * 1000.0),
                        text: text,
                        confidence: Double(asrResult.confidence)
                    )
                ],
                speakers: [])
        }

        let speakers = speakerProfiles(
            segments: segments, spans: diarization.spans, labels: labels, energy: audio.energy)

        if !words.isEmpty {
            // Preferred strategy: assign each recognized word to the diarizer
            // segment containing its midpoint (nearest segment when the word
            // falls in a gap), then build utterances from contiguous
            // same-speaker runs.
            return MeetingProcessingResult(
                utterances: mergeByWordTimings(words: words, segments: segments, labels: labels),
                speakers: speakers)
        }

        // Fallback: no usable token timings — transcribe each diarizer
        // segment's audio slice independently.
        let utterances = try await transcribePerSegment(
            samples: samples,
            segments: segments,
            labels: labels,
            asr: asr,
            decoderLayers: decoderLayers,
            progress: progress
        )
        return MeetingProcessingResult(utterances: utterances, speakers: speakers)
    }

    // MARK: - Diarization

    /// Speaker turns plus, per diarizer speaker id, the raw embeddings behind
    /// them (the material voiceprints are averaged from).
    private struct Diarization {
        let segments: [TimedSpeakerSegment]
        let spans: [String: [VoiceSpan]]
    }

    private nonisolated static func diarize(
        _ samples: [Float], progress: @escaping @Sendable (String) -> Void
    ) async throws -> Diarization {
        // Preferred: the offline pipeline, which clusters the whole meeting
        // at once (VBx). On real recordings it found the right number of
        // speakers where the streaming diarizer below split 3–4 people into
        // 10 or more labels and occasionally merged two voices.
        do {
            progress("loading diarizer models…")
            let offline = OfflineDiarizerManager(
                config: OfflineDiarizerConfig(exposeChunkEmbeddings: true))
            try await offline.prepareModels()
            progress("diarizing…")
            let result = try await offline.process(audio: samples) { done, total in
                progress("diarizing… \(total > 0 ? done * 100 / total : 0)%")
            }
            let spans = Dictionary(grouping: result.chunkEmbeddings ?? [], by: \.speakerId)
                .mapValues { chunks in
                    chunks.map {
                        VoiceSpan(
                            start: $0.startTimeSeconds, end: $0.endTimeSeconds,
                            embedding: $0.embedding256)
                    }
                }
            return Diarization(
                segments: result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds },
                spans: spans)
        } catch {
            // Fail open (first run without a network to fetch the offline
            // models, say): a rougher speaker split beats no transcript.
            progress("offline diarizer unavailable (\(error)); using the streaming diarizer…")
        }

        progress("loading diarizer models…")
        let diarizerModels = try await DiarizerModels.downloadIfNeeded()
        // Default config except a slightly tighter clustering threshold: with
        // the library default (0.7) two same-language voices can sit right at
        // the merge boundary and collapse into one speaker; 0.65 separated
        // them reliably in verification while keeping segment boundaries
        // identical.
        var diarizerConfig = DiarizerConfig.default
        diarizerConfig.clusteringThreshold = 0.65
        let diarizer = DiarizerManager(config: diarizerConfig)
        diarizer.initialize(models: diarizerModels)

        progress("diarizing…")
        let result = try diarizer.performCompleteDiarization(
            samples, sampleRate: sampleRate
        ) { fraction in
            progress("diarizing… \(Int(fraction * 100))%")
        }
        let segments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let spans = Dictionary(grouping: segments, by: \.speakerId).mapValues { turns in
            turns.map {
                VoiceSpan(
                    start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                    embedding: $0.embedding)
            }
        }
        return Diarization(segments: segments, spans: spans)
    }

    // MARK: - Speaker profiles

    /// One profile per label: voiceprint, talk time, mic share, and the clip
    /// to play when asking who it is. Labels without a usable embedding are
    /// left out.
    private nonisolated static func speakerProfiles(
        segments: [TimedSpeakerSegment],
        spans: [String: [VoiceSpan]],
        labels: [String: String],
        energy: ChannelEnergy?
    ) -> [MeetingSpeakerProfile] {
        Dictionary(grouping: segments, by: \.speakerId).compactMap { id, turns in
            guard let label = labels[id], let voiceSpans = spans[id],
                let voiceprint = meanEmbedding(voiceSpans.map(\.embedding))
            else { return nil }

            // Play back the turn that sounds most like this voiceprint, not
            // merely the longest: the diarizer occasionally files someone
            // else's turn under a label, and the longest turn can be that
            // stray (seen on real recordings).
            func strayness(_ turn: TimedSpeakerSegment) -> Float {
                let start = Double(turn.startTimeSeconds)
                let end = Double(turn.endTimeSeconds)
                let nearest = voiceSpans.max {
                    min($0.end, end) - max($0.start, start) < min($1.end, end) - max($1.start, start)
                }
                guard let nearest, let embedding = meanEmbedding([nearest.embedding]) else { return 2 }
                return 1 - zip(embedding, voiceprint).reduce(0) { $0 + $1.0 * $1.1 }
            }
            let substantial = turns.filter { $0.durationSeconds >= minimumClipSeconds }
            guard let clip = (substantial.isEmpty ? turns : substantial)
                .min(by: { strayness($0) < strayness($1) })
            else { return nil }
            let clipStart = Double(clip.startTimeSeconds)
            let clipEnd = min(Double(clip.endTimeSeconds), clipStart + maximumClipSeconds)

            var mic = 0.0
            var system = 0.0
            if let energy {
                for turn in turns {
                    let (m, s) = energy.sums(
                        from: Double(turn.startTimeSeconds), to: Double(turn.endTimeSeconds))
                    mic += m
                    system += s
                }
            }
            return MeetingSpeakerProfile(
                label: label,
                voiceprint: voiceprint,
                talkMs: Int64(turns.reduce(0.0) { $0 + Double($1.durationSeconds) } * 1000),
                micShare: mic + system > 0 ? mic / (mic + system) : 0,
                clipStartMs: Int64(clipStart * 1000),
                clipEndMs: Int64(clipEnd * 1000))
        }
        .sorted { $0.label < $1.label }
    }

    private nonisolated static var minimumClipSeconds: Float { 4 }
    private nonisolated static var maximumClipSeconds: Double { 8 }

    /// Mean of the embeddings, each normalized first so loud stretches don't
    /// dominate, L2-normalized. nil when there is nothing usable to average.
    private nonisolated static func meanEmbedding(_ embeddings: [[Float]]) -> [Float]? {
        guard let dims = embeddings.first?.count, dims > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dims)
        for embedding in embeddings where embedding.count == dims {
            let norm = embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            for i in 0..<dims { sum[i] += embedding[i] / norm }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return sum.map { $0 / norm }
    }

    // MARK: - Audio loading

    private nonisolated static var sampleRate: Int { 16_000 }

    /// Reads any AVAudioFile-supported file, averages all channels to mono
    /// (for two-channel meeting recordings — ch0 mic, ch1 system — this is the
    /// intended sum/2 mixdown), and resamples to 16 kHz Float32. For
    /// two-channel files it also returns the per-channel energy envelope,
    /// which is what tells the local speaker from the remote ones.
    private nonisolated static func loadMono16kSamples(
        from url: URL
    ) throws -> (samples: [Float], energy: ChannelEnergy?) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return ([], nil) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ProcessingError.audioReadFailed("could not allocate PCM buffer")
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else {
            throw ProcessingError.audioReadFailed("no float channel data")
        }

        // Mix all channels to mono (sum / channelCount).
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let source = channelData[channel]
            for i in 0..<frames { mono[i] += source[i] }
        }
        if channels > 1 {
            let scale = 1.0 / Float(channels)
            for i in 0..<frames { mono[i] *= scale }
        }

        let energy = channels == 2
            ? ChannelEnergy(
                mic: UnsafeBufferPointer(start: channelData[0], count: frames),
                system: UnsafeBufferPointer(start: channelData[1], count: frames),
                sampleRate: format.sampleRate)
            : nil

        if Int(format.sampleRate) == sampleRate { return (mono, energy) }
        return (try resample(mono, from: format.sampleRate, to: Double(sampleRate)), energy)
    }

    private nonisolated static func resample(
        _ input: [Float], from sourceRate: Double, to targetRate: Double
    ) throws -> [Float] {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                channels: 1, interleaved: false),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw ProcessingError.audioReadFailed("could not create AVAudioConverter")
        }

        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(input.count))
        else {
            throw ProcessingError.audioReadFailed("could not allocate source buffer")
        }
        input.withUnsafeBufferPointer { pointer in
            sourceBuffer.floatChannelData![0].update(from: pointer.baseAddress!, count: input.count)
        }
        sourceBuffer.frameLength = AVAudioFrameCount(input.count)

        let capacity = AVAudioFrameCount(
            (Double(input.count) * targetRate / sourceRate).rounded(.up) + 1024)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else {
            throw ProcessingError.audioReadFailed("could not allocate target buffer")
        }

        // The input block is invoked synchronously inside convert(); the flag
        // never crosses threads.
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .error {
            throw conversionError ?? ProcessingError.audioReadFailed("AVAudioConverter failed")
        }
        let frames = Int(targetBuffer.frameLength)
        guard frames > 0, let data = targetBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: frames))
    }

    // MARK: - Merge: word timings → diarizer segments

    /// Stable "SPEAKER_00"-style labels, assigned in order of each diarizer
    /// speaker's first appearance on the timeline.
    private nonisolated static func speakerLabels(
        for segments: [TimedSpeakerSegment]
    ) -> [String: String] {
        var labels: [String: String] = [:]
        for segment in segments where labels[segment.speakerId] == nil {
            labels[segment.speakerId] = String(format: "SPEAKER_%02d", labels.count)
        }
        return labels
    }

    /// Groups SentencePiece token timings into whole words with mean confidence.
    private nonisolated static func wordSpans(from timings: [TokenTiming]) -> [WordSpan] {
        var words: [WordSpan] = []
        var pieces = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidences: [Float] = []

        func flush() {
            let trimmed = pieces.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let mean = confidences.isEmpty
                ? nil
                : Double(confidences.reduce(0, +)) / Double(confidences.count)
            words.append(WordSpan(text: trimmed, start: start, end: end, confidence: mean))
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            let startsWord = token.hasPrefix("\u{2581}") || token.hasPrefix(" ") || pieces.isEmpty
            if startsWord {
                flush()
                var text = token
                if text.hasPrefix("\u{2581}") { text.removeFirst() }
                pieces = text.trimmingCharacters(in: .whitespaces)
                start = timing.startTime
                confidences = []
            } else {
                pieces += token
            }
            end = timing.endTime
            confidences.append(timing.confidence)
        }
        flush()
        return words
    }

    private nonisolated static func mergeByWordTimings(
        words: [WordSpan],
        segments: [TimedSpeakerSegment],
        labels: [String: String]
    ) -> [MeetingUtterance] {
        var utterances: [MeetingUtterance] = []
        var runLabel: String?
        var runWords: [WordSpan] = []

        func flushRun() {
            guard let label = runLabel, !runWords.isEmpty else { return }
            let text = runWords.map(\.text).joined(separator: " ")
            let wordConfidences = runWords.compactMap(\.confidence)
            let confidence = wordConfidences.isEmpty
                ? nil
                : wordConfidences.reduce(0, +) / Double(wordConfidences.count)
            utterances.append(
                MeetingUtterance(
                    speakerLabel: label,
                    tStartMs: Int64((runWords.first!.start * 1000.0).rounded()),
                    tEndMs: Int64((runWords.last!.end * 1000.0).rounded()),
                    text: text,
                    confidence: confidence
                )
            )
        }

        for word in words {
            let midpoint = Float((word.start + word.end) / 2.0)
            let segment = segmentContaining(midpoint, in: segments)
            let label = labels[segment.speakerId] ?? "SPEAKER_00"
            if label != runLabel {
                flushRun()
                runLabel = label
                runWords = []
            }
            runWords.append(word)
        }
        flushRun()
        return utterances
    }

    /// The segment containing `time`, or — when the word midpoint falls in a
    /// silence gap or past either edge — the segment whose interval is nearest.
    private nonisolated static func segmentContaining(
        _ time: Float, in segments: [TimedSpeakerSegment]
    ) -> TimedSpeakerSegment {
        var best = segments[0]
        var bestDistance = Float.greatestFiniteMagnitude
        for segment in segments {
            if time >= segment.startTimeSeconds && time < segment.endTimeSeconds {
                return segment
            }
            let distance =
                time < segment.startTimeSeconds
                ? segment.startTimeSeconds - time
                : time - segment.endTimeSeconds
            if distance < bestDistance {
                bestDistance = distance
                best = segment
            }
        }
        return best
    }

    // MARK: - Fallback: per-segment slice transcription

    private nonisolated static func transcribePerSegment(
        samples: [Float],
        segments: [TimedSpeakerSegment],
        labels: [String: String],
        asr: AsrManager,
        decoderLayers: Int,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [MeetingUtterance] {
        let minimumSliceSamples = Int(0.3 * Double(sampleRate))
        // Pad very short (but accepted) slices with trailing silence so they
        // clear the ASR minimum-length guard.
        let paddedSliceSamples = 2 * sampleRate

        var utterances: [MeetingUtterance] = []
        for (index, segment) in segments.enumerated() {
            progress("transcribing segment \(index + 1)/\(segments.count)…")
            let startSample = max(0, Int(Double(segment.startTimeSeconds) * Double(sampleRate)))
            let endSample = min(
                samples.count, Int(Double(segment.endTimeSeconds) * Double(sampleRate)))
            guard endSample - startSample >= minimumSliceSamples else { continue }

            var slice = Array(samples[startSample..<endSample])
            if slice.count < paddedSliceSamples {
                slice.append(
                    contentsOf: [Float](repeating: 0, count: paddedSliceSamples - slice.count))
            }

            // Fresh decoder state per slice — each is an independent utterance.
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await asr.transcribe(slice, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            utterances.append(
                MeetingUtterance(
                    speakerLabel: labels[segment.speakerId] ?? "SPEAKER_00",
                    tStartMs: Int64(Double(segment.startTimeSeconds) * 1000.0),
                    tEndMs: Int64(Double(segment.endTimeSeconds) * 1000.0),
                    text: text,
                    confidence: Double(result.confidence)
                )
            )
        }
        return utterances
    }

}

// MARK: - Supporting types (file-private)

/// One stretch of speech with the speaker embedding extracted from it.
private struct VoiceSpan: Sendable {
    let start: Double
    let end: Double
    let embedding: [Float]
}

/// Per-channel energy of a two-channel meeting recording (ch0 mic, ch1
/// system audio) in 100 ms frames — small enough to keep for any length of
/// meeting, fine enough to attribute a speaker turn to a channel.
private struct ChannelEnergy: Sendable {
    private static let frameSeconds = 0.1
    private let mic: [Double]
    private let system: [Double]

    init(mic: UnsafeBufferPointer<Float>, system: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let frame = max(1, Int(sampleRate * Self.frameSeconds))
        func envelope(_ samples: UnsafeBufferPointer<Float>) -> [Double] {
            stride(from: 0, to: samples.count, by: frame).map { start in
                var sum = 0.0
                for i in start..<min(start + frame, samples.count) {
                    sum += Double(samples[i]) * Double(samples[i])
                }
                return sum
            }
        }
        self.mic = envelope(mic)
        self.system = envelope(system)
    }

    /// Energy on each channel between two times, in whole frames.
    func sums(from start: Double, to end: Double) -> (mic: Double, system: Double) {
        let lo = max(0, Int(start / Self.frameSeconds))
        let hi = min(mic.count, Int((end / Self.frameSeconds).rounded(.up)))
        guard hi > lo else { return (0, 0) }
        return (mic[lo..<hi].reduce(0, +), system[lo..<hi].reduce(0, +))
    }
}

private struct WordSpan: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}

private enum ProcessingError: Error, LocalizedError {
    case audioReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioReadFailed(let detail):
            return "Failed to read meeting audio: \(detail)"
        }
    }
}
