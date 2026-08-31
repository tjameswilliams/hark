# InferenceSpike

Spike #3 for Hark: prove the STT engine choice — NVIDIA Parakeet TDT v3 (0.6b,
multilingual) running locally via the [FluidAudio](https://github.com/FluidInference/FluidAudio)
Swift package — and measure real latency on this machine.

## Build and run

```sh
swift build
swift run inference fixture.wav        # or any WAV/MP3/M4A/FLAC path
```

Requires macOS 15+ (platform pin; built and measured on macOS 26.5) and Swift 6.

## Model caching and first run

- Models download automatically on first run from Hugging Face to
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`
  (23 files, **469 MB** on disk).
- First run on this machine took **~135 s total** for `AsrModels.downloadAndLoad`:
  ~108 s downloading + ~25 s one-time CoreML compilation of the Encoder
  (`Encoder.mlmodelc`, compiled for `cpuAndNeuralEngine`). Subsequent compiles/loads
  are cached by CoreML.
- Warm runs load models in **~0.2 s**.

## Measured results (Apple M4 Max, 128 GB, macOS 26.5.1)

Fixture: 6.72 s of `say -v Samantha` speech, 16 kHz mono 16-bit WAV.

| Metric | First run | Warm run |
| --- | --- | --- |
| Model load | 134.5 s (download + CoreML compile) | 0.17 s |
| Transcription wall time | 0.107 s | 0.132 s |
| Real-time factor (audio/transcribe) | 62.8x | 51.0x |

Transcript produced (fixture text was "The quick brown fox jumps over the lazy
dog. Testing Hark's local transcription engine with Parakeet on the neural
engine."):

> The quick brown fox jumps over the lazy dog, testing Hark's local
> transcription engine with parakeet on the neural engine.

Word-perfect apart from punctuation/casing choices. The Encoder runs on the
Neural Engine (`cpuAndNeuralEngine`); Preprocessor is `cpuOnly`.

**Takeaway for Hark:** with models resident, a ~7 s utterance transcribes in
~100–130 ms. Latency is dominated by model load only on cold start, so the app
should load models once at launch and keep the `AsrManager` alive.

## API notes (FluidAudio pinned at exact "0.15.6")

Our earlier research (README-era ~0.12.x) suggested:

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asrManager = AsrManager(config: .default)
try await asrManager.loadModels(models)
let result = try await asrManager.transcribe(url)   // <- no longer compiles
```

Differences found in 0.15.6:

- **`transcribe` now requires caller-owned decoder state.** All overloads
  (`URL`, `[Float]`, `AVAudioPCMBuffer`) take `decoderState: inout TdtDecoderState`.
  Create it with `TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)`
  and pass `&decoderState`. (This is what FluidAudio's own CLI benchmarks do.)
- `AsrModels.defaultCacheDirectory(for: .v3)` is public — handy for reporting
  the cache path.
- Audio format: the engine wants 16 kHz mono Float32, but the URL overload runs
  the file through FluidAudio's own `AudioConverter`, so arbitrary rates and
  compressed formats (MP3/M4A/FLAC) are accepted. Our fixture is pre-converted
  to `LEI16@16000` mono anyway.
- Files above `config.streamingThreshold` automatically switch to disk-backed
  chunked processing; there are also separate streaming managers (later spike).
- macOS 15 platform target works fine — no need to raise it.
- Note: `Sources/inference/main.swift` uses top-level async code (not `@main`),
  since a file named `main.swift` cannot also declare `@main`.

## Regenerating the fixture

```sh
say -v Samantha -o /tmp/hark-test.aiff "The quick brown fox jumps over the lazy dog. Testing Hark's local transcription engine with Parakeet on the neural engine."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/hark-test.aiff fixture.wav
```
