@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Offline meeting processing: diarization (FluidAudio DiarizerManager) +
/// transcription (FluidAudio AsrManager, Parakeet TDT v3), merged into
/// speaker-attributed utterances.
///
/// The whole file is self-contained apart from `MeetingUtterance`, which is
/// defined elsewhere in the target. Progress is reported solely through the
/// `progress` closure.
@MainActor
final class MeetingProcessor {

    /// Processes a recorded meeting audio file (WAV; 16 kHz 16-bit mono
    /// expected, but any AVAudioFile-readable format/rate/channel-count is
    /// converted — stereo is averaged to mono) into speaker-attributed,
    /// time-stamped utterances.
    static func process(
        fileURL: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [MeetingUtterance] {
        try await runPipeline(fileURL: fileURL, progress: progress)
    }

    // MARK: - Pipeline (off the main actor)

    private nonisolated static func runPipeline(
        fileURL: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [MeetingUtterance] {
        progress("reading audio…")
        let samples = try loadMono16kSamples(from: fileURL)
        guard !samples.isEmpty else { return [] }

        // --- Diarization -----------------------------------------------------
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
        let diarization = try diarizer.performCompleteDiarization(
            samples, sampleRate: sampleRate
        ) { fraction in
            progress("diarizing… \(Int(fraction * 100))%")
        }
        let segments = diarization.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

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
            guard !text.isEmpty else { return [] }
            return [
                MeetingUtterance(
                    speakerLabel: "SPEAKER_00",
                    tStartMs: 0,
                    tEndMs: Int64(Double(samples.count) / Double(sampleRate) * 1000.0),
                    text: text,
                    confidence: Double(asrResult.confidence)
                )
            ]
        }

        if !words.isEmpty {
            // Preferred strategy: assign each recognized word to the diarizer
            // segment containing its midpoint (nearest segment when the word
            // falls in a gap), then build utterances from contiguous
            // same-speaker runs.
            return mergeByWordTimings(words: words, segments: segments, labels: labels)
        }

        // Fallback: no usable token timings — transcribe each diarizer
        // segment's audio slice independently.
        return try await transcribePerSegment(
            samples: samples,
            segments: segments,
            labels: labels,
            asr: asr,
            decoderLayers: decoderLayers,
            progress: progress
        )
    }

    // MARK: - Audio loading

    private nonisolated static var sampleRate: Int { 16_000 }

    /// Reads any AVAudioFile-supported file, averages all channels to mono
    /// (for two-channel meeting recordings — ch0 mic, ch1 system — this is the
    /// intended sum/2 mixdown), and resamples to 16 kHz Float32.
    private nonisolated static func loadMono16kSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
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

        if Int(format.sampleRate) == sampleRate { return mono }
        return try resample(mono, from: format.sampleRate, to: Double(sampleRate))
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
