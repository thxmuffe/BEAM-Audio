# Audio stream control and native audio

**One transport: FLAC over SRTP in BEAM Audio's own engine (owner decision
2026-11-20).** Erlang decides (peers, keys, Session clock, stream anchors) and
supervises; the C++ engine carries and processes the audio. No audio passes
through Erlang. The design is in [AUDIO_ENGINE.md](../../docs/AUDIO_ENGINE.md).

Three layers: `control/` decides, `engine/` executes, `adapters/` connect to the OS.

| Where | What |
| --- | --- |
| `control/` | Erlang: `ba_audio_sup` (the audio supervisor of a Session) |
| `control/engine/` | `ba_audio_engine` (owns the Device's one engine process), ICE configuration (`ba_audio_route`), child environment |
| `control/streams/` | subscriptions and receiving, stream setup on the engine (`ba_engine_media_session`), the stream protocol |
| `control/sources/` | publications (ON AIR) and capture: system audio and microphone |
| `control/diagnostics/` | bounded, payload-free observations for the monitor and chat |
| `engine/` | the C++ engine: speaker, capture, ICE, recovery, timing, control terms, crash reports |
| `adapters/macOS/` | `engine_shell.mm` (Core Audio output, system tap, microphone, test tone) |
| `adapters/iOS/` | `engine_shell.mm` (RemoteIO output and microphone, in-process engine); `IOSAudioSession.swift` (shared audio session) |

Platforms today: Mac sends system audio and microphone and plays; iPhone sends
its microphone and plays; Windows has no audio until its shell exists.

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

ICE server hostnames from `direct_stun_urls` and `audio_turn_servers` are passed
to libjuice, which resolves them on its resolver thread. Do not pre-resolve and
keep only one address family. `BA_ICE_DEBUG=1` enables libjuice connectivity
checks on stderr; the Session chat log contains notices, not these detailed
checks. Failed ICE workers terminate so subscriptions can retry. Mobile playback
was heard after an ON AIR restart; no TURN was needed for that test.

Signed stream setup includes the native sender's 48-bit `packet_index`. A new
receiver uses it to seed libsrtp's rollover counter before authentication, allowing
late joins after the 16-bit RTP sequence wraps. Existing receivers keep replay
protection. Run `python3 tests/transport/srtp-rejoin.py` from the core root on
macOS with the pinned libsrtp build present. This latest fix still needs app
rebuilds and a real Wi-Fi/mobile handover test after more than 262 seconds.

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
remote monitoring. Private metrics and meter/analysis options follow the Device's
Inspect consent, independently of calibration. Inspect also gates bounded runtime
log reads through signed Session control; USB is unnecessary when control is reachable.
The native speaker mixer reports its most recent block's normalization gain
through the same observation. The CLI labels it `mix gain` in dB.
See the CLI README for controls, field meanings and privacy/validation limits.

Experimental track requests use the macOS shell's Music adapter. It checks
that Music is actively using the output being captured and that it has a
finite, non-URL track playing. macOS may request Automation permission.
The command result can include the track title, which the runtime sends
only to the Device that requested the change.
