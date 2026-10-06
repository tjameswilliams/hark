@preconcurrency import AudioToolbox
import AVFoundation
import os
@preconcurrency import CoreAudio
import Foundation

/// Records a meeting: system audio (Core Audio process tap) + the microphone,
/// captured through a private aggregate device and streamed to a 16 kHz
/// stereo 16-bit WAV file (ch0 = mic, ch1 = system-audio mixdown).
///
/// Recipe proven in spikes/AudioTapSpike (adapted from insidegui/AudioCap,
/// BSD-2-Clause, and Apple's "Capturing system audio with Core Audio taps"
/// docs): global stereo tap (private, unmuted) -> process tap -> PRIVATE
/// aggregate with the default OUTPUT device as main sub-device (the tap alone
/// provides no clock), the mic as a second sub-device with drift
/// compensation, and the tap in the tap list with auto-start. Teardown order:
/// stop -> destroy IOProc -> destroy aggregate -> destroy tap.
enum MeetingCaptureError: Error, CustomStringConvertible {
    case alreadyRecording
    case noInputDevice
    case converterCreationFailed
    case coreAudio(String, OSStatus)
    case fileCreationFailed(String)

    var description: String {
        switch self {
        case .alreadyRecording:
            return "a meeting recording is already in progress"
        case .noInputDevice:
            return "no usable microphone input device"
        case .converterCreationFailed:
            return "could not create the AVAudioConverter to 16 kHz"
        case let .coreAudio(what, status):
            return "\(what) failed: OSStatus \(status)"
        case let .fileCreationFailed(path):
            return "could not create the recording file at \(path)"
        }
    }
}

@MainActor
final class MeetingCapture {

    /// Output WAV spec: 16 kHz stereo 16-bit (what the diarizer/ASR consume).
    /// nonisolated: also read from the IO-side classes below.
    nonisolated static let outputSampleRate: Double = 16_000
    nonisolated static let outputChannels = 2

    // MARK: - Core Audio objects (main-actor mutated; IO runs on ioQueue)

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Explicit serial queue for the IOProc — the reliable form on macOS 26
    /// (see the AudioTapSpike notes).
    private let ioQueue = DispatchQueue(label: "hark.meeting.io")

    private var io: MeetingCaptureIO?
    private var fileURL: URL?
    private var startedAt: Date?
    private(set) var isRecording = false

    /// Fires (on the main actor) when a recording is killed from under us —
    /// today that's a coreaudiod restart (`sudo killall coreaudiod`), which
    /// silently destroys the tap and aggregate device. The WAV is finalized
    /// first, so the tuple is exactly what stop() returns and the partial
    /// file is ready for the normal processing path.
    var onCaptureLost: ((URL, Date, Date, Float, Float) -> Void)?

    /// When the recording started, while one is running.
    var recordingStartedAt: Date? { isRecording ? startedAt : nil }
    /// The last moment either channel carried sound above room noise (see
    /// MeetingCaptureIO's thresholds); nil until the first such buffer. The
    /// controller's silence monitor compares this against the clock.
    var lastActivityAt: Date? { io?.lastActivityAt }

    /// System-object listener for kAudioHardwarePropertyServiceRestarted;
    /// registered for the duration of a recording only.
    private var restartListenerBlock: AudioObjectPropertyListenerBlock?

    /// Result of the most recent finalization — makes stop() safe/idempotent
    /// if the controller calls it after a capture-lost finalization already
    /// ran.
    private var lastResult: (url: URL, startedAt: Date, endedAt: Date, micPeak: Float, systemPeak: Float)?

    // MARK: - Lifecycle

