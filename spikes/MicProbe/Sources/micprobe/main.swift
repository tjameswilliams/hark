//
//  main.swift
//  micprobe spike
//
//  Verifies the HAL-IOProc microphone capture pattern that Hark's MicCapture
//  uses (AudioDeviceCreateIOProcIDWithBlock on the *chosen* device with an
//  explicit serial queue — AVAudioEngine's inputNode ignores a behind-its-back
//  kAudioOutputUnitProperty_CurrentDevice poke and renders zero buffers).
//
//  For the system default input and then every other input device: capture
//  2 seconds, resample to 16 kHz mono Float32 via a streaming AVAudioConverter,
//  and print sample count + peak amplitude. Sample count must be > 0 for every
//  device; ambient room noise should give a nonzero peak on a real mic.
//

import AVFoundation
import CoreAudio
import Foundation

// MARK: - HAL property helpers

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
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

func nominalSampleRate(_ id: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
    return rate
}

/// Total input channel count (sum over the device's input-scope buffers).
func inputChannelCount(_ id: AudioObjectID) -> Int {
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
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func listInputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return (id, uid, name)
    }
}

func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
    ) == noErr, id != 0 else { return nil }
    return id
}

// MARK: - Capture core (mirrors Hark's MicCapture)

/// Sample accumulator shared with the IOProc, which runs on the serial IO
/// queue. Everything is guarded by a lock.
final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false

    var isCapturing: Bool { lock.withLock { capturing } }

    func begin() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            capturing = true
        }
    }

    func append(_ chunk: [Float]) {
        lock.withLock {
            guard capturing else { return }
            samples.append(contentsOf: chunk)
        }
    }

    func end() -> [Float] {
        lock.withLock {
            capturing = false
            defer { samples = [] }
            return samples
        }
    }
}

/// The converter (and the pending-buffer handoff slot) are only ever touched
/// from the IOProc on its serial queue, so boxing them as @unchecked Sendable
/// is safe in practice.
final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let inputFormat: AVAudioFormat   // device-rate mono Float32
    let outputFormat: AVAudioFormat  // 16 kHz mono Float32
    var pending: AVAudioPCMBuffer?
    var callbackCount = 0

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case badFormat(String)
    case osStatus(String, OSStatus)
    var description: String {
        switch self {
        case let .badFormat(what): return "bad format: \(what)"
        case let .osStatus(what, status): return "\(what) failed: OSStatus \(status)"
        }
    }
}

/// HAL IOProc capture on one explicit device.
final class HALCapture {
    private let deviceID: AudioDeviceID
    private let state = CaptureState()
    private let box: ConverterBox
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "micprobe.io")

    init(deviceID: AudioDeviceID, deviceRate: Double) throws {
        self.deviceID = deviceID
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: deviceRate,
                channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw ProbeError.badFormat("converter \(deviceRate) Hz -> 16 kHz") }
        box = ConverterBox(converter: converter, inputFormat: inputFormat, outputFormat: outputFormat)
    }

    func start() throws {
        var newProcID: AudioDeviceIOProcID?
        let ioBlock = Self.makeIOBlock(state: state, box: box)
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, ioQueue, ioBlock)
        guard createStatus == noErr, let created = newProcID else {
            throw ProbeError.osStatus("AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        procID = created
        let startStatus = AudioDeviceStart(deviceID, created)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, created)
            procID = nil
            throw ProbeError.osStatus("AudioDeviceStart", startStatus)
        }
        state.begin()
    }

    func stop() -> (samples: [Float], callbacks: Int) {
        let samples = state.end()
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        // Drain any in-flight IO callback before reading box state.
        ioQueue.sync {}
        return (samples, box.callbackCount)
    }

    /// Runs on the IO queue — built outside any actor context so no isolation
    /// is inferred.
    private static func makeIOBlock(state: CaptureState, box: ConverterBox) -> AudioDeviceIOBlock {
        { _, inInputData, _, _, _ in
            box.callbackCount += 1
            guard state.isCapturing else { return }

            // Downmix the HAL input buffers (Float32, possibly several
            // buffers / interleaved channels) to mono at the device rate.
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

            // Streaming conversion: feed exactly this buffer, then report
            // .noDataNow so the converter keeps its resampler state alive for
            // the next callback.
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
}

// MARK: - Probe run

let devices = listInputDevices()
let defaultID = defaultInputDevice()

print("input devices:")
for d in devices {
    let marker = d.id == defaultID ? "  * " : "    "
    print(String(
        format: "%@[%3d] %@  uid=%@  %.0f Hz, %d ch",
        marker, d.id, d.name, d.uid, nominalSampleRate(d.id), inputChannelCount(d.id)))
}
print("  (* = system default)\n")

// Probe order: default first, then every non-default device.
var order = devices
if let defaultID, let i = order.firstIndex(where: { $0.id == defaultID }) {
    let def = order.remove(at: i)
    order.insert(def, at: 0)
}

for d in order {
    let label = d.id == defaultID ? "\(d.name) (default)" : d.name
    let rate = nominalSampleRate(d.id)
    print("probing \(label): \(Int(rate)) Hz, \(inputChannelCount(d.id)) ch")
    do {
        let capture = try HALCapture(deviceID: d.id, deviceRate: rate)
        try capture.start()
        Thread.sleep(forTimeInterval: 2.0)
        let (samples, callbacks) = capture.stop()
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        print(String(
            format: "  -> %d samples @ 16 kHz (%.2f s), peak %.4f, %d IO callbacks%@\n",
            samples.count, Double(samples.count) / 16_000, peak, callbacks,
            samples.isEmpty ? "  ** FAIL: ZERO SAMPLES **" : ""))
    } catch {
        print("  -> FAILED: \(error)\n")
    }
}
