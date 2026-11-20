# Shared audio runtime

**One transport: native AAC over GStreamer RTP (owner decision 2026-11-19).**
Erlang connects, configures and supervises the pipes; audio stays in native
code. The PCM-through-Erlang path (Mixer, PCM data channel, packet handlers,
platform PCM adapters) and the Opus path were deleted. Consequences until native
coverage grows: Mac sends system audio (ON AIR) from the CLI helper only, the
Mac app has no audio (GStreamer and the native host are not packaged into it),
the iPhone app receives, Windows sends and receives through its own native
host (2026-11-20, below), and microphones have no audio. Packet
recovery (RTP retransmission within the buffer, then redundancy for bursts) is
the next audio work.

Mac ON AIR uses a Core Audio process tap, so capture selection and speaker output
are separate. The tap excludes our configured playback-helper executable across
local instances and updates its process list only when the excluded set changes;
unrelated audio-process notifications do not rewrite the running tap. See Apple's
[process-filtered device tap](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses%3Aanddeviceuid%3Awithstream%3A).

## Native AAC

The owner approved AAC-LC at **320 kb/s stereo** for music. The new path is:
Core Audio tap → native interleaving → Apple AAC encoder → GStreamer RTP/WebRTC
(DTLS-SRTP) → native AAC decoder → native output. No PCM or encoded media enters
Erlang, its ports or sockets. Source metadata is float32 at 44.1 or 48 kHz,
stereo; the current `atenc` element requires an explicit native 16-bit PCM
conversion before AAC encoding. Other capture formats are rejected. This is
lossy encoding and is not a bit-exact float transport. No voice processing,
automatic gain control or noise suppression is inserted.

`ba_mac_native_audio` owns the capture helper port and a normal Source publication.
The `gst_aac_rtp_v2` catalogue profile selects `ba_native_media_session` through
the installed handler allowlist. The Media Session owns the native control socket
and routes only SDP/ICE through existing authenticated Session signalling. It
registers Playback execution with the existing permission registry and validates
its grant/authorization before starting and on each heartbeat. Required OTP
owner/supervisor/registry loss stops that endpoint; source-owner loss ends the
Mac helper. Helpers are not daemons and do not spawn media descendants.

For setup diagnosis, read the Device's `runtime.log`: `Native provider closed`
identifies the control path that removed a sending stream; attach failures and
worker exits are logged separately. An initial `native_clock_mapping_failed`
retains the clock planner's reason. These records contain control reasons, not
SDP or audio. Rebuild/restart the affected app to load Erlang changes; an iPhone
runtime update requires a new app build.

