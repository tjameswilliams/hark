import AVFoundation
import Foundation

/// Shared audio constants for the dictation pipeline.
enum AudioSpec {
    /// Parakeet expects 16 kHz mono Float32.
    static let sampleRate: Double = 16_000
    /// FluidAudio's ASR guard rejects audio shorter than 0.3 s
    /// (ASRConstants.minimumAudioDurationSeconds).
    static var minimumSamples: Int { Int(sampleRate * 0.3) }
}

enum MicCaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case converterCreationFailed

    var description: String {
        switch self {
        case .noInputDevice:
            return "no usable input device (input format has 0 Hz / 0 channels)"
        case .converterCreationFailed:
            return "could not create the AVAudioConverter to 16 kHz mono Float32"
        }
    }
}

/// Sample accumulator shared with the AVAudioEngine tap callback, which runs
/// on a realtime audio thread. Everything is guarded by a lock; the audio-side
/// critical sections are just an append.
final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var firstBufferAt: ContinuousClock.Instant?

    var isCapturing: Bool {
        lock.withLock { capturing }
    }

    func begin() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            firstBufferAt = nil
            capturing = true
        }
    }

    func append(_ chunk: [Float]) {
        lock.withLock {
            guard capturing else { return }
            if firstBufferAt == nil { firstBufferAt = ContinuousClock.now }
            samples.append(contentsOf: chunk)
        }
    }

    /// Stops accumulation and hands back everything captured since `begin()`,
    /// plus the instant the first post-press audio buffer landed (for the
    /// press -> capture-active measurement).
    func end() -> (samples: [Float], firstBufferAt: ContinuousClock.Instant?) {
        lock.withLock {
            capturing = false
            defer { samples = [] }
            return (samples, firstBufferAt)
        }
    }
}

/// The converter (and the pending-buffer handoff slot) are only ever touched
/// from the tap callback (a single audio thread at a time), so boxing them as
/// @unchecked Sendable is safe in practice.
final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    /// Handoff slot from the tap callback into the converter's input block.
    var pending: AVAudioPCMBuffer?

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
    }
}

/// Warm microphone capture: the AVAudioEngine runs (with its input tap
/// installed) for the lifetime of the process, and press/release just flips
/// the accumulation flag. That keeps press -> capture-active latency near
/// zero at the cost of the mic indicator staying lit while `dictate` runs.
@MainActor
final class MicCapture {
    private let engine = AVAudioEngine()
    private let state = CaptureState()
    private(set) var isWarm = false

    /// Installs the tap and starts the engine. The first call in a fresh TCC
    /// grant state triggers the microphone permission prompt (attributed to
    /// the terminal that launched us). Returns warm-up wall time in ms.
    func warmUp() throws -> Double {
        let start = ContinuousClock.now

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCaptureError.noInputDevice
        }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioSpec.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw MicCaptureError.converterCreationFailed
        }

        let box = ConverterBox(converter: converter, outputFormat: outputFormat)

        // The tap block MUST be built in a nonisolated context: a closure
        // formed directly inside this @MainActor method gets MainActor
        // isolation inferred, and the audio thread invoking it then trips the
        // runtime isolation assertion (verified crash: EXC_BREAKPOINT in
        // dispatch_assert_queue from the RealtimeMessenger queue).
        input.installTap(
            onBus: 0, bufferSize: 2048, format: inputFormat,
            block: Self.makeTapBlock(state: state, box: box))

        engine.prepare()
        try engine.start()
        isWarm = true
        return (ContinuousClock.now - start).millisecondsValue
    }

    /// Runs on the audio tap thread — deliberately built outside any actor
    /// context so no isolation is inferred.
    private nonisolated static func makeTapBlock(
        state: CaptureState, box: ConverterBox
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            // Cheap early-out while idle: no conversion work between dictations.
            guard state.isCapturing else { return }

            let ratio = box.outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: box.outputFormat, frameCapacity: capacity) else {
                return
            }

            // Streaming conversion: feed exactly this buffer, then report
            // .noDataNow so the converter keeps its resampler state alive for
            // the next tap callback.
            box.pending = buffer
            var convError: NSError?
            let status = box.converter.convert(to: out, error: &convError) { _, outStatus in
                guard let next = box.pending else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                box.pending = nil
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else {
                return
            }
            state.append(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
        }
    }

    var inputDescription: String {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return String(
            format: "%.0f Hz, %d ch -> %.0f Hz mono",
            format.sampleRate, format.channelCount, AudioSpec.sampleRate)
    }

    func beginCapture() {
        state.begin()
    }

    func endCapture() -> (samples: [Float], firstBufferAt: ContinuousClock.Instant?) {
        state.end()
    }

    func teardown() {
        guard isWarm else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isWarm = false
    }
}
