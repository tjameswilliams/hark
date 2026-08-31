# Hark

**Hold a key. Speak. Release. Clean text lands wherever your cursor is.**

Hark is a fully local, macOS-native transcription tool:

- **Push-to-listen dictation** — hold the right ⌘ key, talk, release; an LLM-cleaned
  transcript is pasted into whatever field is focused, in any app.
- **Meeting transcription** — captures any meeting's audio (Zoom, Teams, mic-only)
  via Core Audio process taps, diarizes it locally, and stores it in SQLite.
- **A knowledge layer** — dictations and meetings are embedded and organized into
  projects; search them, or ask questions through any OpenAI-compatible LLM.
- **MCP server** — `hark-mcp` exposes your meetings and projects to Claude Code,
  OpenCode, and Codex.

Everything runs on-device: NVIDIA Parakeet TDT v3 on the Neural Engine for speech
recognition, local diarization, local embeddings, one SQLite file. No audio leaves
your Mac unless you point the cleanup step at a cloud LLM.

## Status

Pre-alpha. Feasibility spike complete (see [docs/SPIKE.md](docs/SPIKE.md));
prototype spikes for the risky OS surfaces live in [spikes/](spikes/).

## Architecture

- **Swift** owns the OS surface and ML inference: event tap (push-to-talk), paste
  injection, Core Audio process taps, Core ML inference via FluidAudio, menu bar
  and main UI.
- **Rust** owns the engine: session orchestration, SQLite (sqlite-vec + FTS5),
  embeddings, hybrid search, LLM cleanup client, and the MCP server.
- Linked in-process via UniFFI.

Requires macOS 15+, Apple Silicon.

## Repository layout

```
crates/hark-core   Rust engine library
crates/hark-mcp    stdio MCP server binary
spikes/            throwaway prototypes de-risking the OS integration
docs/              spike report and design docs
```

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Speech model weights (NVIDIA Parakeet, via FluidInference's
Core ML conversions) are CC-BY-4.0.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.