ICE signalling accepts an empty candidate string as the standard end of
candidate gathering and forwards it to GStreamer (see
[GStreamer's candidate API](https://gstreamer.freedesktop.org/documentation/webrtc/#webrtcbin::add-ice-candidate)). Both sending and receiving
apps must include this schema fix; older validators close their local media
attempt when the native host emits the marker.

Control protocol v2 has a generation-fenced hello and confirmed stop response.
The native host watches control independently of the media loop: socket EOF
starts teardown, two seconds without valid control also stops it, and cleanup
that stalls for 1.5 seconds terminates the helper (the host app on iOS). The Mac
source helper separately watches its owning pipe, including during capture
startup. Stop flushes instead of draining buffered music. EOF triggers
cleanup but never substitutes for a stop acknowledgement.

**Session scheduling is implemented but physical synchronization is unqualified.**
Streams report `synchronized=false`. Both hosts need the v2 media profile; the
older unscheduled v1 profile is rejected.

Before prepare, OTP takes five local control clock observations, selects the
lowest round trip and maps a private native GstClock to the existing Session
reference. Nanosecond values cross JSON as decimal strings. Refreshes every
five seconds preserve clock phase and adjust its rate within ±500 ppm over a
five-second correction horizon. A mapping expires after twelve seconds even
if control heartbeats continue. Status exposes the local control round trip;
that is not a bound on Session clock error or acoustic accuracy.

Core Audio sample positions and their initial host-time anchor determine native
source timestamps, including capture gaps. RTP uses the sample clock; standard
RTCP sender reports map it to the calibrated clock in the NTP epoch. Reports
start with a short burst, then refresh about every five seconds. GStreamer's
native reference-timestamp metadata reconstructs capture time at the receiver;
unmapped initial packets are dropped. The output schedules that time plus the
Session Response time. GStreamer's reported downstream/output latency is
reserved inside that total budget before configuring the RTP jitterbuffer;
BaseSink's render-delay mechanism submits buffers early for native output. No arrival-time
fallback or per-packet Erlang decision is used. Apple output uses GStreamer's
native resampling clock-slave mechanism; sustained correction needs hardware
qualification. A timeline or Response-policy revision change ends/recreates the
stream rather than retiming queued audio.

The initial jitter budget starts at the selected Session Response time,
within 0–10,000 ms, and decreases by negotiated downstream latency. A Response
time below the native output minimum is not yet rejected explicitly; it can
still miss the presentation deadline. Demand-based buffer policy, combined queue budgets and packet
recovery remain to do. TURN configuration currently returns an explicit
unsupported error; STUN/ICE is reused and Reception is unchanged. There is no
native microphone capture yet.

Build the development helper from the core checkout:

```sh
python3 scripts/platforms/macOS/prepare-gstreamer.py --native-stream-headers
bash scripts/platforms/macOS/build-native-stream.sh
```

The helper uses the pinned 1.28.8 runtime. The current build script can reuse the
matching cached iOS SDK headers plus a checksum-pinned macOS header overlay;
set `BA_GSTREAMER_HEADERS` to matching desktop SDK headers to use those instead.
It neither installs GStreamer system-wide nor packages it into the Mac app.
The ordinary core/CLI also needs its usual build after Erlang source changes.

For a Mac source, start the public CLI:

```sh
bin/beamaudio new device --devicename Native-Mac --createbuffee
bin/beamaudio call device --devicename Native-Mac --request '{"method":"capability","capability":"broadcast","enabled":true}'
```

The CLI resolves the helper and runtime from the core build directory; optional
`BA_MAC_NATIVE_STREAM_HELPER` and `BA_GSTREAMER_RUNTIME` override those paths.
Use the ordinary invitation command to join the iPhone, rebuilt with current
core sources/resources. The iPhone host always starts its native listener and
supplies `BA_NATIVE_STREAM_PORT` to BEAM. Allow Playback through the existing
consent controls.

Critical checks (no live Devices or physical audio capture):

```sh
python3 tests/transport/native-stream-smoke.py
rebar3 eunit --module=ba_native_stream_tests
```

The native smoke uses generated audio and `fakesink` in two helper processes.
The sink simulates 200 ms output latency and a 20 ms lateness limit, checking
that RTP buffering leaves output lead within the total Response budget;
it routes JSON control/signalling only. Its reference is deliberately three
hours away from OS UTC. It checks prompt RTCP mapping, periodic clock refresh,
decoded/scheduled output, correlated stop, control loss/timeout, clock expiry,
source-owner exit and a deliberately blocked media loop. Schedule error is
measured at a silent software sink, not a speaker.
The OTP checks cover explicit native offers, owner/session/supervisor/registry
loss, revocation acknowledgement and clock-policy mapping. These are software lifecycle/media checks,
not music-quality, hardware-tail or acoustic-synchronization evidence. The iOS
native source and Swift session/bridge API pass targeted compile checks; the
full app was not built or installed.

## Windows native host

`adapters/Windows/native_stream.cpp` is the Windows port of
`GStreamerStreamHost.mm`, with the same `gst_aac_rtp_v2` control protocol and
lifetime rules. AAC uses FFmpeg's LGPL `avenc_aac` (320 kb/s) / `avdec_aac`; output is
`wasapi2sink` with native resampling; ON AIR is one `wasapi2src` loopback
capture (48 kHz stereo float) feeding every provider peer, excluding BEAM's
process tree so the Device's own playback is not sent back. Modes: default
(capture + host, `ba_windows_native_audio`), `--host` (receiving host owned by
`ba_windows_native_host`, which sets `BA_NATIVE_STREAM_PORT`) and
`--protocol-test`.

```sh
python scripts/platforms/Windows/build-native-stream.py
python tests/transport/native-stream-smoke.py
```

The build installs the pinned official GStreamer 1.28.8 MSVC package
(`scripts/platforms/Windows/gstreamer-sdk.json`) per user into
`builds/intermediates/Windows/gstreamer-sdk`, or uses `BA_GSTREAMER_SDK`. Its
output `builds/CLI/native-stream/` holds the helper, only the DLLs it and the
selected plugins import, `plugins/`, licence texts and the app-local Visual C++
runtime. The smoke test selects it on Windows (`BA_WINDOWS_NATIVE_STREAM_HELPER`
overrides). The CLI (`ba_cli_device`) still configures the Mac helper only.

## Links

Build commands belong in [BUILDING](../../docs/BUILDING.md). Product permission
and launch instructions are in [macOS](../../../OpenSound/docs/MACOS_APP.md),
[iOS](../../../OpenSound/docs/iOS/README.md) and
[Windows](../../../OpenSound/docs/Windows/README.md).

Current contracts: [streams](../../docs/BUFFEE_STREAMS.md),
[engine interface](../../docs/AUDIO_ENGINE_INTERFACE.md),
[clock](../../docs/BUFFEE_TIME.md), [architecture](../../docs/ARCHITECTURE.md).
User listening confirms audible microphone output; quality and physical speaker
timing remain unqualified. See [current limits](../../docs/PROGRESS.md).

The Device's supervised `ba_audio_observer` samples existing audio/clock state
without starting capture/playback. Its cache feeds both local UI and signed
remote monitoring. Meter/analysis options follow the Device's calibration consent.
See the CLI README for controls, field meanings and privacy/validation limits.
