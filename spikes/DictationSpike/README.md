# DictationSpike — the real headline loop

End-to-end push-to-talk dictation: **hold right ⌘ → mic capture → Parakeet
TDT v3 (FluidAudio, resident in memory) → paste the transcript into the
focused app**. Combines the verified pieces from `PTTSpike` (event tap +
clipboard-swap paste) and `InferenceSpike` (FluidAudio 0.15.6 usage).

## Run

```sh
cd spikes/DictationSpike
swift build
./.build/debug/dictate
```

Wait for:

```
[hark] ready — hold right ⌘ and speak
```

Then focus any text field, **hold right ⌘**, speak, release. The transcript
is pasted at the cursor and the previous clipboard is restored.

- Taps shorter than 0.3 s are ignored (audio discarded).
- Empty/whitespace transcripts are not pasted.
- Ctrl-C tears down the mic engine and event tap cleanly.

## TCC (permission) expectations

Both permissions are attributed to the **terminal app** that launches
`dictate` (plain CLI binaries inherit their launcher's TCC identity):

- **Accessibility** — required for the CGEventTap (hotkey) and synthetic
  ⌘V. Already granted to the terminal on this machine. If missing, `dictate`
  prints instructions and exits; grant it to the terminal in System Settings
  → Privacy & Security → Accessibility, then **relaunch the terminal**.
- **Microphone** — prompts on first run when the audio engine starts (at
  startup, not on first press — the engine is kept warm). Grant it to the
  terminal. If it was denied, capture yields silence; `dictate` detects
  all-zero/near-empty captures and prints guidance instead of transcribing.

The mic indicator stays lit the whole time `dictate` runs (warm engine —
see limitations).

## Environment variables

| Variable | Effect |
| --- | --- |
| `HARK_NO_AX_PROMPT=1` | Check Accessibility without popping the system dialog. |
| `HARK_NO_TAP=1` | Skip event-tap creation (headless smoke test — model load + mic warm-up only; hotkey disabled). Also skips the single-instance lock (no tap = no double-paste risk). |
| `HARK_SELFTEST=<audio-file>` | After startup, transcribe the file through the exact samples-API path a live dictation uses (cleanup included when configured), print transcript + timings, exit. |
| `HARK_CLEANUP=0` | Disable the LLM cleanup pass (raw transcripts paste). |
| `HARK_CLEANUP_URL` | OpenAI-compatible base URL (default `http://localhost:1234/v1` — LM Studio). |
| `HARK_CLEANUP_MODEL` | Model id (default: first non-embedding model the server lists). |
| `HARK_CLEANUP_KEY` | Bearer token, for endpoints that need one. |
| `HARK_CLEANUP_TIMEOUT_MS` | Hard fail-open budget (default 3000). |
| `HARK_CLEANUP_REASONING` | `reasoning_effort` sent with each request (default `none`; set `default` to omit the parameter). |

Headless verification (works without Accessibility):

```sh
HARK_NO_AX_PROMPT=1 HARK_NO_TAP=1 HARK_SELFTEST=../InferenceSpike/fixture.wav ./.build/debug/dictate
```

## How it works

- `PTTController.swift` — right-⌘ (`kVK_RightCommand`, 0x36) via a
  `flagsChanged` CGEventTap; observes only, passes events through;
  re-enables the tap on `tapDisabledByTimeout`/`ByUserInput`. Press starts
  accumulation; release < 0.3 s discards, ≥ 0.3 s transcribes + pastes.
  Presses while a previous dictation is still processing are refused.
- `MicCapture.swift` — one `AVAudioEngine` with an `inputNode` tap installed
  at startup and left running (warm). The tap converts each buffer to
  16 kHz mono Float32 with a streaming `AVAudioConverter` (`.noDataNow`
  keeps resampler state across callbacks) and appends to a lock-guarded
  accumulator; press/release just flips the accumulation flag.
  **Swift 6 gotcha (found via a real crash):** the tap block must be built
  in a `nonisolated` context — a closure formed inside a `@MainActor`
  method gets MainActor isolation inferred and the audio thread then traps
  in `dispatch_assert_queue`.
- `Transcriber.swift` — models loaded once (`AsrModels.downloadAndLoad(version: .v3)`),
  `AsrManager` resident. Transcription uses FluidAudio 0.15.6's **direct
  samples API**: `transcribe(_ audioSamples: [Float], decoderState: inout
  TdtDecoderState)` — no temp WAV needed. Fresh decoder state per utterance
  (`TdtDecoderState.make(decoderLayers:)`).
- `PasteEngine.swift` — verbatim from PTTSpike: secure-input guard,
  pasteboard snapshot → transcript (+ nspasteboard.org transient markers) →
  synthetic ⌘V from a private event source → snapshot restore only if the
  pasteboard still holds our item.
- `Cleanup.swift` — **fail-open** LLM cleanup against any OpenAI-compatible
  `/chat/completions` endpoint: any error, non-200, unparseable reply, or
  hard-budget timeout returns the raw transcript unchanged (the failure
  reason is printed). `temperature: 0`; `reasoning_effort: "none"` by
  default — a reasoning model was measured spending **300 thinking tokens /
  3.4 s** on a one-line cleanup vs **0 tokens / 0.7 s** with it off.
- `main.swift` — holds an exclusive `flock` on `~/.hark-dictate.lock` so a
  second instance exits immediately (two instances each own a tap + mic and
  paste every dictation twice — observed in the field). Top-level code is
  deliberately **synchronous**; async
  startup (model load, mic warm-up) runs in a `Task` that `CFRunLoopRun()`
  drains. A top-level `await` would make the whole body a MainActor task
  whose `CFRunLoopRun()` starves every other MainActor task (deadlocks the
  paste/dictation tasks).

## Measured timings (this machine: M4 Max, macOS 26.5.1)

Measured via the headless selftest (hotkey path not exercisable
programmatically):

| Metric | Value |
| --- | --- |
| Model load (CoreML compile cache cold) | ~13–15 s (Encoder compile dominates) |
| Model load (compile cache warm) | ~0.1 s |
| Mic engine warm-up | ~210–310 ms (once, at startup) |
| Press → capture-active | printed per dictation; expected ~0 ms with the warm engine (flag flip; first tap buffer ≤ ~46 ms away at 2048 frames / 48 kHz) |
| Transcription, 6.72 s fixture audio | ~112 ms (≈60× real-time) |
| LLM cleanup (LM Studio, gemma-4-26b-a4b, reasoning off, warm) | ~700–850 ms |
| Release → paste-complete | printed per dictation; expect transcription + cleanup + ~130 ms of paste choreography (100 ms pasteboard settle + 4 × 10 ms key events) |

Fixture transcript (samples API, resident models):
"The quick brown fox jumps over the lazy dog, testing Hark's local
transcription engine with parakeet on the neural engine."

## Known limitations

- **Mic always hot**: the engine (and the orange mic indicator) runs for the
  process lifetime. A real app should stop the engine after an idle timeout
  and eat the ~250 ms restart on the next press.
- **Conversion tail not flushed**: the streaming converter isn't drained on
  release, so the last <20 ms of resampler tail is dropped. Inaudible in
  practice for dictation.
- **First dictation may clip its head** if the user starts speaking the
  instant the TCC mic prompt appears (no audio flows until granted).
- **No VAD / auto-stop, no streaming partials** — strictly hold-to-talk,
  transcription starts at release.
- **Long holds**: samples accumulate unbounded in memory (~7.7 MB/min at
  16 kHz Float32); FluidAudio chunks >15 s audio internally, so long
  dictations work but latency grows linearly.
- **Default input device only**; device hot-swap while running is untested
  (AVAudioEngine usually handles it via configuration-change restarts, not
  wired up here).
- **Tap-vs-hold**: taps < 0.3 s are just ignored (no toggle mode).
- Right ⌘ still acts as a modifier for the frontmost app while held (the tap
  observes, it doesn't consume).

## Verification status

- `swift build` clean (Swift 6 strict concurrency, zero warnings).
- Headless run reaches "ready" with models resident; Ctrl-C teardown clean.
- Samples-API transcription verified against `../InferenceSpike/fixture.wav`.
- Graceful-failure path verified in a shell *without* Accessibility: prints
  guidance and exits 1 when the tap can't be created.
- The physical hold-right-⌘ → speak → paste loop needs a human: run
  `./.build/debug/dictate`, wait for ready, dictate into a text field, and
  read the printed press→capture-active / transcription / RTFx /
  release→paste-complete numbers.