    /// Starts a meeting recording. `micDeviceUID` pins the microphone (same
    /// semantics as MicCapture: pinned UID when present, else the system
    /// default input). Throws when a recording is already running or any
    /// Core Audio/file step fails; partial objects are torn down on failure.
    func start(micDeviceUID: String?) throws {
        guard !isRecording else { throw MeetingCaptureError.alreadyRecording }

        // 1. Resolve the microphone: pinned UID when present & connected,
        //    else the system default input.
        let mic: AudioInputDevice
        if let uid = micDeviceUID, let pinned = AudioInputDevices.device(forUID: uid) {
            mic = pinned
        } else {
            if micDeviceUID != nil {
                harkLog("meeting: pinned input device not present — using system default.")
            }
            guard let fallback = AudioInputDevices.defaultInput() else {
                throw MeetingCaptureError.noInputDevice
            }
            mic = fallback
        }

        // 2. The default OUTPUT device must be the aggregate's main
        //    sub-device: making the tap the main device yields silence
        //    (no clock to drive the IOProc).
        let outputID = try Self.defaultOutputDeviceID()
        guard let outputUID = Self.deviceUID(of: outputID) else {
            throw MeetingCaptureError.coreAudio(
                "read default output device UID", OSStatus(kAudioHardwareBadObjectError))
        }
        harkLog("meeting: output \(Self.deviceName(of: outputID)) [\(outputUID)], mic \(mic.name) [\(mic.uid)]")

        // 3. Global stereo mixdown tap of every process (private, unmuted).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "hark-meeting-tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr else {
            throw MeetingCaptureError.coreAudio("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID

        // 4. Private aggregate: output as MAIN sub-device, mic with drift
        //    compensation, tap in the tap list with auto-start.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hark-meeting-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                ],
                [
                    kAudioSubDeviceUIDKey: mic.uid,
                    kAudioSubDeviceDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &newAggregateID)
        guard aggStatus == noErr else {
            destroyCoreAudioObjects()
            throw MeetingCaptureError.coreAudio("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = newAggregateID

        // Only a starting guess: the IO side measures the rate audio really
        // arrives at and converts from that (see InputRateMeter).
        let aggregateRate = Self.nominalSampleRate(of: aggregateID)
        let inputRate = aggregateRate > 0 ? aggregateRate : 48_000
        harkLog("meeting: aggregate device up, nominal rate \(Int(inputRate)) Hz")

        // 5. Recording file: ~/Library/Application Support/Hark/recordings/
        //    <ISO-timestamp>.wav (colons swapped for '-' to keep the filename
        //    Finder-friendly).
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport
            .appendingPathComponent("Hark", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp).wav")

        let io: MeetingCaptureIO
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            io = try MeetingCaptureIO(fileURL: url, nominalSampleRate: inputRate)
        } catch let error as MeetingCaptureError {
            destroyCoreAudioObjects()
            throw error
        } catch {
            destroyCoreAudioObjects()
            throw MeetingCaptureError.fileCreationFailed("\(url.path): \(error)")
        }

        // 6. IOProc on the explicit serial queue. The block is built in a
        //    nonisolated context (same reason as MicCapture: a closure formed
        //    inside a @MainActor method gets MainActor isolation inferred and
        //    trips the runtime isolation assertion on the IO queue).
        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, ioQueue, Self.makeIOBlock(io: io))
        guard createStatus == noErr, let created = newProcID else {
            io.abandon()
            destroyCoreAudioObjects()
            throw MeetingCaptureError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        procID = created

        let startStatus = AudioDeviceStart(aggregateID, created)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, created)
            procID = nil
            io.abandon()
            destroyCoreAudioObjects()
            throw MeetingCaptureError.coreAudio("AudioDeviceStart", startStatus)
        }

        self.io = io
        self.fileURL = url
        self.startedAt = Date()
        isRecording = true
        installServiceRestartListener()
        harkLog("meeting: recording started -> \(url.path)")
    }

    /// Stops the recording, tears down the Core Audio objects (spike order:
    /// stop -> destroy IOProc -> destroy aggregate -> destroy tap), patches
    /// the WAV header, and returns the finished file plus per-channel peaks
    /// for zero-buffer diagnostics.
    ///
    /// Safe to call after a capture loss (audio-server restart) already
    /// finalized the recording: it logs and returns the finalized result
    /// instead of crashing.
    func stop() -> (url: URL, startedAt: Date, endedAt: Date, micPeak: Float, systemPeak: Float) {
        guard isRecording else {
            if let lastResult {
                harkLog("meeting: stop() called after the recording was already finalized (capture lost) — returning the finalized result.")
                return lastResult
            }
            // Never recorded at all: keep the old contract loudly rather
            // than fabricating a file that doesn't exist.
            preconditionFailure("MeetingCapture.stop() called while not recording")
        }
        return finalize()
    }

