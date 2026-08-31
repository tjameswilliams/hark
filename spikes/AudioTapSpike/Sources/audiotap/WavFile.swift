//
//  WavFile.swift
//  audiotap spike
//
//  Minimal 16-bit PCM WAV writer (header written by hand).
//

import Foundation

enum WavFile {
    /// Write interleaved 16-bit PCM samples as a canonical 44-byte-header WAV file.
    static func write(to url: URL, samples: [Int16], channels: Int, sampleRate: Int) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data(capacity: 44 + dataSize)

        func appendString(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendString("RIFF")
        appendU32(UInt32(36 + dataSize))
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
        appendU32(UInt32(dataSize))

        // arm64/x86_64 are little-endian, so the in-memory Int16 layout is already
        // the WAV byte order.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        try data.write(to: url)
    }
}
