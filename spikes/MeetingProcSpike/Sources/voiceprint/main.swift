@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// Speaker-identity spike. For each meeting recording (16 kHz stereo WAV,
// ch0 = mic, ch1 = system audio) this runs two diarizers over the mono
// mixdown and writes one JSON per recording with a voiceprint per speaker:
//
//   streaming — DiarizerManager, exactly as the app configures it today
//   offline   — OfflineDiarizerManager (VBx clustering), the candidate upgrade
//
// Alongside each voiceprint: talk time, first-half/second-half voiceprints
// (same person, same conditions — the floor for match distance), the share
// of that speaker's energy that arrived on the mic channel (≈1.0 means "the
// person at this Mac"), and the best clip to play back when asking for a name.

struct SpeakerDump: Codable {
    let id: String
    let seconds: Double
    let segments: Int
    let micShare: Double
    let centroid: [Float]
    /// Mean of the raw span embeddings — equals `centroid` for streaming; for
    /// offline it is the alternative to the library's speakerDatabase entry.
    let spanCentroid: [Float]?
    let firstHalf: [Float]?
    let secondHalf: [Float]?
    let clipStart: Double
    let clipEnd: Double
}

struct PipelineDump: Codable {
    let seconds: Double
    let speakers: [SpeakerDump]
}

