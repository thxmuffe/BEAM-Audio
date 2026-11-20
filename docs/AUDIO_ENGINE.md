# Audio engine design

Owner decisions 2026-11-20. This engine is the only audio implementation; the
earlier GStreamer path and its experiments were removed on 2026-11-20. Status
and next steps are in the [plan](PLAN.md#next-own-audio-engine).

## Principle

Erlang is the network and control layer: it decides everything. The C++ engine
is a slave that executes Erlang's instructions on audio and packets. No audio
sample or encoded packet passes through Erlang; no decision is made in C++.

```
UI (Swift / web)            commands and state only
        │
Erlang/OTP (src/Audio/control, src/control)
  trust, keys, peers, routes, network changes, Session clock,
  stream anchors, supervision, crash reporting to chat
        │  control protocol (length-prefixed messages)
        ▼
C++ engine (src/Audio/engine)            one codebase, all platforms
  UDP sockets · SRTP · FLAC · NACK/RTX · timestamp ring buffer ·
  clock mapping · resampling · mixing · DSP · counters
        │  two C functions, in-process
        ▼
Platform shell (src/Audio/adapters/<platform>)
  permissions, audio session, device callbacks, system capture
        │
OS audio (Core Audio, WASAPI, AAudio/Oboe, PipeWire)
```

## What does what

### Erlang: decides

- **Network setup.** Decides who connects to whom: one ICE connection per
  sender–receiver pair, which it names and opens in the engine, configures
  (STUN and TURN hostnames supplied by `ba_audio_route`, resolved on libjuice's
  resolver thread)
  and whose descriptions it carries in the signed setup messages
  (`signal.endpoint`, `signal.stream`). ICE itself (candidates, checks, path
  choice, NAT traversal, relay) runs in libjuice in the engine.
- **Network change.** Notices new addresses (a 2 s check, and at once on the
  iPhone's path notifications) and starts a new connection (ICE restart); the
  sender follows. Streams are identified by SSRC and SRTP key, so playback
  continues from the same buffer.
- **Keys.** Session control payloads are visible to the Reception, so no key
  ever travels in them. Each side puts an ephemeral X25519 public key in its
  signed stream setup; Erlang derives the 30-byte SRTP master key and salt with
  ECDH + HKDF-SHA256 and hands it to the local engine. No DTLS or SDP: trust
  already lives in Erlang.
- **Clock.** Owns the Session clock and sends the mapping
  `session_ns = host_ns × (1 + ppm) + offset`, refreshed periodically.
- **Stream anchors.** Distributes, per stream, the Session time of RTP sample
  position 0 and the playback delay. With that, every sample has a known play
  time; no RTCP sender reports are needed for timing.
- **Late joins.** Signed `signal.stream` includes the native sender's 48-bit
  `packet_index`. A fresh receiver chooses the nearest extended index for its
  first packet and seeds libsrtp's rollover counter before authentication.
  This preserves ongoing streams after 16-bit sequence wrap without resetting
  an established receiver's replay state. The focused native regression passes;
  deployment and real-phone handover validation remain pending.
- **Lifecycle.** One OTP process owns each engine; the engine is linked to it.
  Commands: `start_speaker`, `stop_speaker`, `start_capture` / `stop_capture`
  (system audio, microphone; several at once), `connect`, `remote`,
  `disconnect`, `route`, `clock_map`, `volume`, `delay`, `status`.
- **Crashes.** Let it crash. The supervisor restarts the engine; the crash
  report, with stack trace, is posted to Session chat.

### C++ engine: executes

| Part | Library | Ours |
| --- | --- | --- |
| UDP sockets, batched receive | OS sockets (`recvmmsg` where available) | socket loop |
| Encryption | **libsrtp** | — |
| Codec | **libFLAC** (lossless, owner choice for development) | — |
| Connectivity | **libjuice** (MPL-2.0): ICE, STUN, TURN | thin wrapper (`ice.*`) |
| Packet recovery | — | NACK and resend from history (`recovery.*`, ~80 lines) |
| Buffer | — | ring buffer indexed by RTP timestamp; a late or missing slot fades to silence and resumes in sync |
| Timing | — | compare each sample's Session play time with the callback's hardware host time; small error → resampler ratio, large error → one skip/insert |
| Resampling | **libsamplerate** (variable ratio) | — |
| Mixing | — | sum with gains |
| Crash traces | **cpptrace** (MIT) | crash handler |

Real-time rule: the audio callback and the packet loop never allocate, lock or
throw. Setup and control code is ordinary C++17.

A fixed playback delay on a shared clock makes adaptive jitter buffering
unnecessary: packets go to the slot their timestamp names, playback reads by time.

### Platform shell: owns the OS

Permissions, audio session (iOS `AVAudioSession`, interruptions, route changes,
background), opening the device and running its real-time callback, and
platform-specific sources (Mac process tap, Windows loopback). Swift may manage
the session; real-time callbacks are C/Objective-C++. The shell calls the
engine in-process:

```cpp
void ba_engine_render(float *out, uint32_t frames, uint64_t host_time_ns);
void ba_engine_capture(const float *in, uint32_t frames, uint64_t host_time_ns);
```

The host timestamp comes from the OS callback (Core Audio `mHostTime`, WASAPI
`IAudioClock`, AAudio timestamps), which is why device I/O stays native rather
than behind a portable audio library.

| Platform | Device API | Shell language |
| --- | --- | --- |
| macOS | Core Audio (AudioUnit, process tap) | Objective-C++ |
| iOS | Core Audio (AudioUnit), `AVAudioSession` | Objective-C++ + Swift |
| Windows | WASAPI (incl. loopback) | C++ |
| Android | Oboe/AAudio | C++ + Kotlin |
| Linux | PipeWire | C++ |

## Source layout (`src/Audio/engine/`)

| File | Role |
| --- | --- |
| `engine.h` | API for shells: `Shell` interface, `ba_engine_render`, `ba_engine_capture` |
| `engine.cpp` | control loop, packet thread, command dispatch |
| `speaker.*` | receive: SRTP, FLAC decode, timestamp ring, render with drift correction |
| `capture.*` | send: capture ring, resample onto Session time, FLAC encode, SRTP send |
| `timing.h` | clock mapping, servo, error summary |
| `net.*` | packet formats: SRTP sessions, RTP header |
| `ice.*` | connectivity: ICE connections (libjuice), events to Erlang, inbound queue |
| `recovery.*` | lost-packet recovery: loss tracking, NACK, resend history |
| `term.*` | Erlang external term format via OTP's `ei` |
| `crash.cpp` | crash reports (cpptrace) |

The macOS shell is `src/Audio/adapters/macOS/engine_shell.mm`; the Erlang owner
is `src/Audio/control/engine/ba_audio_engine.erl`. Build with
`scripts/platforms/macOS/build-engine.sh` (pinned libraries via
`prepare-engine-deps.py`).

## Hosting and the control protocol

- **Where the OS allows child processes** (macOS, Windows, Linux): the engine is
  an executable started with `open_port({spawn_executable, …}, [{packet, 4},
  exit_status, binary])`, following the OTP interoperability guide: messages
  are `term_to_binary` maps decoded with OTP's `ei`, raw `read(0)`/`write(1)`
  (never C stdio on the protocol channel), diagnostics on stderr, exit on stdin
  EOF. An engine crash is an `exit_status` to its owner, which stops and is
  restarted by its supervisor. OTP recommends external ports over NIFs or
  linked-in drivers because a native fault there takes down the whole VM.
- **iOS** cannot spawn processes, so the engine runs in-process on its own
  thread with the same message protocol. A crash there ends the app; the crash
  report is written to a file and posted to chat on the next launch.
- Messages are small maps (commands, events, bounded counters). Never audio.
  Every command carries an `id`; the reply is `#{event := <<"ok">> | <<"error">>,
  id, op, ...}`. Unsolicited events (e.g. `capture_started` with the stream
  anchor) go to the owner as `{ba_audio_engine, Pid, Event}`.

## Crash reporting

- The engine installs handlers for fatal signals and `std::terminate` (Windows
  unhandled exceptions with the Windows shell). Each writes a report: reason,
  symbolized stack trace with file:line (cpptrace, template arguments pruned),
  and the last eight commands with SRTP keys redacted. Symbolizing inside a
  signal handler is best effort.
- The report goes to stderr of the port (desktop) and to a crash file in the
  Device's data directory (all platforms).
- Erlang's engine owner reads the report on exit and posts it **in full** to
  Session chat. The existing crash notice deliberately strips detail; during
  development native crash reports are an owner-approved exception, to be
  hidden later.

## Chat to a file for live tests

Live manual tests run an Inspector from the CLI that follows Session chat and
appends every line to `builds/live/chat.log` (timestamp, Device, text). Claude
reads that file while the owner tests. It works for every platform's crashes,
including the iPhone, because they arrive through the shared chat.

## Requirements and how they are met

| Requirement | How |
| --- | --- |
| All platforms | one C++ engine; small native shell per platform |
| Wi-Fi ↔ mobile data | ICE restart on address change; mobile-data failure under investigation, detailed ICE checks needed before deciding whether TURN is necessary |
| Fast networks | one packet thread, batched receive, lock-free handoff to the callback; no Erlang in the packet path |
| Our choice of parts | codec, encryption, recovery, resampler and DSP sit behind internal function boundaries; no plugin system until needed |
| Visible failures | let it crash, full trace in chat and in `builds/live/chat.log` |
