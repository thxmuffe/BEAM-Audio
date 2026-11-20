# Audio stream control and native audio

**One transport: FLAC over SRTP in BEAM Audio's own engine (owner decision
2026-11-20).** Erlang decides (peers, keys, Session clock, stream anchors) and
supervises; the C++ engine carries and processes the audio. No audio passes
through Erlang. The design is in [AUDIO_ENGINE.md](../../docs/AUDIO_ENGINE.md).

| Where | What |
| --- | --- |
| `engine/` | the C++ engine: speaker, capture, net, timing, control terms, crash reports |
| `adapters/macOS/` | `engine_shell.mm` (Core Audio output, system tap, test tone); `ba_mac_native_audio` (ON AIR) |
| `adapters/iOS/` | `engine_shell.mm` (RemoteIO output, in-process engine); `IOSAudioSession.swift` (shared audio session) |
| `src/` | Erlang: `ba_audio_engine` (one engine per Device), `ba_engine_media_session` (stream setup), subscriptions and publications |

Platforms today: Mac sends system audio (ON AIR) and plays; iPhone plays;
Windows has no audio until its shell exists; no platform sends its microphone yet.

## Running and testing

- Build: `scripts/platforms/macOS/build-engine.sh` (also run by `./build.sh`);
  iOS: `scripts/platforms/iOS/build-engine.sh device`, run by the app's
  runtime preparation. Libraries come from pinned sources via
  `scripts/platforms/prepare-engine-deps.py`.
- Measure: `escript tests/macOS/audio-engine-sync.escript [--audible]
  [--source system] [--seconds N]` runs a sender and two receivers on one Mac
  and reports each engine's scheduling error. This is software scheduling
  evidence, not physical speaker timing.
- Two CLI Devices: see the [CLI README](../Tools/CLI/README.md).
- Crashes: the engine's report (stack trace, last commands, keys redacted) is
  posted to Session chat; `beamaudio monitor` appends chat to
  `builds/live/chat.log`.

Mac ON AIR uses a Core Audio process tap that excludes every running engine
process, so received audio is not captured again. The first capture asks for
macOS's System Audio Recording permission.

## Links

Build commands belong in [BUILDING](../../docs/BUILDING.md). Product permission
and launch instructions are in [macOS](../../../OpenSound/docs/MACOS_APP.md),
[iOS](../../../OpenSound/docs/iOS/README.md) and
[Windows](../../../OpenSound/docs/Windows/README.md).

Current contracts: [streams](../../docs/SESSION_STREAMS.md),
[audio engine](../../docs/AUDIO_ENGINE.md),
[clock](../../docs/SESSION_TIME.md), [architecture](../../docs/ARCHITECTURE.md).
See [current limits](../../docs/PROGRESS.md).

The Device's supervised `ba_audio_observer` samples existing audio/clock state
without starting capture/playback. Its cache feeds both local UI and signed
remote monitoring. Meter/analysis options follow the Device's calibration consent.
See the CLI README for controls, field meanings and privacy/validation limits.