    /// Shared teardown/finalization for both the user-initiated stop() and
    /// the capture-lost path. Only call while `isRecording`.
    private func finalize() -> (url: URL, startedAt: Date, endedAt: Date, micPeak: Float, systemPeak: Float) {
        let io = self.io!
        let url = self.fileURL!
        let started = self.startedAt!

        removeServiceRestartListener()
        // After a coreaudiod restart these IDs are dead and the calls return
        // errors — harmless; the objects died with the server.
        if let procID {
            AudioDeviceStop(aggregateID, procID)
        }
        destroyCoreAudioObjects()
        // Drain any in-flight IO callback before touching IO state from here.
        ioQueue.sync {}

        let stats = io.finish()
        let endedAt = Date()

        harkLog(String(
            format: "meeting: recording stopped after %d IO callbacks, %d frames written (%.1f s). peaks: mic %.4f, system %.4f",
            stats.callbackCount, stats.framesWritten,
            Double(stats.framesWritten) / Self.outputSampleRate,
            stats.micPeak, stats.systemPeak))

        // Zero-buffer diagnostics. The silent-TCC failure mode delivers
        // buffers of pure zeros instead of an error.
        if stats.systemPeak <= 1e-6 {
            harkLog("""
                meeting: WARNING — the system-audio channel is pure silence. If \
                audio was playing during the recording, the usual culprit is the \
                system-audio capture permission: System Settings > Privacy & \
                Security > Screen & System Audio Recording -> enable Hark \
                (System Audio Recording Only), then record again.
                """)
        }
        if stats.micPeak <= 1e-6 {
            harkLog("""
                meeting: WARNING — the microphone channel is pure silence. Check \
                System Settings > Privacy & Security > Microphone -> Hark, and \
                that the selected input device is the one you spoke into.
                """)
        }

        self.io = nil
        self.fileURL = nil
        self.startedAt = nil
        isRecording = false

        let result = (url, started, endedAt, stats.micPeak, stats.systemPeak)
        lastResult = result
        return result
    }

    /// Best-effort teardown for app exit while a recording is running.
    func teardown() {
        guard isRecording else { return }
        _ = stop()
    }

    // MARK: - coreaudiod-restart resilience

