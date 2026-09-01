import AVFoundation
import CoreAudio
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
    case coreAudio(String, OSStatus)

    var description: String {
        switch self {
        case .noInputDevice:
            return "no usable input device (input format has 0 Hz / 0 channels)"
        case .converterCreationFailed:
            return "could not create the AVAudioConverter to 16 kHz mono Float32"
        case let .coreAudio(what, status):
            return "\(what) failed: OSStatus \(status)"
        }
    }
}

/// Sample accumulator shared with the HAL IOProc, which runs on the serial IO
/// dispatch queue. Everything is guarded by a lock; the audio-side critical
/// sections are just an append.
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

/// Latest peak amplitude of the downmixed capture chunk, written by the HAL
/// IOProc on the IO queue and polled by the indicator HUD on the main actor.
/// Same lock discipline as CaptureState; the critical sections are one store
/// and one load.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func update(_ newValue: Float) {
        lock.withLock { value = newValue }
    }

    func read() -> Float {
        lock.withLock { value }
    }
}

/// The converter (and the pending-buffer handoff slot) are only ever touched
/// from the IOProc block (which the HAL invokes on our serial IO queue), so
/// boxing them as @unchecked Sendable is safe in practice.
final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    /// Device-rate mono Float32 — what the IOProc downmixes into.
    let inputFormat: AVAudioFormat
    /// 16 kHz mono Float32 (AudioSpec).
    let outputFormat: AVAudioFormat
    /// Handoff slot from the IOProc into the converter's input block.
    var pending: AVAudioPCMBuffer?

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }
}

/// Warm microphone capture straight through the Core Audio HAL: an IOProc on
/// the chosen input device runs for the lifetime of the warm-up, and
/// press/release just flips the accumulation flag. That keeps
/// press -> capture-active latency near zero at the cost of the mic indicator
/// staying lit while Hark runs.
///
/// Why not AVAudioEngine: its inputNode always binds to the *system default*
/// device, and poking kAudioOutputUnitProperty_CurrentDevice on its audio unit
/// behind the engine's back conflicts with the engine's graph bookkeeping —
/// inputNode.outputFormat(forBus:) kept reporting the default device's format
/// and the input rendered ZERO buffers (observed with a USB mic pinned while a
/// Bluetooth headset was the default). The HAL IOProc binds to exactly the
/// device we ask for.
@MainActor
final class MicCapture {
    private let state = CaptureState()
    private let meter = LevelMeter()
    private(set) var isWarm = false

    /// UID of the input device Hark is pinned to; nil follows the system
    /// default (which macOS reassigns on its own — e.g. to Bluetooth
    /// headsets — so pinning is the reliable mode).
    var pinnedDeviceUID: String?
    /// Human-readable name of the device the IOProc actually bound to.
    private(set) var activeDeviceName = "system default"

    /// The bound device and its IOProc (nil while torn down).
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Explicit serial queue for the IOProc — on macOS 26 passing an explicit
    /// queue to AudioDeviceCreateIOProcIDWithBlock is the reliable form (see
    /// the AudioTapSpike notes).
    private let ioQueue = DispatchQueue(label: "hark.mic.io")

    /// Actual device input format, as read from the HAL at warm-up (for
    /// `inputDescription` / logging).
    private var boundSampleRate: Double = 0
    private var boundChannels = 0

    // MARK: - coreaudiod-restart / device-death resilience state

    /// System-object listener for kAudioHardwarePropertyServiceRestarted;
    /// installed once on first warm-up, lives for the app's lifetime.
    private var restartListenerBlock: AudioObjectPropertyListenerBlock?
    /// Per-device listener for kAudioDevicePropertyDeviceIsAlive; re-added on
    /// every warm-up (the bound device changes) and removed in teardown so
    /// listeners never leak across re-warms.
    private var aliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var aliveListenerDevice = AudioDeviceID(kAudioObjectUnknown)
    /// Debounce for restart storms: at most one re-warm scheduled at a time,
    /// executed ~1 s after the first trigger (coalesces the multiple
    /// notifications a coreaudiod restart fires).
    private var rewarmScheduled = false
    /// True from warmUp() until an explicit teardown(): the re-warm handlers
    /// use this (not `isWarm`) so a failed re-warm attempt can still be
    /// retried on the next restart notification.
    private var wantsWarm = false

