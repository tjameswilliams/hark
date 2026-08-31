# Feasibility & Scope Spike — Local Transcription Engine (Rust core + Swift UI)

*Researched 2026-08-31. All claims verified against current sources during the spike; links inline.*

## Verdict

**Feasible, with one architectural twist.** Every MVP feature has a proven, shipped reference implementation, and the whole stack can be MIT/Apache/CC-BY licensed. The twist on the "build the engine in Rust" question: **the fastest, most power-efficient STT on Apple Silicon lives behind Core ML / the Neural Engine, and that path is Swift-first.** The winning split is therefore:

- **Rust owns the engine**: session orchestration, audio ring buffers, VAD, SQLite (+vectors, FTS), embeddings, chunking, LLM cleanup client, the MCP server — the "largest portion" you asked about.
- **Swift owns the OS surface and ML inference**: event tap (push-to-talk), paste injection, Core Audio process taps (meeting capture), Core ML inference (Parakeet via FluidAudio), status bar UI, main app UI.
- Linked **in-process via UniFFI** (Rust static lib → XCFramework → Swift Package), the same shape 1Password uses (they use a C FFI + typeshare; UniFFI is the right-sized version at this scale).

A pure-Rust inference path exists (whisper-rs + Metal; parakeet-rs + ONNX on CPU) and stays as the escape hatch, but it gives up the ANE — meaning worse battery/thermals for an always-on tool, which is exactly where "second to none performance" is felt.

## Architecture

```
┌─────────────────────────────  Swift (app bundle)  ─────────────────────────────┐
│  Status bar (NSStatusItem, LSUIElement)   Main window (SwiftUI)                │
│  ShortcutMonitor: CGEventTap .flagsChanged, keycode 0x36 (right ⌘)             │
│  Paster: clipboard swap + CGEvent ⌘V (VoiceInk timing recipe)                  │
│  MeetingCapture: Core Audio process tap + aggregate device (mic ‖ system)      │
│  Inference: FluidAudio → Parakeet TDT v3 (ANE), diarization, speaker DB        │
└───────────────────────────────┬────────────────────────────────────────────────┘
                            UniFFI (in-process, coarse-grained: PCM buffers ↓, transcript events ↑)
┌───────────────────────────────┴──────────────  Rust core crate  ───────────────┐
│  Session orchestration · VAD gate · whisper-rs fallback engine                 │
│  LLM cleanup client (any OpenAI-compatible base URL, fail-open, hard timeout)  │
│  SQLite (rusqlite + sqlite-vec static + FTS5, WAL) · fastembed-rs embeddings   │
│  Chunking (speaker-turn aligned) · hybrid search (BM25 + KNN, RRF)             │
└───────────────────────────────┬────────────────────────────────────────────────┘
                                │ same crate, second binary
                        ┌───────┴────────┐
                        │  yourapp-mcp   │  stdio MCP server (rmcp 3.x),
                        │  (read-only)   │  spawned on demand by Claude Code /
                        └────────────────┘  OpenCode / Codex; opens DB ?mode=ro
```

## 1. Push-to-listen (headline feature) — LOW RISK, fully proven

**Hotkey.** Right-Cmd is a modifier, so `RegisterEventHotKey` can't see it (and Sequoia deliberately broke modifier-only combos there). The shipped pattern (VoiceInk's `ShortcutMonitor.swift`, superwhisper behaves identically):

- Active `CGEventTap` on `.flagsChanged` at `.cgSessionEventTap`, match `kVK_RightCommand = 0x36` (left is `0x37`), press = flag set, release = flag cleared.
- **Mandatory**: re-enable the tap on `.tapDisabledByTimeout` / `.tapDisabledByUserInput` (macOS disables slow taps; also fires around sleep/wake).
- Requires **Accessibility** (`AXIsProcessTrusted`). Ship as `LSUIElement=1` — Apple DTS explicitly warns `LSBackgroundOnly` processes hit event-tap failures on Sequoia.
- Borrow WhisperForge's dual-mode nicety: tap-to-toggle vs hold-to-talk with a ~0.3 s threshold.
- Do this in Swift. Rust *can* create taps (rdev/core-graphics) but the CFRunLoop threading, TCC prompt orchestration, and re-enable logic are idiomatic AppKit territory.

**Paste into any app.** Every shipping dictation app converges on clipboard-swap + synthetic ⌘V; AX insertion is unreliable (Electron, terminals) and nobody uses it for writing. The field-tested recipe (VoiceInk `CursorPaster.swift`):

