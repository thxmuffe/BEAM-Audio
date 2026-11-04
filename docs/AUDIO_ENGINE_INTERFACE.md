# Receiver media engine interface

Implemented 2026-11-03 as step 2 of the simultaneous-playback plan. The
2026-11-04 contract correction replaces anchor-derived playback timing with
independent per-packet targets. iPhone GStreamer implements the new executor;
Windows GStreamer and libwebrtc reject scheduled subscription until their
executors exist. Physical speaker synchronization remains unqualified.

## Authoritative per-packet target

The broadcaster assigns a target to every audio packet. Receivers execute that
original target or report failure. They may reorder transport packets and decode
media, but must not infer missing targets from neighbours, use arrival order as
a playback timeline, or adaptively choose replacement deadlines.

The Opus RTP profile now declares `rtp_timestamp_semantics=global_playback_48k_v1`
and `presentation_stream_id` in its descriptor. Subscription requests explicitly
require that clock profile. Each RTP timestamp is the low 32 bits of the packet's
POSIX-epoch playback time in 48000 ticks/second. It is **not** a random-origin
source sample counter. Both peers must be updated; legacy profiles are rejected.
Sender assignment is quantized to the representable tick before it is stored,
so receiver decoding recovers precisely that assigned value. Tick resolution is
20.833 microseconds; rounding differs from the ideal target by at most half a
tick. No periodic source timing anchor is needed to resolve an individual target.

The shared clock resolves the nearest 32-bit era (wrap approximately every
24.86 hours); a target more than 60 seconds from receiver reference time is
rejected. Configured cluster target offset is at most 30 seconds. This conversion
uses the shared reference only, never neighbouring packets. Periodic source
observations retained for diagnostics do not supply packet playback deadlines.

Erlang maps each target to receiver monotonic time and combines the native clock
observation with GstSegment/base-time/latency information. Its packet-correlated
plan carries `packet_id`, `rtp_timestamp`, target, generation and local sink
coordinates. iPhone's decoder worker awaits its own decision, rewrites only that
buffer's PTS, and rejects missing, mismatched, stale, timed-out or late decisions.
There is no persistent sink offset used to choose later packets' targets.
A packet rejection wakes only that packet's worker. Closure also wakes the worker
before stopping the pipeline. Adaptive sink rate matching is disabled.

The scheduled boundary is the GStreamer sink clock, not measured acoustic
emission. `calibrated_output_latency_ns=null` means uncalibrated, not zero.
Counter evidence distinguishes receipt, decode, probe acceptance and sink
submission; none alone proves sound came out at the requested instant.

## Ownership

| Layer | Responsibility |
| --- | --- |
| OpenSound UI | Existing subscribe/play/pause/buffering commands and state display. |
| Shared Erlang runtime | Admission, source discovery, subscription ownership, shared clock, presentation targets, output-path calibration policy and correction limits. |
| Stream handler | Wire profile, peer SDP/ICE/RTP, source sequence/sample/timeline association. The current Opus handler uses ExWebRTC on the provider. |
| Receiver engine | Native media negotiation, jitter/decode, device execution, local output observations and lifecycle through its binding. |
| Platform binding | Starts the installed native service, selects its local engine adapter, transfers native buffers and supplies OS timing. |

`parvi_audio_stream_handler` remains the wire-format boundary, including the
legacy PCM/data-channel implementation. `parvi_audio_engine` is the new native
receiver execution behaviour. Both current engines implement the same WebRTC/
Opus wire profile, so the sender, cluster transport and UI can stay unchanged
when the receiver's native implementation changes. An uncompressed RTP backend
would also need its corresponding wire handler and connectivity/security work.

