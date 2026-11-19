# Shared audio runtime

Architecture clarified 2026-11-18: Erlang connects, configures and supervises the
pipes; audio payloads stay in native code and OS/media libraries. This applies
to encoded media as well as PCM. The current default described below does not
meet this boundary: it carries PCM through Erlang and mixes it there. It remains
legacy implementation while a complete native pipeline is integrated. Existing
native receiver prototypes do not yet provide that complete production path.
The accepted replacement uses continuous native streams with sample positions
and periodic shared-clock mappings, preferably RTP/RTCP, rather than requiring
independent absolute targets on every packet. Acquire an initial mapping promptly;
native buffering/recovery and smooth rate correction follow Session policy.
GStreamer is selected for the first complete native integration. The
[replacement control contract](../../docs/AUDIO_ENGINE_INTERFACE.md#native-stream-decision--2026-11-18)
requires teardown on OTP owner/supervisor loss and variable native buffering up
to ten seconds. The first AAC implementation is a development trial below;
Session timing is connected in the trial; continuous playback correction and
ten-second buffering qualification remain unfinished. The default remains the
legacy path described later.

## Native AAC development trial

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

Control protocol v2 has a generation-fenced hello and confirmed stop response.
The native host watches control independently of the media loop: socket EOF
starts teardown, two seconds without valid control also stops it, and cleanup
that stalls for 1.5 seconds terminates the helper (the host app on iOS). The Mac
source helper separately watches its owning pipe, including during capture
startup. Stop flushes instead of draining buffered music. EOF triggers
cleanup but never substitutes for a stop acknowledgement.

**Session scheduling is implemented but physical synchronization is unqualified.**
The trial requires `BA_NATIVE_STREAM_TRIAL=1` on both hosts and continues to
report `synchronized=false`. Rebuild both hosts for the v2 media profile; the
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
Session Response time, compensating for native pipeline latency. No arrival-time
fallback or per-packet Erlang decision is used. Apple output uses GStreamer's
native resampling clock-slave mechanism; sustained correction needs hardware
qualification. A timeline or Response-policy revision change ends/recreates the
trial stream rather than retiming queued audio.

The initial jitter latency follows Session Response time (normally 800 ms),
within 0–10,000 ms. Demand-based buffer policy, combined queue budgets and packet
recovery remain step 4. This trial must remain opt-in pending qualification. TURN
configuration currently returns an explicit unsupported error; this increment
reuses STUN/ICE and does not change Reception. Microphone and other existing
inputs remain on their previous implementations.

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

For a disposable Mac source, start the public CLI with the trial flag:

```sh
BA_NATIVE_STREAM_TRIAL=1 bin/beamaudio new device --devicename Native-Mac --createbuffee
bin/beamaudio call device --devicename Native-Mac --request '{"method":"capability","capability":"broadcast","enabled":true}'
```

The CLI resolves the helper and runtime from the core build directory; optional
`BA_MAC_NATIVE_STREAM_HELPER` and `BA_GSTREAMER_RUNTIME` override those paths.
Use the ordinary invitation command to join the iPhone. Add
`BA_NATIVE_STREAM_TRIAL=1` to its Xcode Run scheme environment and rebuild with
current core sources/resources. The iPhone host starts its local native listener
and supplies `BA_NATIVE_STREAM_PORT` to BEAM automatically. Allow Playback through
the existing consent controls. To leave the trial, stop the disposable CLI Device
and relaunch the iPhone without that environment flag. These manual device steps
have not been executed or listening-qualified in this increment.

Critical checks (no live Devices or physical audio capture):

```sh
python3 tests/transport/native-stream-smoke.py
rebar3 eunit --module=ba_native_stream_tests
```

The native smoke uses generated audio and `fakesink` in two helper processes;
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

## Legacy implementation


Shared Erlang modules in `src/` own publication, metering, interpretation,
subscription/Contract lifetimes, timing policy and backend lifecycle. Adapters
under `adapters/macOS`, `adapters/iOS` and `adapters/Windows` bind platform APIs,
provide buffers/formats/monotonic timestamps and execute approved output work.
Platform-specific Erlang adapters live alongside their native bindings.

Handlers under `handlers/` supply isolated media transport. The current PCM path
uses WebRTC; optional native engines remain isolated experiments until justified
by timing, playback and recovery evidence. No library may silently replace a
broadcaster's independently assigned target on any packet.

Sources retain explicit formats. The reference Mixer currently needs compatible
rate and clock; unsupported formats and missed/overlapping/output failures remain
visible in diagnostics. Local consent is mandatory. Guest microphones are
permitted; other publication requires Chef authorization.

Fresh authenticated raw clock time is usable before the median window fills.
`clock.estimate_quality` distinguishes provisional/reference/filtered estimates;
`clock.raw_offset_ns` carries the raw measurement as a decimal string. Filter
fullness no longer blocks playback startup, while authorization, freshness and
post-resume observation checks remain. Clock acquisition starts on Session join,
independent of speaker use: a short burst takes up to five samples, 250 ms apart,
or finishes two seconds after the first valid reply. The lowest-RTT observation
sets the initial audio mapping directly before scheduling is allowed. Raw time
remains visible during this calibration. Diagnostics expose
`clock.initial_sync_complete`, `clock.initial_sync_samples` and
`clock.initial_sync_round_trip_ns`; completion is not an acoustic accuracy claim.
Same-source overlap is still rejected:
clock-rate correction with continuous resampling and deliberate-splice crossfades
is proposed work, not part of this startup change.

iOS output reports an individual rejected buffer to Erlang without closing the
engine or changing later targets. `monitor --metrics` exposes
`mixer.failure.<reason>` for `native_late_packet`, `native_target_out_of_bounds`
and `native_output_queue_full`. Native
analysis reports target-lead bounds; per-buffer rejection logging is avoided. Local output TCP uses NODELAY.
`mixer.output_stop_pending: true` means a failed output has not acknowledged
stop; it cannot be reused as healthy. EOF alone does not confirm native stop.
iOS output handshake v2 (`<<1,2>>`) supports stop confirmation on a fresh
connection after a broken output socket: its serial listener acknowledges
`<<4>>` only after the previous engine and audio session have finished cleanup.
Erlang reopens output only after that acknowledgement. Older bindings and
missing acknowledgements remain fenced; no packet target is changed.

Missed-output-time drops are summarized over five seconds and announced in
Session chat, at most once per 30 seconds per Device. With measured overshoot,
the warning gives mean lateness and the estimated required Response time.
iOS handshake v3 (`<<1,3>>`) reports native late rejection as
`<<5,1,LatenessNanoseconds:64>>`; older rejections have no measured overshoot.
In Automatic mode, the clock authority applies increasingly weighted increases
from these reports, never raising to 3 seconds. Manual mode only reports advice.
This changes future source targets, never an assigned packet's playback time.
Rebuild/run the iPhone app to update both sides of the local binding protocol.
Focused hardware-free protocol checks: `rebar3 eunit --module=ba_ios_audio_tests`.

For bursts followed by silence, inspect `clock.filter_reset_reason` and
`clock.filter_reset_count` alongside `clock.filter_ready` and clock state.
Reasons distinguish `resume`, `network_changed`, `sample_gap`,
`reference_changed`, `scope_changed` and `permission_unavailable`.
`receiver.suspended`, `receiver.active_subscriptions`,
`receiver.mix_ready_subscriptions`, `transport.sessions` and `transport.open`
distinguish saved intent from live media work. Speaker `ready` means capability
availability; receive/render counters alone do not prove physical output.
Network-path hints refresh discovery without discarding clock samples or closing
healthy media. Connection, lease and clock-freshness checks handle actual failures.

Build commands belong in [BUILDING](../../docs/BUILDING.md). Product permission
and launch instructions are in [macOS](../../../OpenSound/docs/MACOS_APP.md),
[iOS](../../../OpenSound/docs/iOS/README.md) and
[Windows](../../../OpenSound/docs/Windows/README.md).

Current contracts: [streams](../../docs/BUFFEE_STREAMS.md),
[engine interface](../../docs/AUDIO_ENGINE_INTERFACE.md),
[clock](../../docs/BUFFEE_TIME.md), [architecture](../../docs/ARCHITECTURE.md).
User listening confirms audible microphone output; quality and physical speaker
timing remain unqualified. See [current limits](../../docs/PROGRESS.md).

Optional output diagnostics use `diagnostics(Handle, Options)` on an adapter.
It returns `{ok, Summary}`, `pending` for an asynchronous local response, or
`unsupported`. The Mixer polls every 500 ms; a binding must not synchronously
wait for native playback or run DSP here. iOS protocol v1 advertises readiness
`<<1,1>>`, accepts `<<6,Enabled>>` for analysis and `<<7>>` for a fixed-size
summary; old `<<1>>` bindings remain usable without this extension. Completion
callbacks only update locked bounded native counters; socket replies stay on
the binding's serial queue. Erlang retains all sample interpretation and policy.

The Device's supervised `ba_audio_observer` samples existing audio/clock state
without starting capture/playback. Its cache feeds both local UI and signed
remote monitoring. Meter/analysis options follow the Device's calibration consent.
See the CLI README for controls, field meanings and privacy/validation limits.