1. Snapshot full pasteboard (all items, all types).
2. Write transcript with `org.nspasteboard.TransientType` markers so clipboard managers skip it, plus a private session-ID type.
3. Wait 100 ms → post ⌘V as 4 CGEvents (`0x37`↓ `0x09`↓ `0x09`↑ `0x37`↑, `.maskCommand`, private event source, 10 ms apart, to `.cghidEventTap`).
4. Restore pasteboard after ≥250 ms, only if the session-ID is still present (user may have copied meanwhile).
5. Resolve the physical "V" key via `UCKeyTranslate` for non-QWERTY layouts (WhisperForge's `KeyboardLayoutProvider.swift`).
6. Detect Secure Input (`IsSecureEventInputEnabled()`) and degrade to "left on clipboard" + notification — password fields and Terminal secure-entry block all injection techniques, period.
7. Offer `CGEventKeyboardSetUnicodeString` "type instead of paste" as a user-selectable fallback.

**Latency budget (key-release → text in field):** Parakeet transcribes a 10 s utterance in ~100 ms on ANE; the paste choreography is ~400 ms; the LLM cleanup is the only real cost (~1.3–3.5 s local 4B model, ~1–2 s cloud API). Cleanup must be **fail-open** (any error/timeout → paste the raw transcript) with a hard wall-clock timeout — WhisperForge's `TextEnhancer` contract. Also transcribe streaming *during* the hold so release-to-paste doesn't start from zero.

## 2. STT engine — Parakeet TDT via Core ML wins on every axis

| Engine | WER (en) | Speed (M-series) | RAM | License | Best path |
|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v3 (FluidAudio, Core ML)** ⭐ | **2.2–2.6%** | **~110–155× RT** (ANE) | ~0.3–0.5 GB | Apache 2.0 (models CC-BY-4.0) | Swift; official `fluidaudio-rs` crate exists (young, 0.1.x) |
| whisper.cpp large-v3-turbo (Metal) | ~7.8% mean leaderboard | ~9–18× RT | ~6 GB fp16 (less quantized) | MIT | **whisper-rs** — mature, pure Rust |
| WhisperKit / argmax-oss-swift 1.0 | = whisper models | 42–72× RT (ANE) | 626 MB model | MIT | Swift-only (or its local OpenAI-compatible HTTP server) |
| Moonshine v2 medium-stream | 6.65% | purpose-built streaming | tiny | MIT (en) | ONNX → ort |
| Apple SpeechAnalyzer (macOS 26) | 2.12% LibriSpeech clean | very fast, OS asset | 0 | OS API | Swift; ~30 locales, weaker on conversational audio |

**Decision:** Parakeet TDT v3 via FluidAudio (ANE, streaming + end-of-utterance variants, punctuation/caps built in). Fallbacks: whisper-rs + large-v3-turbo (Metal) for the pure-Rust path and for non-European languages (Parakeet v3 = 25 European languages, no CJK; Qwen3-ASR via FluidAudio covers CJK); SpeechAnalyzer as a zero-download instant-start option.

**LLM cleanup:** one code path targeting *any* OpenAI-compatible base URL — Ollama/MLX server locally, cloud optionally. 4B-class models (Qwen3-4B, Gemma small, Llama 3.2 3B) are fine at ~60–100 tok/s on M4-class; keep resident (`keep_alive`) since cold load dwarfs inference.

## 3. Meeting transcription & diarization — feasible; capture is the highest-risk item

**Capture (system audio + mic).** Core Audio **process taps** (macOS 14.2+, practical 14.4+, sane permission flow on 15+): PID → `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → IOProc. This is what openwhispr ships (`macos-audio-tap.swift`). Include the mic *and* the tap as sub-devices of one aggregate device → one hardware-clocked callback with mic and system audio in **separate channels** — materially better diarization ("my voice" is a clean channel).

- Do **not** use ScreenCaptureKit (Screen Recording TCC + macOS 15/26 periodic re-approval nags) or BlackHole (driver install).
- Permission: `NSAudioCaptureUsageDescription` (hand-edit Info.plist — Xcode build settings silently drop it); appears as "System Audio Recording Only" on macOS 15+.
- Gotchas that make this the #1 spike target: **TCC denial is silent — calls return `noErr` and buffers are all zeros** (detect and surface); real output device must be the main sub-device with `kAudioAggregateDeviceTapAutoStartKey`; TCC keys off the stable signing identity (use the real Developer ID cert even in dev); macOS 26 changed an IOProc dispatch-queue requirement. `CATapDescription` is an Obj-C class, so this stays in Swift.

**Diarization.** Offline is solved locally; naive streaming is not:

- **Final pass (shippable):** FluidAudio offline pipeline — pyannote-style segmentation + WeSpeaker embeddings — **10.6% DER on AMI-SDM at 323× RT** on ANE. A 1-hour meeting processes in well under a minute. Merge ASR word timestamps → speaker segments WhisperX-style.
- **Live view (optional):** streaming clustering collapses (38% DER), so live labels come from end-to-end streaming models — Sortformer (≤4 speakers; runs from pure Rust via parakeet-rs/ONNX) or LS-EEND (≤10, FluidAudio) — shown as *provisional* and overwritten by the offline pass.
- **Persistent speaker identity:** FluidAudio ships speaker enrollment + a speaker database (cosine similarity on embeddings) out of the box; store embeddings in our SQLite `speakers.voiceprint_blob` like openwhispr's `speaker_profiles`.
- Avoid embedding Python/pyannote directly; its models are reachable via FluidAudio/SpeakerKit (Core ML) or sherpa-onnx (C API).

## 4. Data layer — SQLite all the way down

- **rusqlite + statically linked sqlite-vec** (register `sqlite3_vec_init` via auto-extension — no dylib loading, which matters for notarization). Stable brute-force KNN is ~<75 ms at 100k × 768-dim; tens of thousands of chunks at 384-dim is trivially fine. Ignore the ANN alphas; usearch sidecar is the escape hatch past ~500k chunks.
- **Hybrid search:** FTS5 (BM25) + vec KNN fused with Reciprocal Rank Fusion in pure SQL (Alex Garcia's reference implementation; RRF k=60, no score normalization needed).
- **Embeddings:** fastembed-rs (ONNX Runtime; candle/Metal backend option). Default **bge-small-en-v1.5 or arctic-embed-s @ 384d** (~35 MB, fast on CPU); **EmbeddingGemma-300M-Q4** as a quality tier (Matryoshka-truncate to 512/256d). Bundle models — fastembed downloads from HF by default. Store `model_id + dims` per row for migration.
- **Schema shape** (validated against openwhispr, Granola's local store, and anarlog/Hyprnote):

```sql
projects(id, name, description, created_at);
sessions(id, project_id, kind CHECK(kind IN ('dictation','meeting')),
         title, started_at, ended_at, audio_path, app_context);
speakers(id, display_name, voiceprint_blob);
session_speakers(session_id, speaker_id, label);         -- 'SPEAKER_01' → person
segments(id, session_id, speaker_id, t_start_ms, t_end_ms, text, confidence);
chunks(id, session_id, seg_start_id, seg_end_id, text, token_count, pos);
notes(session_id, kind, content);                        -- summaries/AI output, separate
CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='id');
CREATE VIRTUAL TABLE chunk_embeddings USING vec0(
  embedding float[384], +model_id TEXT, +session_id INTEGER);
