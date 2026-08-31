# AudioTapSpike

Prototype spike #1 for Hark's meeting-capture feature: capture **system audio**
(Core Audio process tap) **plus the default microphone** into a single stereo
WAV file.

- **Channel 0 = microphone** (mono mixdown of the default input device)
- **Channel 1 = system audio** (global stereo process-tap mixdown, averaged to mono)

Output is 16-bit PCM at the aggregate device's nominal rate (typically 48 kHz —
the actual rate is printed and written into the WAV header; no resampling is
performed).

## How it works

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` — a global stereo
   mixdown tap of *all* processes (empty exclusion list), marked `isPrivate`,
   mute behavior `.unmuted`. (Equivalent intent to
   `stereoMixdownOfProcesses: []`; the exclude-variant is unambiguous about
   "tap everything".)
2. `AudioHardwareCreateProcessTap` turns that into a tap audio object.
3. `AudioHardwareCreateAggregateDevice` builds a **private** aggregate device:
   - **default output device as the MAIN sub-device** (tap-as-main yields
     silence — the output device provides the clock),
   - default input (mic) as a second sub-device with
     `kAudioSubDeviceDriftCompensationKey`,
   - the tap under `kAudioAggregateDeviceTapListKey` with drift compensation
     and `kAudioAggregateDeviceTapAutoStartKey: true`.
4. `AudioDeviceCreateIOProcIDWithBlock` (with an explicit serial dispatch
   queue) + `AudioDeviceStart`. The input `AudioBufferList` carries the
   sub-devices' input streams in list order: **buffer 0 = mic**, **last buffer
   = tap** (the output device contributes no input streams). Both layouts are
   logged at startup and on the first IO callback.
5. Each callback downmixes mic → ch0 and tap → ch1 as Float32, tracks peak
   absolute level per channel, converts to interleaved Int16, and accumulates
   in memory; the WAV (hand-written 44-byte header) is written on exit.
6. Teardown on timer expiry or SIGINT: `AudioDeviceStop` →
   `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
   `AudioHardwareDestroyProcessTap`.

The tap/aggregate recipe is adapted from
[insidegui/AudioCap](https://github.com/insidegui/AudioCap) (BSD-2-Clause) and
Apple's ["Capturing system audio with Core Audio taps"](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

## Build & run

```sh
cd spikes/AudioTapSpike
swift build
.build/debug/audiotap [seconds] [output.wav]   # defaults: 10 seconds, capture.wav
```

While it records: play some audio (music/video) and speak into the mic.
Ctrl-C stops early and still writes the WAV.

Verify the result, e.g. `afplay capture.wav`, or open in Audacity — left
channel should be your voice, right channel the played audio.

## TCC permissions (read this before trusting silence)

Because this is an unbundled CLI, both permissions attribute to the
**invoking terminal app** (Terminal, iTerm2, VS Code, ...):

- **Microphone**: a normal TCC prompt fires on first use. Approve it and
  re-run if the first run was silent.
- **System audio**: System Settings → Privacy & Security →
  **Screen & System Audio Recording** → "System Audio Recording Only" — add or
  enable your terminal app. A prompt may or may not appear.

**Critical failure mode: TCC denial is SILENT.** Core Audio returns `noErr`
everywhere and simply delivers all-zero buffers. The spike therefore tracks the
peak absolute sample per channel and prints at exit:

```
Peak levels:
  ch0 (microphone):      peak 0.031250  (-30.1 dBFS)
  ch1 (system audio):    peak 0.000000  (-inf dBFS)
    -> channel was ALL ZEROS — likely System Audio Recording permission denied ...
```

Interpretation:

- **Both channels non-zero** → success; inspect the WAV.
- **ch0 zero** → mic permission denied, mic muted/unplugged, or nobody spoke.
- **ch1 zero** → System Audio Recording permission denied for the terminal, or
  no audio was actually playing during capture.
- **"only one input buffer present" warning** → the aggregate came up without
  one of its sub-devices; check the logged stream layout.

## macOS 26 notes (Xcode 26.6, Swift 6.3)

- **No API drift encountered.** `AudioDeviceCreateIOProcIDWithBlock` worked
  first try in its standard 4-argument form
  (`&procID, deviceID, queue, block`) with an explicit serial
  `DispatchQueue` — we always pass one rather than `nil`, which is the form
  reported to be reliable on macOS 26.
- The `kAudioAggregateDevice*` / `kAudioSubTap*` / `kAudioSubDevice*` dictionary
  keys and `CATapDescription` (Obj-C class from CoreAudio) all import cleanly
  under Swift 6 language mode; the only concurrency accommodations needed were
  `@preconcurrency import CoreAudio/AudioToolbox`, an `@unchecked Sendable`
  recorder class, and one `nonisolated(unsafe)` flag for the SIGINT handler.
- SwiftPM emits an `audiotap-entitlement.plist` during build (get-task-allow);
  nothing audio-related needs entitlements for a CLI — only TCC grants.

## Status

- `swift build`: **clean** (no errors, no warnings).
- Smoke-tested on macOS 26.5.1 (2-second run, sandboxed agent shell, AirPods
  Max as default in/out): tap object and aggregate device created successfully,
  IOProc ran (68 callbacks), stream layout was exactly as designed
  (`#0: 1ch` mic buffer, `#1: 2ch` tap buffer), clean teardown, valid WAV
  written. Both channels were all zeros — expected, since that shell had no
  mic/system-audio TCC grants and no audio was playing; the zero-buffer
  detector flagged both channels correctly.
- **Human still needs to**: run it from a real terminal, approve the mic
  prompt, enable System Audio Recording (Only) for the terminal app, play
  audio + speak during a run, and confirm the WAV contains voice on the left
  and system audio on the right.
