import Foundation

// Spike #4: Swift -> Rust in-process boundary via UniFFI.
// Pushes 30 s of synthetic 16 kHz PCM in 10 ms buffers (160 samples x 3000
// calls); Rust emits a fake transcript event per 0.5 s via a callback.

let sampleRate: UInt32 = 16_000
let bufferSamples = 160          // 10 ms at 16 kHz
let bufferCount = 3_000          // 30 s total
let passBudgetMicros = 100.0     // pass/fail bar: mean per-push < 100 us

// The generated protocol requires Sendable (the Rust trait is Send + Sync).
// All pushes happen on one thread in this spike, so @unchecked is fine here.
final class Listener: TranscriptListener, @unchecked Sendable {
    private(set) var eventCount = 0
    func onEvent(event: TranscriptEvent) {
        eventCount += 1
        if eventCount <= 3 {
            print("  event #\(eventCount): \"\(event.text)\" [\(event.tStartMs)–\(event.tEndMs) ms]")
        }
    }
}

// Pre-generate all buffers (440 Hz sine, amplitude 8000) so the timed loop
// measures only the FFI push path, not synthesis.
var buffers: [[Int16]] = []
buffers.reserveCapacity(bufferCount)
var phase = 0.0
let phaseStep = 2.0 * Double.pi * 440.0 / Double(sampleRate)
for _ in 0..<bufferCount {
    var buf = [Int16](repeating: 0, count: bufferSamples)
    for i in 0..<bufferSamples {
        buf[i] = Int16(8000.0 * sin(phase))
        phase += phaseStep
    }
    buffers.append(buf)
}

let session = EngineSession(sampleRate: sampleRate)
let listener = Listener()
session.setListener(listener: listener)

print("Pushing \(bufferCount) buffers x \(bufferSamples) samples (30 s of 16 kHz PCM)...")

let t0 = DispatchTime.now().uptimeNanoseconds
for buf in buffers {
    session.pushBuffer(samples: buf)
}
let t1 = DispatchTime.now().uptimeNanoseconds

let stats = session.finish()

let wallNanos = t1 - t0
let wallMillis = Double(wallNanos) / 1_000_000.0
let meanMicros = Double(wallNanos) / Double(bufferCount) / 1_000.0
let rustMeanMicros = Double(stats.totalPushNanos) / Double(stats.totalBuffers) / 1_000.0

print("")
print("Events received via callback: \(listener.eventCount) (expected \(bufferCount * bufferSamples / (Int(sampleRate) / 2)))")
print("Rust-side stats: buffers=\(stats.totalBuffers) samples=\(stats.totalSamples) pushTime=\(Double(stats.totalPushNanos) / 1_000_000.0) ms")
print("")
print("FFI throughput:")
print("  total FFI push calls:        \(bufferCount)")
print(String(format: "  wall time for all pushes:    %.2f ms", wallMillis))
print(String(format: "  mean per-push (Swift side):  %.2f us", meanMicros))
print(String(format: "  mean per-push (Rust side):   %.2f us", rustMeanMicros))
print("")

if meanMicros < passBudgetMicros {
    print(String(format: "PASS: mean per-push %.2f us < %.0f us budget", meanMicros, passBudgetMicros))
    exit(0)
} else {
    print(String(format: "FAIL: mean per-push %.2f us >= %.0f us budget", meanMicros, passBudgetMicros))
    exit(1)
}