```

Key subtlety: **chunk ≠ segment**. Diarized segments are 2-second fragments, too small to embed. Chunk on speaker-turn/sentence boundaries (~200–400 tokens, slight overlap) and keep segment-range refs so search hits cite timestamps/speakers. Use vec0 partition columns for project-filtered KNN rather than post-filtering.

## 5. MCP server — LOW RISK, SDK is now Tier 1

- **rmcp** (official `modelcontextprotocol/rust-sdk`) hit Tier 1 conformance Aug 2026, v3.0.1 stable; `#[tool]` macros generate schemas from typed structs; a stdio server is ~20 lines.
- **Shape:** a separate `openwhispr-mcp` stdio binary reusing the core crate, spawned on demand by the client, opening the same SQLite file **read-only** (WAL: app is sole writer, N readers free). Works even when the app isn't running; zero ports/auth.
- Tools: search sessions (hybrid), get meeting transcript (with speakers/timestamps), list projects, pull meeting summaries into context.
- Claude Code (`.mcp.json`), OpenCode (`opencode.json` `"mcp"` key), and Codex (`~/.codex/config.toml`) all take the same command/args/env triple → ship `openwhispr-mcp install --client claude|opencode|codex`.
- Prior art validating exactly this design: community MCP servers over Granola's local SQLite; anarlog (Rust + SQLite + MCP CLI).

## 6. App shell & distribution — LOW RISK checklist work