struct RecordingDump: Codable {
    let file: String
    let audioSeconds: Double
    let streaming: PipelineDump
    let offline: PipelineDump?
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func loadChannels(_ url: URL) throws -> (mic: [Float], system: [Float], mono: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    precondition(Int(format.sampleRate) == 16_000, "expected a 16 kHz recording")
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else { return ([], [], []) }
    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    guard frames > 0, let data = buffer.floatChannelData else { return ([], [], []) }
    let mic = Array(UnsafeBufferPointer(start: data[0], count: frames))
    let system =
        format.channelCount > 1
        ? Array(UnsafeBufferPointer(start: data[1], count: frames))
        : [Float](repeating: 0, count: frames)
    var mono = [Float](repeating: 0, count: frames)
    for i in 0..<frames { mono[i] = (mic[i] + system[i]) * 0.5 }
    return (mic, system, mono)
}

func energy(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
    let lo = max(0, Int(start * 16_000))
    let hi = min(samples.count, Int(end * 16_000))
    guard hi > lo else { return 0 }
    var sum = 0.0
    for i in lo..<hi { sum += Double(samples[i]) * Double(samples[i]) }
    return sum
}

/// Weighted mean of embeddings, L2-normalized. nil when nothing to average.
func mean(_ items: [(embedding: [Float], weight: Double)]) -> [Float]? {
    guard let dims = items.first?.embedding.count, dims > 0 else { return nil }
    var sum = [Double](repeating: 0, count: dims)
    for item in items where item.embedding.count == dims {
        // Normalize each contribution first so loud chunks don't dominate.
        let norm = sqrt(item.embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0 else { continue }
        for i in 0..<dims { sum[i] += Double(item.embedding[i]) / norm * item.weight }
    }
    let norm = sqrt(sum.reduce(0.0) { $0 + $1 * $1 })
    guard norm > 0 else { return nil }
    return sum.map { Float($0 / norm) }
}

struct Span {
    let start: Double
    let end: Double
    let embedding: [Float]
}

/// `spans` carry the embeddings to average (segments for streaming, chunk
/// embeddings for offline); `segments` are the speaker's talk turns.
func dump(
    id: String, segments: [TimedSpeakerSegment], spans: [Span], database: [Float]?,
    mic: [Float], system: [Float]
) -> SpeakerDump? {
    guard !segments.isEmpty else { return nil }
    let seconds = segments.reduce(0.0) { $0 + Double($1.durationSeconds) }
    var micEnergy = 0.0
    var systemEnergy = 0.0
    for segment in segments {
        micEnergy += energy(mic, Double(segment.startTimeSeconds), Double(segment.endTimeSeconds))
        systemEnergy += energy(
            system, Double(segment.startTimeSeconds), Double(segment.endTimeSeconds))
    }
    let weighted = spans.map { (embedding: $0.embedding, weight: max($0.end - $0.start, 0.01)) }
    guard let centroid = database ?? mean(weighted) else { return nil }

    // Split the speaker's own talk time in half by time to get two
    // independent voiceprints of the same person in the same meeting.
    let ordered = spans.sorted { $0.start < $1.start }
    let half = ordered.count / 2
    let first = half >= 2
        ? mean(ordered[..<half].map { (embedding: $0.embedding, weight: max($0.end - $0.start, 0.01)) })
        : nil
    let second = half >= 2
        ? mean(ordered[half...].map { (embedding: $0.embedding, weight: max($0.end - $0.start, 0.01)) })
        : nil

    // Playback clip: the turn that sounds most like the speaker's voiceprint,
    // not merely the longest one — the diarizer occasionally files someone
    // else's turn under this label, and the longest turn can be that stray.
    func strayness(_ segment: TimedSpeakerSegment) -> Double {
        let start = Double(segment.startTimeSeconds)
        let end = Double(segment.endTimeSeconds)
        let best = spans.max {
            min($0.end, end) - max($0.start, start) < min($1.end, end) - max($1.start, start)
        }
        guard let best, best.embedding.count == centroid.count else { return 2 }
        var dot = 0.0
        var norm = 0.0
        for i in 0..<centroid.count {
            dot += Double(best.embedding[i]) * Double(centroid[i])
            norm += Double(best.embedding[i]) * Double(best.embedding[i])
        }
        return norm > 0 ? 1 - dot / sqrt(norm) : 2
    }
    let long = segments.filter { $0.durationSeconds >= 4 }
    let clip = (long.isEmpty ? segments : long).min { strayness($0) < strayness($1) }!
    let clipStart = Double(clip.startTimeSeconds)
    return SpeakerDump(
        id: id, seconds: seconds, segments: segments.count,
        micShare: micEnergy + systemEnergy > 0 ? micEnergy / (micEnergy + systemEnergy) : 0,
        centroid: centroid, spanCentroid: mean(weighted), firstHalf: first, secondHalf: second,
        clipStart: clipStart, clipEnd: min(Double(clip.endTimeSeconds), clipStart + 8))
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: voiceprint <out-dir> <meeting.wav>...")
    exit(64)
}

// `voiceprint --embed <wav> <start> <end>`: voiceprint of one clip, as JSON —
// for checking whether a playback clip actually represents its speaker.
if arguments[1] == "--embed", arguments.count == 5,
    let from = Double(arguments[3]), let to = Double(arguments[4])
{
    let (_, _, mono) = try loadChannels(URL(fileURLWithPath: arguments[2]))
    let diarizer = DiarizerManager()
    diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded())
    let slice = Array(mono[max(0, Int(from * 16_000))..<min(mono.count, Int(to * 16_000))])
    let embedding = try diarizer.extractSpeakerEmbedding(from: slice)
    print(String(decoding: try JSONEncoder().encode(embedding), as: UTF8.self))
    exit(0)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

log("loading streaming diarizer models…")
// One DiarizerModels per manager: initialize(models:) consumes it.
log("loading offline diarizer models…")
var offline: OfflineDiarizerManager? = OfflineDiarizerManager(
    config: OfflineDiarizerConfig(exposeChunkEmbeddings: true))
do {
    try await offline?.prepareModels()
} catch {
    log("offline models unavailable (\(error)) — streaming only")
    offline = nil
}

for path in arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let outURL = outDir.appendingPathComponent(
        url.deletingPathExtension().lastPathComponent + ".json")
    if FileManager.default.fileExists(atPath: outURL.path) {
        log("skip \(url.lastPathComponent) (already dumped)")
        continue
    }
    do {
        let (mic, system, mono) = try loadChannels(url)
        let audioSeconds = Double(mono.count) / 16_000
        log(String(format: "%@  %.0f s", url.lastPathComponent, audioSeconds))

        // --- streaming: the app's current configuration, fresh per meeting
        var config = DiarizerConfig.default
        config.clusteringThreshold = 0.65
        config.debugMode = true  // the only path that returns speakerDatabase
        let diarizer = DiarizerManager(config: config)
        diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded())
        var start = ContinuousClock.now
        let streamed = try diarizer.performCompleteDiarization(mono, sampleRate: 16_000)
        let streamingSeconds = seconds(since: start)
        let streamingSpeakers = Dictionary(grouping: streamed.segments, by: \.speakerId)
            .compactMap { id, segments in
                dump(
                    id: id, segments: segments,
                    spans: segments.map {
                        Span(
                            start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                            embedding: $0.embedding)
                    },
                    database: nil, mic: mic, system: system)
            }
            .sorted { $0.seconds > $1.seconds }
        log(String(format: "  streaming: %d speakers in %.1f s", streamingSpeakers.count, streamingSeconds))

        // --- offline (VBx)
        var offlineDump: PipelineDump?
        if let offline {
            start = ContinuousClock.now
            let result = try await offline.process(audio: mono)
            let offlineSeconds = seconds(since: start)
            let chunks = Dictionary(grouping: result.chunkEmbeddings ?? [], by: \.speakerId)
            let speakers = Dictionary(grouping: result.segments, by: \.speakerId)
                .compactMap { id, segments in
                    dump(
                        id: id, segments: segments,
                        spans: (chunks[id] ?? []).map {
                            Span(
                                start: $0.startTimeSeconds, end: $0.endTimeSeconds,
                                embedding: $0.embedding256)
                        },
                        database: result.speakerDatabase?[id], mic: mic, system: system)
                }
                .sorted { $0.seconds > $1.seconds }
            log(String(format: "  offline:   %d speakers in %.1f s", speakers.count, offlineSeconds))
            offlineDump = PipelineDump(seconds: offlineSeconds, speakers: speakers)
        }

        let recording = RecordingDump(
            file: url.lastPathComponent, audioSeconds: audioSeconds,
            streaming: PipelineDump(seconds: streamingSeconds, speakers: streamingSpeakers),
            offline: offlineDump)
        try JSONEncoder().encode(recording).write(to: outURL)
    } catch {
        log("  FAILED \(url.lastPathComponent): \(error)")
    }
}
