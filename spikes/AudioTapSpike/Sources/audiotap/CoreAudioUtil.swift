//
//  CoreAudioUtil.swift
//  audiotap spike
//
//  Small helpers around the C Core Audio HAL API.
//  Portions of the tap/aggregate-device recipe are adapted from
//  insidegui/AudioCap (https://github.com/insidegui/AudioCap, BSD-2-Clause).
//

import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case let .osStatus(what, status):
            return "\(what) failed: OSStatus \(status) \(fourCCString(status))"
        }
    }
}

/// Render an OSStatus as a four-char code when printable (e.g. 'what', '!obj').
func fourCCString(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [
        UInt8((n >> 24) & 0xff),
        UInt8((n >> 16) & 0xff),
        UInt8((n >> 8) & 0xff),
        UInt8(n & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
          let s = String(bytes: bytes, encoding: .ascii)
    else { return "" }
    return "('\(s)')"
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(what, status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID.unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(.system, &address, 0, nil, &size, &deviceID),
            "read default device (selector \(selector))"
        )
        guard deviceID != .unknownObject else {
            throw CoreAudioError.osStatus("default device lookup (selector \(selector))", OSStatus(kAudioHardwareBadObjectError))
        }
        return deviceID
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDevice() throws -> AudioObjectID {
        try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    func deviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The HAL writes a +1 retained CFStringRef into the supplied storage.
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, &uidRef),
            "read device UID for object \(self)"
        )
        guard let uid = uidRef?.takeRetainedValue() else {
            throw CoreAudioError.osStatus("device UID for object \(self)", OSStatus(kAudioHardwareBadObjectError))
        }
        return uid as String
    }

    func deviceName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &nameRef)
        guard status == noErr, let name = nameRef?.takeRetainedValue() else {
            return "<unnamed \(self)>"
        }
        return name as String
    }

    func nominalSampleRate() throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, &rate),
            "read nominal sample rate for object \(self)"
        )
        return rate
    }

    /// Channel count per input buffer of this device (input-scope stream configuration).
    func inputStreamLayout() throws -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
            "read input stream configuration size for object \(self)"
        )
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw),
            "read input stream configuration for object \(self)"
        )
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }
    }
}