    private nonisolated static var serviceRestartedAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// A coreaudiod restart destroys our process tap and aggregate device
    /// with no per-object notification — the recording just stops producing
    /// callbacks. Listen on the system object for the restart and finalize
    /// the WAV cleanly (everything captured so far is preserved).
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
            harkLog("meeting: WARNING — could not install the audio-server restart listener (OSStatus \(status)).")
        }
    }

    private func removeServiceRestartListener() {
        guard let block = restartListenerBlock else { return }
        var address = Self.serviceRestartedAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        restartListenerBlock = nil
    }

    /// Runs on the main actor. Re-entrancy-safe: the first event finalizes
    /// and flips isRecording, so a restart storm's follow-up notifications
    /// fall through the guard.
    private func handleAudioServerRestart() {
        guard isRecording else { return }
        harkLog("meeting: audio server restarted — the tap/aggregate device are gone; finalizing the file.")
        let result = finalize()
        harkLog("meeting: recording stopped by an audio-server restart — partial recording kept at \(result.url.path)")
        onCaptureLost?(result.url, result.startedAt, result.endedAt, result.micPeak, result.systemPeak)
    }

    /// Test seam: invokes the capture-lost path exactly as the HAL listener
    /// would (already on the main actor). `sudo killall coreaudiod` is the
    /// live equivalent.
    func simulateAudioServerRestart() {
        handleAudioServerRestart()
    }

    /// Idempotent destruction of the tap/aggregate/proc in the verified
    /// order. AudioDeviceStop (when applicable) happens before calling this.
    private func destroyCoreAudioObjects() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Built outside any actor context so no isolation is inferred (the HAL
    /// invokes it on `ioQueue`).
    private nonisolated static func makeIOBlock(io: MeetingCaptureIO) -> AudioDeviceIOBlock {
        { inNow, inInputData, inInputTime, _, _ in
            // The buffer's own hardware timestamp when there is one; "now"
            // is later by a jittery amount, but still good enough to tell
            // 24 kHz from 48 kHz over a second.
            let stamp = inInputTime.pointee.mFlags.contains(.hostTimeValid)
                ? inInputTime.pointee.mHostTime
                : (inNow.pointee.mFlags.contains(.hostTimeValid)
                    ? inNow.pointee.mHostTime : mach_absolute_time())
            io.handleInput(inInputData, hostTime: stamp)
        }
    }

    // MARK: - HAL queries (global scope)

    private nonisolated static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw MeetingCaptureError.coreAudio("read default output device", status)
        }
        return id
    }

    private nonisolated static func deviceUID(of id: AudioObjectID) -> String? {
        stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private nonisolated static func deviceName(of id: AudioObjectID) -> String {
        stringProperty(of: id, selector: kAudioObjectPropertyName) ?? "<unnamed \(id)>"
    }

    private nonisolated static func stringProperty(
        of id: AudioObjectID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private nonisolated static func nominalSampleRate(of id: AudioObjectID) -> Double {
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
}

// MARK: - IO-side state

/// Measures the rate audio actually arrives at, from how many frames the
/// HAL delivers between buffer timestamps, and snaps it to a standard rate.
///
/// The aggregate's nominal rate cannot be trusted. With a Bluetooth headset
/// as the output device it reads 48 kHz while music-quality playback is up,
/// but the moment the headset's microphone opens the link drops to its
/// hands-free rate and buffers arrive at 24 kHz. Converting those as 48 kHz
/// wrote recordings at half length: double speed, an octave up (seen on
/// three real meetings, 2026-10-05/06).
struct InputRateMeter {
    static let standardRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000,
    ]

    /// Seconds of audio per measurement.
    var window: Double
    private var windowStart: Double?
    private var frames = 0

    init(window: Double) { self.window = window }

    /// Records a buffer of `count` frames stamped `time` (seconds, any
    /// monotonic origin). Returns the snapped rate each time a window closes.
    mutating func add(frames count: Int, at time: Double) -> Double? {
        guard let start = windowStart else {
            windowStart = time
            frames = count
            return nil
        }
        // A buffer's stamp is its first frame, so the frames counted so far
        // span exactly start..<time.
        guard time - start >= window else {
            frames += count
            return nil
        }
        let measured = Double(frames) / (time - start)
        windowStart = time
        frames = count
        return Self.snap(measured)
    }

    /// What has been seen of an unfinished window, if it is enough to trust
    /// (a recording stopped before the first window closed).
    func partial(until time: Double) -> Double? {
        guard let start = windowStart, time - start >= 0.25, frames > 0 else { return nil }
        return Self.snap(Double(frames) / (time - start))
    }

    /// The standard rate nearest `measured` on a ratio scale.
    static func snap(_ measured: Double) -> Double? {
        guard measured.isFinite, measured > 0 else { return nil }
        return standardRates.min { abs(log($0 / measured)) < abs(log($1 / measured)) }
    }
}

/// One side (mic or system) of the capture: streams mono Float32 at the
/// device rate through an AVAudioConverter to 16 kHz and accumulates the
/// converted samples in a FIFO until the writer pairs both sides
/// frame-for-frame. Only ever touched from the serial IO queue (and from
/// stop() after ioQueue.sync{} drained it), hence @unchecked Sendable — same
/// pattern as MicCapture's ConverterBox.
private final class ChannelPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// Handoff slot from feed() into the converter's input block.
    private var pending: AVAudioPCMBuffer?
    /// Converted 16 kHz mono samples awaiting interleave.
    var fifo: [Float] = []

    init(inputSampleRate: Double) throws {
        guard
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate,
                channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: MeetingCapture.outputSampleRate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else {
            throw MeetingCaptureError.converterCreationFailed
        }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
    }

    /// Downmixes `frames` frames of interleaved Float32 (`channels` wide) to
    /// mono. Returns the samples and their peak (the silence monitor's raw
    /// signal).
    static func downmix(
        _ data: UnsafePointer<Float32>, frames: Int, channels: Int
    ) -> (samples: [Float], peak: Float) {
        guard frames > 0, channels > 0 else { return ([], 0) }
        var peak: Float = 0
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            for i in 0..<frames {
                mono[i] = data[i]
                peak = max(peak, abs(data[i]))
            }
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += data[frame * channels + ch] }
                let v = sum * scale
                mono[frame] = v
                peak = max(peak, abs(v))
            }
        }
        return (mono, peak)
    }

    /// Converts mono samples at the device rate to 16 kHz and appends them
    /// to the FIFO.
    func feed(_ samples: [Float]) {
        let frames = samples.count
        guard frames > 0,
              let mono = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0]
        else { return }
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
        mono.frameLength = AVAudioFrameCount(frames)

        // Streaming conversion: feed exactly this buffer, then report
        // .noDataNow so the converter keeps its resampler state alive.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        pending = mono
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { [self] _, outStatus in
            guard let next = pending else {
                outStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            outStatus.pointee = .haveData
            return next
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else {
            return
        }
        fifo.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    /// Pads the FIFO with silence up to `count` samples (evens out the two
    /// sides at the end of a recording).
    func padZeros(to count: Int) {
        if fifo.count < count {
            fifo.append(contentsOf: repeatElement(0, count: count - fifo.count))
        }
    }
}

/// Everything the IO block touches: the two converter pipes and the streaming
/// WAV writer. The HAL invokes handleInput on the serial IO queue only, and
/// stop() drains that queue (ioQueue.sync{}) before finish() reads state from
/// the main actor — so no lock is needed (@unchecked Sendable is safe, same
/// discipline as the spike's Recorder).
final class MeetingCaptureIO: @unchecked Sendable {
    /// Nil until the input rate has been measured; audio is held meanwhile.
    private var pipes: (mic: ChannelPipe, sys: ChannelPipe)?
    /// The rate `pipes` convert from.
    private(set) var inputRate: Double = 0
    private let nominalRate: Double
    private var meter = InputRateMeter(window: MeetingCaptureIO.calibrationSeconds)
    /// Device-rate mono audio captured before the rate was known.
    private var heldMic: [Float] = []
    private var heldSys: [Float] = []
    /// A measured rate that disagrees with `inputRate`, awaiting a second
    /// window to confirm it before the converters are rebuilt.
    private var disputedRate: Double?
    private var lastHostSeconds: Double = 0
    private var micPeak: Float = 0
    private var sysPeak: Float = 0
    private let writer: WavStreamWriter

    /// Audio held while the first measurement runs, then how often the rate
    /// is re-checked for the rest of the recording.
    private static let calibrationSeconds = 1.0
    /// Held audio (at the nominal rate) after which calibration is abandoned.
    private static let calibrationGiveUpSeconds = 4.0
    private static let monitorSeconds = 5.0
    private static let secondsPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    private var loggedLayout = false
    private var callbackCount = 0
    private var framesWritten = 0

    /// Peak thresholds (linear, 0…1) above which a buffer counts as
    /// "someone is talking / the call is producing sound". Speech peaks sit
    /// well above 0.1 at normal gain; keyboard clatter and room tone on the
    /// mic hover around 0.01 to 0.03, hence the higher mic bar. System audio
    /// is a clean mixdown, so a lower bar catches a quiet remote speaker.
    static let micActivityThreshold: Float = 0.05
    static let systemActivityThreshold: Float = 0.02
    /// Seconds since the reference date of the last active buffer; 0 = none
    /// yet. Written on the IO queue, read from the main actor by the silence
    /// monitor, so it lives behind a lock.
    private let lastActivity = OSAllocatedUnfairLock<Double>(initialState: 0)

    var lastActivityAt: Date? {
        let t = lastActivity.withLock { $0 }
        return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : nil
    }

    init(fileURL: URL, nominalSampleRate: Double) throws {
        nominalRate = nominalSampleRate
        writer = try WavStreamWriter(
            url: fileURL,
            channels: MeetingCapture.outputChannels,
            sampleRate: Int(MeetingCapture.outputSampleRate))
    }

    func handleInput(_ inInputData: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let bufferCount = abl.count
        guard bufferCount > 0 else { return }
        callbackCount += 1

        if !loggedLayout {
            loggedLayout = true
            let desc = abl.enumerated()
                .map { "#\($0.offset): \($0.element.mNumberChannels)ch \($0.element.mDataByteSize)B" }
                .joined(separator: "  ")
            harkLog("meeting: first IO callback buffers: \(desc)")
            if bufferCount == 1 {
                harkLog("meeting: WARNING — only one input buffer present; expected mic + tap. Treating it as the system-audio tap; the mic channel will be silent.")
            }
        }

        // Buffers arrive in sub-device order: mic (input device) first, the
        // tap last. The output device contributes no input streams.
        let micBuffer: AudioBuffer? = bufferCount > 1 ? abl[0] : nil
        let sysBuffer = abl[bufferCount - 1]
        let bytesPerFloat = MemoryLayout<Float32>.size

        var mic: (samples: [Float], peak: Float) = ([], 0)
        var sys: (samples: [Float], peak: Float) = ([], 0)
        if let micBuffer,
           micBuffer.mNumberChannels > 0,
           let data = micBuffer.mData?.assumingMemoryBound(to: Float32.self) {
            let channels = Int(micBuffer.mNumberChannels)
            let frames = Int(micBuffer.mDataByteSize) / (bytesPerFloat * channels)
            mic = ChannelPipe.downmix(data, frames: frames, channels: channels)
        }
        if sysBuffer.mNumberChannels > 0,
           let data = sysBuffer.mData?.assumingMemoryBound(to: Float32.self) {
            let channels = Int(sysBuffer.mNumberChannels)
            let frames = Int(sysBuffer.mDataByteSize) / (bytesPerFloat * channels)
            sys = ChannelPipe.downmix(data, frames: frames, channels: channels)
        }
        if micBuffer == nil {
            // Single-buffer degenerate case: keep the channels paired by
            // giving the mic side silence of the same length.
            mic = ([Float](repeating: 0, count: sys.samples.count), 0)
        }
        micPeak = max(micPeak, mic.peak)
        sysPeak = max(sysPeak, sys.peak)
        if mic.peak > Self.micActivityThreshold || sys.peak > Self.systemActivityThreshold {
            let now = Date().timeIntervalSinceReferenceDate
            lastActivity.withLock { $0 = now }
        }

        lastHostSeconds = Double(hostTime) * Self.secondsPerHostTick
        let measured = meter.add(frames: sys.samples.count, at: lastHostSeconds)
        if pipes == nil {
            heldMic.append(contentsOf: mic.samples)
            heldSys.append(contentsOf: sys.samples)
            if let measured {
                settle(on: measured)
            } else if Double(heldSys.count) > Self.calibrationGiveUpSeconds * nominalRate {
                // Timestamps that never advance would hold audio forever.
                harkLog("meeting: WARNING — could not measure the input rate (buffer timestamps are not advancing); assuming the nominal \(Int(nominalRate)) Hz.")
                settle(on: nominalRate)
            }
        } else {
            if let measured { recheck(measured) }
            pipes?.mic.feed(mic.samples)
            pipes?.sys.feed(sys.samples)
        }
        drainPaired()
    }

    /// Ends calibration: builds the converters for `rate` and runs the held
    /// audio through them.
    private func settle(on rate: Double) {
        // Within a few percent of nominal is the nominal rate, measured
        // through clock drift and timestamp jitter.
        let chosen = abs(rate / nominalRate - 1) < 0.05 ? nominalRate : rate
        if chosen != nominalRate {
            harkLog("meeting: audio is arriving at \(Int(chosen)) Hz, not the device's nominal \(Int(nominalRate)) Hz — converting from the measured rate.")
        }
        guard rebuildPipes(for: chosen) else { return }
        pipes?.mic.feed(heldMic)
        pipes?.sys.feed(heldSys)
        heldMic = []
        heldSys = []
        meter.window = Self.monitorSeconds
    }

    /// The rate can change mid-recording (a headset switching profile when
    /// another app takes or releases its microphone). One odd window is
    /// noise; two in a row that agree with each other is a real change.
    private func recheck(_ measured: Double) {
        guard measured != inputRate, abs(measured / inputRate - 1) >= 0.05 else {
            disputedRate = nil
            return
        }
        guard disputedRate == measured else {
            disputedRate = measured
            return
        }
        disputedRate = nil
        harkLog("meeting: input rate changed from \(Int(inputRate)) Hz to \(Int(measured)) Hz mid-recording — rebuilding the converters. Up to \(Int(3 * Self.monitorSeconds)) s around the change is at the wrong speed.")
        rebuildPipes(for: measured)
    }

    /// Swaps in converters for `rate`, keeping whatever 16 kHz audio the old
    /// ones had not yet written. Returns false (logged) if they can't be made.
    @discardableResult
    private func rebuildPipes(for rate: Double) -> Bool {
        do {
            let mic = try ChannelPipe(inputSampleRate: rate)
            let sys = try ChannelPipe(inputSampleRate: rate)
            if let old = pipes {
                mic.fifo = old.mic.fifo
                sys.fifo = old.sys.fifo
            }
            pipes = (mic, sys)
            inputRate = rate
            return true
        } catch {
            harkLog("meeting: WARNING — could not build converters for \(Int(rate)) Hz: \(error)")
            return false
        }
    }

    /// Interleaves however many frames BOTH pipes have ready (the converters
    /// may emit slightly different counts per callback) and appends them to
    /// the WAV file: ch0 = mic, ch1 = system.
    private func drainPaired() {
        guard let (micPipe, sysPipe) = pipes else { return }
        let n = min(micPipe.fifo.count, sysPipe.fifo.count)
        guard n > 0 else { return }
        var chunk = [Int16]()
        chunk.reserveCapacity(n * 2)
        for i in 0..<n {
            chunk.append(Self.int16Sample(micPipe.fifo[i]))
            chunk.append(Self.int16Sample(sysPipe.fifo[i]))
        }
        micPipe.fifo.removeFirst(n)
        sysPipe.fifo.removeFirst(n)
        writer.append(chunk)
        framesWritten += n
    }

    /// Flushes what can still be paired (padding the shorter side with
    /// silence so no captured audio is dropped), patches the WAV header, and
    /// closes the file. Call only after the IO queue is drained.
    func finish() -> (callbackCount: Int, framesWritten: Int, micPeak: Float, systemPeak: Float) {
        if pipes == nil, !heldSys.isEmpty {
            // Stopped inside the first second: go with what was seen of the
            // rate so far, or the nominal rate if even that is too little.
            settle(on: meter.partial(until: lastHostSeconds) ?? nominalRate)
        }
        if let (micPipe, sysPipe) = pipes {
            let n = max(micPipe.fifo.count, sysPipe.fifo.count)
            if n > 0 {
                micPipe.padZeros(to: n)
                sysPipe.padZeros(to: n)
                drainPaired()
            }
        }
        writer.finish()
        return (callbackCount, framesWritten, micPeak, sysPeak)
    }

    /// Failure path during start(): close and delete the half-created file.
    func abandon() {
        writer.abandon()
    }

    private static func int16Sample(_ v: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, v))
        return Int16(clamped * 32767.0)
    }
}

