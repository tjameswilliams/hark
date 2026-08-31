//
//  Recorder.swift
//  audiotap spike
//
//  Captures system audio (Core Audio process tap) + default microphone through a
//  private aggregate device, mixing into stereo: ch0 = mic, ch1 = system audio.
//
//  Recipe adapted from insidegui/AudioCap
//  (https://github.com/insidegui/AudioCap, BSD-2-Clause license) and Apple's
//  "Capturing system audio with Core Audio taps" documentation.
//

@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Foundation

/// All mutation happens either on the thread that calls start()/stop() or on the
/// serial IO dispatch queue; stop() drains the queue before results are read.
final class Recorder: @unchecked Sendable {

    // MARK: - Core Audio objects

    private var tapID: AudioObjectID = .unknownObject
    private var aggregateID: AudioObjectID = .unknownObject
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "audiotap.io")

    // MARK: - Capture state (touched on ioQueue while running)

    private var interleaved: [Int16] = []       // ch0 = mic, ch1 = system
    private var loggedLayout = false
    private var callbackCount = 0
    private(set) var peakMic: Float = 0
    private(set) var peakSystem: Float = 0
    private(set) var sampleRate: Double = 48_000

    private var running = false

    // MARK: - Lifecycle

    func start() throws {
        // 1. Locate the default devices. The default OUTPUT device must be the
        //    aggregate's main sub-device: making the tap the main device yields
        //    silence (no clock to drive the IOProc).
        let outputID = try AudioObjectID.defaultOutputDevice()
        let inputID = try AudioObjectID.defaultInputDevice()
        let outputUID = try outputID.deviceUID()
        let inputUID = try inputID.deviceUID()
        log("default output: \(outputID.deviceName()) [\(outputUID)]")
        log("default input:  \(inputID.deviceName()) [\(inputUID)]")

        // 2. Create a global stereo mixdown tap of every process.
        //    `initStereoGlobalTapButExcludeProcesses:` with an empty exclusion
        //    list is the canonical "tap everything" spelling (equivalent intent
        //    to `stereoMixdownOfProcesses: []`, but unambiguous about scope).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "audiotap-spike-tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID.unknownObject
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            "AudioHardwareCreateProcessTap"
        )
        tapID = newTapID
        log("created process tap, object id \(tapID)")

        // 3. Aggregate device: default output as MAIN sub-device, mic as second
        //    sub-device with drift compensation, tap in the tap list with
        //    auto-start so it runs as soon as the device does.
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "audiotap-spike-aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                ],
                [
                    kAudioSubDeviceUIDKey: inputUID,
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

        var newAggregateID = AudioObjectID.unknownObject
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggregateID
        log("created aggregate device, object id \(aggregateID)")

        if let rate = try? aggregateID.nominalSampleRate() {
            sampleRate = rate
        }
        log("aggregate nominal sample rate: \(sampleRate) Hz")
        if let layout = try? aggregateID.inputStreamLayout() {
            let desc = layout.enumerated().map { "#\($0.offset): \($0.element)ch" }.joined(separator: "  ")
            log("aggregate input stream layout: \(layout.count) buffer(s)  \(desc)")
        }

        // 4. IOProc on an explicit dispatch queue.
        //    (On macOS 26 passing an explicit serial queue is the reliable form;
        //    see README for notes.)
        var newProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
                self?.handleInput(inInputData)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        procID = newProcID

        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        running = true
        log("recording started")
    }

    /// Stops IO, tears everything down, and returns the captured interleaved
    /// stereo samples (ch0 = mic, ch1 = system audio).
    func stop() -> [Int16] {
        if running, let procID {
            AudioDeviceStop(aggregateID, procID)
        }
        if let procID, aggregateID != .unknownObject {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != .unknownObject {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknownObject
        }
        if tapID != .unknownObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknownObject
        }
        running = false
        // Drain any in-flight IO callback before reading state from this thread.
        ioQueue.sync {}
        log("recording stopped after \(callbackCount) IO callbacks, \(interleaved.count / 2) frames captured")
        return interleaved
    }

    // MARK: - IO callback

    private func handleInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let bufferCount = abl.count
        guard bufferCount > 0 else { return }
        callbackCount += 1

        if !loggedLayout {
            loggedLayout = true
            let desc = abl.enumerated()
                .map { "#\($0.offset): \($0.element.mNumberChannels)ch \($0.element.mDataByteSize)B" }
                .joined(separator: "  ")
            log("[io] first callback buffers: \(desc)")
            if bufferCount == 1 {
                log("[io] WARNING: only one input buffer present; expected mic + tap. Treating it as the system-audio tap; mic channel will be silent.")
            }
        }

        // Buffers arrive in sub-device order: mic (input device) first, the tap
        // last. The output device contributes no input streams.
        let micBuffer: AudioBuffer? = bufferCount > 1 ? abl[0] : nil
        let sysBuffer = abl[bufferCount - 1]

        let bytesPerFloat = MemoryLayout<Float32>.size
        let micChannels = Int(micBuffer?.mNumberChannels ?? 0)
        let sysChannels = Int(sysBuffer.mNumberChannels)
        let micFrames = micChannels > 0 ? Int(micBuffer!.mDataByteSize) / (bytesPerFloat * micChannels) : 0
        let sysFrames = sysChannels > 0 ? Int(sysBuffer.mDataByteSize) / (bytesPerFloat * sysChannels) : 0
        let frames = micFrames > 0 && sysFrames > 0 ? min(micFrames, sysFrames) : max(micFrames, sysFrames)
        guard frames > 0 else { return }

        let micPtr = micBuffer?.mData?.assumingMemoryBound(to: Float32.self)
        let sysPtr = sysBuffer.mData?.assumingMemoryBound(to: Float32.self)

        var chunk = [Int16]()
        chunk.reserveCapacity(frames * 2)

        for frame in 0..<frames {
            var mic: Float = 0
            if let micPtr, micChannels > 0, frame < micFrames {
                var sum: Float = 0
                for ch in 0..<micChannels { sum += micPtr[frame * micChannels + ch] }
                mic = sum / Float(micChannels)
            }
            var sys: Float = 0
            if let sysPtr, sysChannels > 0, frame < sysFrames {
                var sum: Float = 0
                for ch in 0..<sysChannels { sum += sysPtr[frame * sysChannels + ch] }
                sys = sum / Float(sysChannels)
            }
            peakMic = max(peakMic, abs(mic))
            peakSystem = max(peakSystem, abs(sys))
            chunk.append(int16Sample(mic))
            chunk.append(int16Sample(sys))
        }

        interleaved.append(contentsOf: chunk)
    }

    private func int16Sample(_ v: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, v))
        return Int16(clamped * 32767.0)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[audiotap] \(message)\n".utf8))
}