- `NSStatusItem` + `LSUIElement=1`; toggle `.regular` activation policy when the main window opens. `SMAppService` for launch-at-login.
- **Mac App Store is a confirmed non-starter** (sandbox rejects active event taps and `CGEvent.post`; Guideline 2.4.5 rejections on record). Every comparable app (superwhisper, VoiceInk, Wispr Flow) is Developer ID direct distribution.
- Developer ID + Hardened Runtime + `notarytool` + stapling; Sparkle 2 for updates (EdDSA-signed).
- Entitlements/plist: `com.apple.security.device.audio-input` + `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription` (hand-edited), `com.apple.security.automation.apple-events` + usage string if the AppleScript paste fallback ships. Accessibility/Input Monitoring are TCC prompts, not entitlements.
- Onboarding must include a **permission-health dashboard** (mic / Accessibility / system-audio), because TCC grants sometimes need a tap re-install or app restart, and revocation is silent.

## Risk register

| Risk | Level | Mitigation |
|---|---|---|
| Core Audio process taps (silent zero-buffer TCC failures, thin docs, macOS 26 API drift) | **High** | First prototype spike; target macOS 15+; all-zero-buffer detector; real signing cert in dev; openwhispr's helper + AudioCap as references |
| `fluidaudio-rs` immaturity (0.1.x) | Medium | Treat as optional; primary plan is FluidAudio in Swift with transcripts crossing UniFFI — the crate is a convenience, not a dependency |
| TCC lifecycle papercuts (grants needing restart; Sequoia/Tahoe event-tap regressions, e.g. VoiceInk #735 on 26.3.1) | Medium | Permission-health UI; tap re-enable logic; track macOS point releases |
| LLM cleanup latency (1.3–3.5 s local) makes release-to-paste feel slow | Medium | Fail-open + hard timeout; stream STT during hold; "paste raw, then replace" option; resident model |
| Live diarization quality (38% DER streaming) | Low (scoped) | Live labels are provisional-only; offline re-pass is the source of truth |
| sqlite-vec slow maintenance cadence | Low | Vendor the C amalgamation; brute-force core is stable; usearch escape hatch |
| Parakeet v3 language coverage (European-only, no CJK) | Low | whisper large-v3-turbo / Qwen3-ASR fallback per-language |

## What the reference repos teach

- **WhisperForge** (MIT, Swift, OpenSuperWhisper fork): hold-vs-tap 0.3 s dual-mode hotkey; layout-aware ⌘V with full pasteboard restore; fail-open LLM pass with hard timeout; FluidAudio integration; notarization scripts. No meetings, batch-only.
- **openwhispr** (MIT, Electron): the most complete feature map — Core Audio tap helper, sherpa-onnx diarization recipe (pyannote-seg + CAM++ + silero, threshold 0.55), speaker-profile schema, meeting auto-detection, FTS5 notes. Cautionary tale on Electron heft and monolithic helpers — exactly what the Rust+Swift rewrite fixes.
- **meeting-assistant** (your repo, Rust): reusable tokio pipeline/plugin skeleton and the double-tap-with-continuation-cancel hotkey trick; cautionary tales on ffmpeg-subprocess capture (use process taps) and DSP-only diarization (use real models). CC BY-NC — yours to relicense.
- **VoiceInk** (GPL-3, Swift): the closest shipped architecture; read `ShortcutMonitor.swift` / `CursorPaster.swift` for exact recipes — *reference only, no code copying* into a non-GPL product.

## MVP scope & phasing

**Phase 1 — the headline (dictation loop):** menu bar app, right-⌘ push-to-listen, Parakeet streaming STT, fail-open LLM cleanup, paste-anywhere, dictation history in SQLite, onboarding/permission health. *This alone is a usable product.*

**Phase 2 — meetings:** process-tap + mic aggregate capture, offline diarized transcript, speaker enrollment/persistent identity, meetings stored with segments.

**Phase 3 — knowledge layer:** projects, embeddings + hybrid search, main management UI (search, meeting browser, project views), "ask your projects" chat against any OpenAI-compatible LLM.

**Phase 4 — MCP:** `openwhispr-mcp` stdio binary + client installers.

## Prototype spike results (2026-08-31, M4 Max, macOS 26.5.1)

All four planned spikes were built and verified the same day (see `spikes/`); every architecture bet held.

1. **Audio capture** (`spikes/AudioTapSpike`) — ✅ **de-risked.** Process tap + mic aggregate device created successfully first try on macOS 26 (no API drift; `AudioDeviceCreateIOProcIDWithBlock` with an explicit dispatch queue). Correct channel layout (mic ch0 / system-tap ch1), 48 kHz, clean teardown, valid 2-channel WAV. Zero-buffer TCC detector confirmed working. *Remaining human step: grant mic + "System Audio Recording Only" to the terminal and confirm non-zero peaks with real audio.*
2. **PTT + paste** (`spikes/PTTSpike`) — ✅ builds clean; right-⌘ (0x36) edge detection with 0.3 s hold-vs-tap, full clipboard-swap ⌘V recipe, secure-input guard, tap auto re-enable. Graceful no-Accessibility path verified at runtime. Paste-latency floor ~130 ms by construction. *Noted for the real app: use the device-specific right-⌘ flag bit so release is detected while left-⌘ is also held.*
3. **Inference** (`spikes/InferenceSpike`) — ✅ **end-to-end transcription verified.** FluidAudio 0.15.6 + Parakeet TDT v3: word-perfect transcript of a 6.72 s fixture in 107–132 ms → **RTFx 51–63×** on the ANE. Warm model load 0.17 s; first run downloads 469 MB + ~25 s one-time Core ML compile (cache: `~/Library/Application Support/FluidAudio/Models/`). API change vs research: 0.15.x requires caller-owned decoder state (`TdtDecoderState.make` + `transcribe(url, decoderState:)`). Implication: load models once at app launch and keep the manager resident.
4. **UniFFI interop** (`spikes/UniFFISpike`) — ✅ **boundary overhead negligible.** uniffi 0.32 proc-macro mode, Rust static lib linked into a SwiftPM executable; 3,000 × 10 ms PCM buffer pushes → **mean 1.6–2.4 µs per call** (budget was 100 µs; ~0.02% of real time), all 60 callback events received with correct RMS. Gotchas recorded in its README (modulemap `--module-name`, Swift 6 `Sendable` listener, tools-version 6.0).

## Decisions (resolved 2026-08-31)

- **Minimum macOS: 15+** — clean "System Audio Recording Only" permission flow; simplifies the process-tap code path.
- **English-first at launch** — Parakeet TDT v3 only in Phase 1; whisper-rs fallback (multilingual) deferred to a later phase.
- **Open source, distributed via Homebrew.** License: **dual MIT OR Apache-2.0** (Rust ecosystem convention) across the repo.
  - Apache-2.0 provides the patent grant and matches FluidAudio; MIT maximizes reuse. Dual-licensing gives downstream users either.
  - Consequence: VoiceInk (GPL-3) stays strictly reference-only — patterns, not code. WhisperForge/openwhispr (MIT) code may be adapted with attribution.
  - Model weights are CC-BY-4.0 (Parakeet upstream) — attribution required in README/About.
  - `meeting-assistant` code (CC BY-NC) can be relicensed by its author before reuse.
  - **Brew path:** personal tap first (`brew tap tjameswilliams/tap && brew install --cask <name>`), cask pointing at notarized `.app` zips on GitHub Releases (CI: build → codesign with Developer ID → notarytool → staple → upload). Casks do not bypass Gatekeeper, so notarization is still required. Set `auto_updates true` in the cask since Sparkle handles updates. Graduate to `homebrew/cask` once the repo meets its notability bar (GitHub stars/forks thresholds).

## Name: **Hark** (decided 2026-08-31)

Chosen: **Hark** — with a **hawk** as the logo (the author is a falconer). Binaries: `hark`, `hark-mcp`; cask: `brew install --cask hark`. Original candidate analysis below.

### Candidate analysis

Working dir says `lightning-open-whispr` — recommend avoiding the "-whispr/whisper" suffix entirely: the space is saturated (superwhisper, openwhispr, WhisperForge, MacWhisper, TypeWhisper…), it invites confusion with OpenAI's Whisper, and our primary engine isn't even Whisper. Candidates checked against Homebrew, the dictation/transcription category, and domains (2026-08-31):

| Name | Rationale | Conflicts found |
|---|---|---|
| **Hark** (front-runner) | Imperative "listen!" — the app's whole job; crisp CLI binaries (`hark`, `hark-mcp`) | None in brew or category; hark.app registered |
| **Perch** | Where a parakeet sits; a home your speech data comes back to | None in brew or category; perch.app registered |
| **Peal** | A peal of thunder (the lightning motif) and of bells (sound) | None in brew or category; peal.app registered |

Rejected after checks: **Sotto** (≥3 shipping dictation apps by that name), **Starling** (existing open-source Parakeet-based macOS dictation app), **Murmur** (Mumble's server daemon). Before committing: run a USPTO/EUIPO trademark search and grab a `get<name>.dev`-style domain if the .app is parked.