// MARK: - Streaming WAV writer

/// Hand-written 16-bit PCM WAV: a 44-byte header with placeholder sizes is
/// written up front, samples are appended as they arrive, and finish()
/// patches the RIFF/data sizes (the spike's WavFile, made streaming).
/// Touched only from the IO queue plus the post-drain finish()/abandon().
/// Also used by CaptureDump for one-shot dictation captures.
final class WavStreamWriter: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private var closed = false

    init(url: URL, channels: Int, sampleRate: Int) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw MeetingCaptureError.fileCreationFailed("\(url.path): \(error)")
        }

        let bytesPerSample = 2
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var header = Data(capacity: 44)
        func appendString(_ s: String) { header.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }

        appendString("RIFF")
        appendU32(36)                       // patched on finish(): 36 + dataBytes
        appendString("WAVE")
        appendString("fmt ")
        appendU32(16)                       // fmt chunk size
        appendU16(1)                        // PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(16)                       // bits per sample
        appendString("data")
        appendU32(0)                        // patched on finish(): dataBytes

        do {
            try handle.write(contentsOf: header)
        } catch {
            try? handle.close()
            throw MeetingCaptureError.fileCreationFailed("\(url.path): \(error)")
        }
    }

    func append(_ samples: [Int16]) {
        guard !closed else { return }
        // arm64/x86_64 are little-endian, so the in-memory Int16 layout is
        // already the WAV byte order.
        let data = samples.withUnsafeBytes { Data($0) }
        do {
            try handle.write(contentsOf: data)
            dataBytes += UInt32(data.count)
        } catch {
            harkLog("meeting: WARNING — WAV write failed: \(error)")
        }
    }

    /// Patches the RIFF (offset 4) and data (offset 40) chunk sizes, then
    /// closes the file.
    func finish() {
        guard !closed else { return }
        closed = true
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: withUnsafeBytes(of: (36 + dataBytes).littleEndian) { Data($0) })
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: withUnsafeBytes(of: dataBytes.littleEndian) { Data($0) })
            try handle.close()
        } catch {
            harkLog("meeting: WARNING — could not patch/close the WAV header: \(error)")
        }
    }

    /// Failure path: close the handle and remove the unusable file.
    func abandon() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
