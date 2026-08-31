import AVFoundation
import Foundation

enum AudioFileError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let why): return "could not load audio file: \(why)"
        }
    }
}

/// Loads an audio file and returns 16 kHz mono Float32 samples — used by the
/// HARK_SELFTEST smoke test to push real audio through the same samples-API
/// path a live dictation uses.
func loadSamples16k(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inFormat = file.processingFormat
    guard file.length > 0,
        let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
    else {
        throw AudioFileError.unreadable("empty file or buffer allocation failed")
    }
    try file.read(into: inBuffer)

    if inFormat.commonFormat == .pcmFormatFloat32,
        inFormat.sampleRate == AudioSpec.sampleRate,
        inFormat.channelCount == 1,
        let channel = inBuffer.floatChannelData
    {
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(inBuffer.frameLength)))
    }

    guard
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioSpec.sampleRate,
            channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: inFormat, to: outFormat),
        let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: AVAudioFrameCount(
                Double(inBuffer.frameLength) * AudioSpec.sampleRate / inFormat.sampleRate) + 1024)
    else {
        throw AudioFileError.unreadable("could not create converter to 16 kHz mono")
    }

    // Same Sendable-handoff pattern as the mic tap: the input block is
    // @Sendable, so the buffer goes through an @unchecked Sendable box.
    let box = ConverterBox(converter: converter, outputFormat: outFormat)
    box.pending = inBuffer
    var convError: NSError?
    let status = box.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
        guard let next = box.pending else {
            outStatus.pointee = .endOfStream
            return nil
        }
        box.pending = nil
        outStatus.pointee = .haveData
        return next
    }
    guard status != .error, let channel = outBuffer.floatChannelData else {
        throw AudioFileError.unreadable("conversion failed: \(convError?.localizedDescription ?? "?")")
    }
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
}

extension Duration {
    /// Total seconds as a Double.
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Total milliseconds as a Double.
    var millisecondsValue: Double {
        secondsValue * 1000
    }
}