The existing `parvi_webrtc_audio_session` gen_statem owns the engine handle and
socket. It calls the engine callbacks directly. The audio supervisor still owns
session lifetime; source/peer/consumer monitoring and SDP/ICE routing remain in
Erlang. There is no additional forwarding process, registry or OTP application.
This follows the standard [OTP behaviour/worker separation](https://www.erlang.org/doc/system/design_principles.html).

## Implementations and selection

- `parvi_audio_engine_libwebrtc`: current iPhone libwebrtc/NetEq and signed
  16-bit RemoteIO output binding.
- `parvi_audio_engine_gstreamer`: current Windows webrtcbin/Opus and float32
  WASAPI output binding.
- `parvi_audio_native_engine`: their shared packet-4 JSON socket binding. Native
  Swift/Python implementations remain in their platform adapter directories.

The platform binding sets `PARVI_AUDIO_ENGINE` to `libwebrtc` or `gstreamer`.
Only these locally installed identifiers select Erlang modules. Unset retains
libwebrtc compatibility with previously built iPhone hosts; unknown identifiers
fail explicitly. `PARVI_WEBRTC_AUDIO_PORT` retains its existing name/protocol.

An engine is selected when the native endpoint is prepared and stored in the
session handle. Later configuration changes do not switch an open session.
Selecting an adapter requires the matching native service to be started by its
platform binding: the environment setting does not install or load a different
native library into an existing app. No remote descriptor can name an Erlang
module. Live engine switching and general plugin discovery remain deferred.

## Behaviour callbacks

| Callback | Contract |
| --- | --- |
| `info/0` | Identity, supported wire format/rate/channels and execution/measurement capabilities of this binding. |
| `available/0` | Whether the local native service endpoint is configured; connection/readiness is established separately. |
| `open/1` | Prepare a native receiver with authorized ICE configuration; return a session-owned opaque handle or an error. |
| `command/2` | Execute an explicit command against that handle. |
| `event/2` | Convert owned native transport events into common session events; ignore unrelated messages or return an endpoint error. |
| `close/1` | Release the owned endpoint. Native connection teardown releases its media/device resources. |

Both existing receivers accept 48 kHz stereo Opus. The wire handler validates
that source descriptor before opening the receiver. `info/0` is a factual local
capability description, not general format negotiation or proof of recovery.
GStreamer's `loss_concealment=configured` records opusdec's PLC setting; its
actual loss-event/recovery behavior still needs device evidence.

`parvi_audio_receiver:control_output/1` dispatches through the selected stream
handler's `output_control/2`. Existing app/inspector APIs, including
`minimum_playout_delay/1`, keep their entry points. The legacy PCM handler returns
`unsupported_output_control` for these new native controls; its existing
per-buffer scheduling is preserved.

## Commands and acknowledgements

Preparation, play/pause, SDP answer/candidate, stats requests and native-clock
observation retain their existing local JSON messages. No audio bodies are added
to the control path. Existing `playing`, `paused`, `connected`, delay reply,
stats, clock and error events retain their meaning. Endpoint connection means
media is ready; it does not establish physical speaker timing.

Minimum delay is asynchronous and request-correlated. The session owns its
existing timeout. On libwebrtc the acknowledgement's `guarantee` is
`minimum_only`; on GStreamer it is `jitter_buffer_latency`, reflecting the actual
webrtcbin latency property. Neither guarantees an exact output deadline.

Two additional explicit output operations establish the scheduling boundary:

- `{presentation, Map}` identifies `stream_id`, `revision`, `clock_timeline`,
  `sample_position`, `sample_rate`, `target_output_time_ns`,
  `local_handoff_time_ns` and `calibrated_output_latency_ns`.
- `{rate_correction, Map}` identifies `stream_id`, `revision`, `clock_timeline`,
  requested `correction_ppm` and its Erlang-approved `max_absolute_ppm` bound.

Erlang supplies a speaker target in the shared time reference and an earlier
handoff in the receiver's local monotonic reference. Use the existing
`parvi_audio_presentation:output_deadline/2` to map the shared target minus
calibrated path delay. Source position denotes the first source sample governed
by the schedule; a new stream/clock timeline or revision invalidates an obsolete
association. A correction revision belongs to that same schedule. The ppm bound
is nonnegative, and a native implementation must reject out-of-bound corrections
or stale/unmappable schedules rather than reinterpret them as buffering requests.
Positive correction means consume source samples faster per local elapsed time.

The iPhone host opts in with local `PARVI_GSTREAMER_SCHEDULE=1`; only that
GStreamer execution path advertises scheduling support. Rate correction remains
an interface operation but is unsupported on this path. Native observations and
plans are exchanged per packet as specified above. `reject_packet` explicitly
rejects an identified pending packet; invalidation mutes pending a fresh plan.

The current trial targets the nominal packet/decoder timeline at the GStreamer
sink clock boundary. `calibrated_output_latency_ns=null` explicitly denotes an
uncalibrated path; it is not an assumed zero speaker delay. Output remains muted
until a future plan is accepted, and packet/segment association loss invalidates
it. The public UI keeps cluster synchronization unverified. Automatic iOS jitter
latency is 100 ms; other backends retain their existing defaults. Unsupported
platforms reject schedule/rate commands before sending native bytes.

## Common output report

Existing native statistics and timing fields are retained. Receiver statistics
add `output_engine` and `output_status`; session status also includes `engine`.
The output report preserves a `source_anchor` with the source's sample position,
capture segment, RTP association and presentation stream/revision. It explicitly
reports `source_output_mapping=unavailable` without a valid applied plan. The
scheduled iPhone path reports `packet_global_target`; this is a decoder-buffer
association, not a physical output callback or calibrated speaker sample.

The report separately exposes callback host/sample observations, their existing
`output_timing_status`, reported route latency, dropped buffers, packet loss and
concealed samples when supplied. Missing calibrated path latency, queue depth,
underruns and counters remain `null`. Raw callback coordinates are observations;
consult validity/status and do not treat them as calibrated speaker times.
The render sample rate is the configured stream format, not a measured DAC
oscillator rate. No sample identity is inferred through NetEq stretching/concealment or GStreamer
buffering. Scheduling is advertised only for the implemented per-packet executor;
rate control remains false.

Stage 3 must preserve exact source/output identity through decode and retained
buffers, report timing/validity at the selected execution boundary, execute the
Erlang deadline, without silently replacing packet targets. Calibration must be
accounted for once. A GStreamer library feature alone does not prove that the
current Windows pipeline executes this contract.

## Validation and limits

The focused `parvi_audio_engine_tests` exercise both real Erlang adapters against
an isolated loopback native-protocol endpoint: command encoding, repeated
active-once events, endpoint closure, session pinning, rejected scheduling/rate
commands sending no bytes, unknown selection and unavailable services, and
source-anchor/output-report separation. They do not run native media engines or
physical devices. Run with the existing timing regressions:

```sh
rebar3 eunit --module=parvi_audio_engine_tests,parvi_webrtc_audio_timing_tests
```

Socket tests need local loopback permission. Root Erlang compilation, the Windows
packaging source set and unsigned iPhone compilation pass. No new app has been
installed, and device playback after this refactor is not yet verified. The user
confirmed the preceding Mac/iPhone baseline before these source changes.