    /// Resolves the capture device, creates its IOProc, and starts IO. The
    /// first call in a fresh TCC grant state triggers the microphone
    /// permission prompt (attributed to Hark via its Info.plist usage
    /// description). Returns warm-up wall time in ms.
    ///
    /// `ignorePinned` skips the pinned-UID preference for this warm-up only
    /// (used when the pinned device died mid-session and we fall back to the
    /// system default).
    func warmUp(ignorePinned: Bool = false) throws -> Double {
        let start = ContinuousClock.now

        if isWarm { teardown() }
        wantsWarm = true
        installServiceRestartListener()

        // Resolve device: the pinned UID when present, else the system
        // default. Falls back to the default when the pinned device is
        // unplugged/missing.
        let device: AudioInputDevice
        if !ignorePinned, let uid = pinnedDeviceUID,
           let pinned = AudioInputDevices.device(forUID: uid) {
            device = pinned
        } else {
            if pinnedDeviceUID != nil, !ignorePinned {
                harkLog("pinned input device not present — using system default.")
            }
            guard let fallback = AudioInputDevices.defaultInput() else {
                throw MicCaptureError.noInputDevice
            }
            device = fallback
        }

        // Read the device's REAL input format from the HAL (nominal rate +
        // input-scope stream configuration) — not a graph node's idea of it.
        let sampleRate = Self.nominalSampleRate(of: device.id)
        let channels = Self.inputChannelCount(of: device.id)
        guard sampleRate > 0, channels > 0 else {
            throw MicCaptureError.noInputDevice
        }

        // The HAL delivers Float32; the IOProc downmixes to mono at the
        // device rate, and this converter streams that to 16 kHz.
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
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

        let box = ConverterBox(converter: converter, inputFormat: inputFormat, outputFormat: outputFormat)

        // The IO block MUST be built in a nonisolated context: a closure
        // formed directly inside this @MainActor method gets MainActor
        // isolation inferred, and the IO queue invoking it then trips the
        // runtime isolation assertion (same failure mode as the old
        // AVAudioEngine tap: EXC_BREAKPOINT in dispatch_assert_queue).
        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, device.id, ioQueue, Self.makeIOBlock(state: state, box: box, meter: meter))
        guard createStatus == noErr, let created = newProcID else {
            throw MicCaptureError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        let startStatus = AudioDeviceStart(device.id, created)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, created)
            throw MicCaptureError.coreAudio("AudioDeviceStart", startStatus)
        }

        deviceID = device.id
        procID = created
        activeDeviceName = device.name
        boundSampleRate = sampleRate
        boundChannels = channels
        isWarm = true
        installDeviceAliveListener(on: device.id)
        return (ContinuousClock.now - start).millisecondsValue
    }

    // MARK: - coreaudiod-restart / device-death resilience

    private nonisolated static var serviceRestartedAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static var deviceIsAliveAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Installed once, on the system object, for the app's lifetime. If
    /// coreaudiod is killed/restarted (`sudo killall coreaudiod` happens in
    /// the field), every IOProc dies silently — this is the only signal.
    private func installServiceRestartListener() {
        guard restartListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Dispatched on the main queue (listener registration below).
            MainActor.assumeIsolated {
                self?.handleAudioServerRestart()
            }
        }
        var address = Self.serviceRestartedAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            restartListenerBlock = block
        } else {
            harkLog("mic: WARNING — could not install the audio-server restart listener (OSStatus \(status)); a coreaudiod restart will require a manual re-warm.")
        }
    }

    /// Watches the bound device: if it disappears mid-session (unplugged USB
    /// mic, Bluetooth drop), re-warm onto the system default. Removed and
    /// re-added per warm-up so listeners never accumulate.
    private func installDeviceAliveListener(on device: AudioDeviceID) {
        removeDeviceAliveListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleDeviceAliveChanged()
            }
        }
        var address = Self.deviceIsAliveAddress
        let status = AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        if status == noErr {
            aliveListenerBlock = block
            aliveListenerDevice = device
        } else {
            harkLog("mic: WARNING — could not watch device liveness (OSStatus \(status)).")
        }
    }

    private func removeDeviceAliveListener() {
        guard let block = aliveListenerBlock,
              aliveListenerDevice != AudioDeviceID(kAudioObjectUnknown)
        else { return }
        var address = Self.deviceIsAliveAddress
        // Best-effort: after a coreaudiod restart the old device ID is gone
        // and this returns an error — that's fine, the registration died with
        // the server.
        AudioObjectRemovePropertyListenerBlock(aliveListenerDevice, &address, .main, block)
        aliveListenerBlock = nil
        aliveListenerDevice = AudioDeviceID(kAudioObjectUnknown)
    }

    private func handleAudioServerRestart() {
        guard wantsWarm else { return }
        scheduleRewarm(reason: "audio server restarted", ignorePinned: false)
    }

    private func handleDeviceAliveChanged() {
        guard wantsWarm else { return }
        // The property can fire without the device dying; only act when it
        // is actually gone (or can no longer be queried).
        guard !Self.deviceIsAlive(aliveListenerDevice) else { return }
        scheduleRewarm(
            reason: "input device '\(activeDeviceName)' disappeared",
            ignorePinned: true)
    }

    /// Coalesces re-warm triggers: the first one schedules a re-warm ~1 s
    /// out; anything arriving meanwhile (restart storms fire several
    /// notifications) is absorbed. The delay also gives the HAL time to
    /// repopulate its device list after a server restart.
    private func scheduleRewarm(reason: String, ignorePinned: Bool) {
        guard !rewarmScheduled else { return }
        rewarmScheduled = true
        harkLog("mic: \(reason) — re-warming in 1 s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rewarmScheduled = false
                self.performRewarm(reason: reason, ignorePinned: ignorePinned)
            }
        }
    }

    private func performRewarm(reason: String, ignorePinned: Bool) {
        guard wantsWarm else { return }  // torn down while debouncing
        do {
            let ms = try warmUp(ignorePinned: ignorePinned)
            if ignorePinned {
                harkLog(String(
                    format: "mic: input device lost — re-warmed onto fallback '%@' in %.1f ms (%@)",
                    activeDeviceName, ms, inputDescription))
            } else {
                harkLog(String(
                    format: "audio server restarted — mic engine re-warmed in %.1f ms (%@)",
                    ms, inputDescription))
            }
        } catch {
            // wantsWarm stays true: the next restart/death notification (or
            // an explicit warmUp) gets another shot.
            harkLog("mic: re-warm after '\(reason)' FAILED: \(error)")
        }
    }

    private nonisolated static func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        guard id != AudioDeviceID(kAudioObjectUnknown) else { return false }
        var address = deviceIsAliveAddress
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr else {
            return false  // can't even query it — treat as dead
        }
        return alive != 0
    }

    /// Test seam: invokes the coreaudiod-restart path exactly as the HAL
    /// listener would (already on the main actor). Used by the resilience
    /// harness; sudo-killing coreaudiod is the live equivalent.
    func simulateAudioServerRestart() {
        handleAudioServerRestart()
    }

    /// Test seam for the device-death path.
    func simulateDeviceDeath() {
        guard wantsWarm else { return }
        scheduleRewarm(
            reason: "input device '\(activeDeviceName)' disappeared (simulated)",
            ignorePinned: true)
    }

    /// Runs on the IO queue — deliberately built outside any actor context so
    /// no isolation is inferred.
    private nonisolated static func makeIOBlock(
        state: CaptureState, box: ConverterBox, meter: LevelMeter
    ) -> AudioDeviceIOBlock {
        { _, inInputData, _, _, _ in
            // Cheap early-out while idle: no conversion work between dictations.
            guard state.isCapturing else { return }

            // Downmix the HAL input buffers (Float32; a device may expose one
            // interleaved buffer or several) to mono at the device rate.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var frames = 0
            for buffer in abl where buffer.mNumberChannels > 0 {
                let f = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * Int(buffer.mNumberChannels))
                frames = frames == 0 ? f : min(frames, f)
            }
            guard frames > 0,
                  let mono = AVAudioPCMBuffer(
                    pcmFormat: box.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let dst = mono.floatChannelData?[0]
            else { return }

            for i in 0..<frames { dst[i] = 0 }
            var totalChannels = 0
            for buffer in abl {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0,
                      let data = buffer.mData?.assumingMemoryBound(to: Float32.self)
                else { continue }
                totalChannels += channels
                for frame in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += data[frame * channels + ch] }
                    dst[frame] += sum
                }
            }
            guard totalChannels > 0 else { return }
            if totalChannels > 1 {
                let scale = 1 / Float(totalChannels)
                for i in 0..<frames { dst[i] *= scale }
            }
            mono.frameLength = AVAudioFrameCount(frames)

            // Level meter for the indicator HUD: peak of this downmixed chunk.
            // Only computed while capturing (the isCapturing early-out above),
            // so idle cost stays zero.
            var chunkPeak: Float = 0
            for i in 0..<frames { chunkPeak = max(chunkPeak, abs(dst[i])) }
            meter.update(chunkPeak)

            // Streaming conversion: feed exactly this buffer, then report
            // .noDataNow so the converter keeps its resampler state alive for
            // the next IO callback.
            let ratio = box.outputFormat.sampleRate / box.inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: box.outputFormat, frameCapacity: capacity) else {
                return
            }
            box.pending = mono
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
        String(
            format: "%@ — %.0f Hz, %d ch -> %.0f Hz mono",
            activeDeviceName, boundSampleRate, boundChannels, AudioSpec.sampleRate)
    }

    func beginCapture() {
        meter.update(0)
        state.begin()
    }

    func endCapture() -> (samples: [Float], firstBufferAt: ContinuousClock.Instant?) {
        meter.update(0)
        return state.end()
    }

    /// Latest capture-chunk peak amplitude (0…1-ish raw peak; the indicator
    /// view normalizes). Zero while idle.
    func currentLevel() -> Float {
        meter.read()
    }

    func teardown() {
        // An explicit teardown always cancels the desire to stay warm (a
        // re-warm scheduled behind a debounce checks wantsWarm before
        // acting). warmUp() re-sets it right after calling teardown().
        wantsWarm = false
        guard isWarm else { return }
        removeDeviceAliveListener()
        // Stop IO before destroying the proc (AudioTapSpike ordering), then
        // drain any in-flight IO callback so the converter box is quiescent
        // before a subsequent warmUp() builds a new one.
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        ioQueue.sync {}
        deviceID = AudioDeviceID(kAudioObjectUnknown)
        isWarm = false
    }

    // MARK: - HAL input-format queries (device scope, not a graph node's view)

    private nonisolated static func nominalSampleRate(of id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    /// Total input channel count (sum over the device's input-scope buffers).
    private nonisolated static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
