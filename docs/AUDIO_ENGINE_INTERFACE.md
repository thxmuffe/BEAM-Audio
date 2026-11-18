# Audio Engine interface

## Native stream decision — 2026-11-18

**Use GStreamer for the first complete native stream implementation.** Keep OTP
responsible for authorization, supervision and Session timing policy. GStreamer
owns capture through transport to playback, including encoded packets. This is
a backend selection and control contract, not an enabled backend or a completed
native revocation implementation. The current runtime remains unchanged.

### Why this backend

| Candidate | Existing evidence | Decision |
| --- | --- | --- |
| GStreamer | Native WebRTC sender/receiver scheduling experiment; iOS and Windows receiver bindings; RTP/RTCP, queue and resampling components | First implementation: exposes the media timeline and pipeline lifecycle without writing an audio engine. |
| libwebrtc/NetEq | iOS receiver and custom audio-device binding; loss concealment and callback observations | Retain as an experiment. Its present binding cannot execute the Session schedule or explicit rate correction; NetEq normally chooses an adaptive playout delay. |
| Current PCM and Opus paths | Working platform adapters and some user-confirmed playback | Migration reference only: both still carry audio through Erlang. |

The earlier tone comparison does not establish a general quality winner. Select
GStreamer for control of timing and lifecycle, not that metric. Reuse its existing
`webrtcbin` connectivity/security components where suitable; selecting a backend
does not authorize replacing authenticated media with plain UDP. The wire profile
and source-format negotiation still need integration. Do not silently quantize
float capture or force all sources through the prototype's 48-kHz stereo Opus
format. No new backend fallback, plugin registry or OTP application is needed.

Sources inspected:

- [Native receiver binding](../src/Audio/src/ba_audio_native_engine.erl): opens a
  loopback JSON socket but refuses the current profile with
  `native_revocation_protocol_required`; `close/1` only closes the socket.
- [iOS GStreamer receiver](../src/Audio/adapters/iOS/IOSGStreamerReceiver.m):
  `close` queues teardown on the media context and returns before it completes.
- [Windows receiver](../src/Audio/adapters/Windows/webrtc_output.py): socket EOF
  queues teardown and owning-port EOF queues loop exit on GLib. A stalled media
  loop can delay both; neither provides an independent forced-stop mechanism.
- [Experiments and validation limits](../src/Audio/experiments/gstreamer/README.md):
  a native sender/receiver exists in the isolated proof. Current production
  `ba_media_session` still uses ExWebRTC and carries media in Erlang. The receiver
  engine abstraction has no production session caller in this checkout.

### OTP ownership is mandatory

A native stream must never become an autonomous connection. Its lifetime is
bounded by its local OTP Media Session, the owning audio/runtime supervisors,
the Device consent authority and permission registry. Losing any required owner
invalidates that stream generation and triggers teardown, even after an
untrappable Erlang `kill`. Saved subscription/playback intent may survive; native
sockets, queued audio and old execution handles must not survive with it.

Use the existing supervised Media Session to own the control endpoint directly.
Use OTP links for parent/child lifetime and monitors for other required local
owners. Register the executor with `ba_device_permission:enter/1` before accepting
work, then validate the returned permission generation. Do not add a registry or
a forwarding process. Restart creates a fresh stream generation and checks
current consent and Session authorization; an old native handle cannot reattach.

There are two different stop paths:

1. **Requested stop/revocation:** publish denial first, stop and flush native
   work, close all media transports, release capture/output resources, then send
   a correlated stop acknowledgement. Only that completion or confirmed helper
   process exit satisfies the stop barrier. Pause/mute is not a stop.
2. **Owner/supervisor/runtime loss:** closing the owned port or socket must
   independently trigger native teardown. This cannot depend on `terminate/2`,
   the next audio callback, receipt of another media packet, remote cooperation
   or servicing the normal media event loop. A native lifetime guard enforces
   a bounded cleanup deadline and forces termination if cleanup stalls.

On desktop platforms prefer a non-daemonizing native helper owned through an
Erlang port. The native guard observes control-channel loss independently of the
GStreamer loop, disables new work and stops the pipeline. If teardown hangs,
terminate the helper process so the OS releases its sockets and devices. Media
resources stay in that process; do not spawn detached media descendants. Port
closure alone is not proof the helper exited. Normal-stop escalation can reuse
`ba_native_stop`'s existing 1.5-second deadline, but owner-loss escalation must
also work when no Erlang process remains to call that module.

On iOS the native backend lives in the app process. The same independent native
guard must stop the stream after its owning control socket closes. If teardown
cannot complete, the enforcement boundary is the host process itself; a stalled
engine cannot be allowed to keep running merely to preserve the UI. The exact
guard integration and hard-termination path must be implemented and checked
before enabling this backend. This is not currently guaranteed by the app.

The initial cleanup bound is 1.5 seconds after owner loss is detected, independent
of the requested audio buffer. Teardown starts immediately and discards queued
audio rather than draining up to ten seconds. This is a bounded software-stop
requirement, not zero-time crash detection or an acoustic-silence claim: OS
scheduling and already-submitted device audio must be measured separately.
Control closure is an enforcement trigger, never a stop acknowledgement.

### Replacement control contract

This section specifies the replacement; these operations are **not yet the
implemented wire protocol**. Reuse the existing packet-4 JSON control framing,
with a version/capability handshake before creating media resources. Payloads
are limited to control, signalling, timing and bounded diagnostic summaries.
Native sender and receiver use the same lifetime rules.

Every command/reply belongs to one stream generation. Operations needing
completion also carry a request ID. The native endpoint serializes commands,
rejects stale generations and closes permanently after stop. Decimal strings
carry nanosecond times and sample positions that could exceed JSON's exact
integer range in a host language. A new connection never inherits an old stream.

| Operation | Required completion/meaning |
| --- | --- |
| Handshake | Protocol version, actual backend capabilities and enforced lifecycle/deadline support; no media allocation. Unsupported lifecycle fails before prepare. |
| Prepare | Authorized source/receiver configuration, source format, ICE/signalling configuration and new generation; reports prepared. Acquired resources are already under the native lifetime guard. |
| Signal | SDP/ICE only; the native library owns all media sockets and packets. |
| Clock mapping | Session timeline/revision, shared-time and local-monotonic correspondence, uncertainty and validity; native code consumes the mapping without per-packet Erlang calls. |
| Presentation | Source sample position/rate mapped to shared Session time, Response time and approved correction limits. Initial mapping precedes scheduled playback; revisions identify their effective sample position. |
| Buffer policy | Requested duration from 0 through 10,000 ms and explicit native resource limits; replies with accepted values or an error, never silently clamps an unsupported request. |
| Start / pause | Reports the actual state; pause remains owned and authorized and does not count as revocation or teardown. Start requires a valid schedule and grants. |
| Rate correction | Revision and effective sample position, requested ppm and approved bound; native resampling follows Session policy. Unsupported control is an error. |
| Stop | Terminal and idempotent for this generation. Acknowledged only after pipeline teardown, queue flush, media socket closure and device-resource release. No EOS drain. |
| Status | Actual lifecycle state, schedule validity, queued duration/bytes, transport stage and bounded counters/errors; missing measurements stay unavailable. |

Failure to send/receive commands, malformed control or lost required ownership
stops the stream; stale commands cannot restart it. Permission/authorization
freshness is checked by the OTP owner independently of media traffic. If an
owner can remain alive but stop servicing control, the native guard also needs a
bounded control-liveness deadline, renewed only after those checks. This deadline
is separate from media buffering and cannot be refreshed by an audio thread.
Its cadence must be qualified under realistic OS stalls before claiming support.
It supplements channel-loss handling; it cannot replace mandatory teardown on EOF.

### Buffering and timing

Buffer duration varies with demand under Session policy, **up to ten seconds**;
ten seconds is a maximum supported horizon, not a default wait or fixed prefill.
Keep requested Response time, capacity and actual queue occupancy distinct.
Budget all native stages together in time/frames and bytes, including jitter,
decode, render and retransmission history as applicable; do not accidentally
allocate ten seconds at every stage. Format-specific memory overhead and a
bounded extra packet must be accounted for explicitly. Existing manual Session
Response times are not silently changed or clamped by this design document.

GStreamer queues stop at whichever configured limit is reached first. Their
default 200-buffer/one-second limits cannot simply be retained while claiming
ten-second support. Configure time, count and byte limits consistently for the
negotiated format. Native reordering/recovery consumes the existing presentation
budget; it does not choose a new playout timeline. Changing capacity must not
retime samples already assigned to the Session schedule. Smooth continuous rate
correction replaces dropping entire blocks for tiny same-source overlaps.

### Implementation order and acceptance

The backend decision and contract above are recorded. **Step 1 implementation
is still open:** implement the lifecycle handshake, native guard, correlated
stop completion and OTP permission/owner monitoring before removing the existing
profile rejection. Prove lifetime behavior first with a disposable native
endpoint; then connect GStreamer resources to that same boundary. A protocol
mock alone cannot qualify the actual pipeline or iOS host.

Critical checks are normal stop, consent revocation, owner `kill`, parent
supervisor `kill`, permission-authority/registry loss, BEAM exit, blocked media
loop during teardown, stale commands after stop, and a fresh authorized restart.
Check released OS sockets/helper exit and flushed queues, not just an Erlang
`DOWN` or a quiet meter. Scope crash checks to disposable processes, never the
user's running Devices. Only after these pass should step 2 connect real capture
and playback; device listening and physical synchronization are later evidence.

Primary references:

- [OTP port ownership](https://www.erlang.org/doc/system/ports.html): owner
  termination closes the port; the external program must implement its own exit.
- [GStreamer RTP/RTCP](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpbin.html):
  media/reference clock mapping, jitter buffering and recovery integration.
- [GStreamer queues](https://gstreamer.freedesktop.org/documentation/coreelements/queue.html):
  independently configured time, buffer-count and byte limits.
- [GStreamer state changes](https://gstreamer.freedesktop.org/documentation/gstreamer/gstelement.html):
  `NULL` teardown is distinct from pause and EOS draining.
- [NetEq](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md):
  its ordinary adaptive playout and time stretching explain the present mismatch.

## Legacy receiver interface (reference only)

The remainder documents earlier implementation/prototype behavior. The native
stream contract above supersedes its per-packet target requirement, receiver-only
boundary and assumptions that endpoint closure confirms teardown. Do not extend
the old packet-by-packet Erlang scheduling path for the native migration.

### Authoritative per-packet target

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
rejected. Configured Playback Offset is at most 30 seconds. This conversion
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

`ba_stream_handler` remains the wire-format boundary, including the
legacy PCM/data-channel implementation. `ba_audio_engine` is the new native
receiver execution behaviour. Both current engines implement the same WebRTC/
Opus wire profile, so the sender, cluster transport and UI can stay unchanged
when the receiver's native implementation changes. An uncompressed RTP backend
would also need its corresponding wire handler and connectivity/security work.

The existing `ba_webrtc_audio_session` gen_statem owns the engine handle and
socket. It calls the engine callbacks directly. The audio supervisor still owns
session lifetime; source/peer/consumer monitoring and SDP/ICE routing remain in
Erlang. There is no additional forwarding process, registry or OTP application.
This follows the standard [OTP behaviour/worker separation](https://www.erlang.org/doc/system/design_principles.html).



## Implementations and selection

- `ba_audio_engine_libwebrtc`: current iPhone libwebrtc/NetEq and signed
  16-bit RemoteIO output binding.
- `ba_audio_engine_gstreamer`: current Windows webrtcbin/Opus and float32
  WASAPI output binding.
- `ba_audio_native_engine`: their shared packet-4 JSON socket binding. Native
  Swift/Python implementations remain in their platform adapter directories.

The platform binding sets `BA_AUDIO_ENGINE` to `libwebrtc` or `gstreamer`.
Only these locally installed identifiers select Erlang modules. Unset retains
libwebrtc compatibility with previously built iPhone hosts; unknown identifiers
fail explicitly. `BA_WEBRTC_AUDIO_PORT` retains its existing name/protocol.

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

`ba_audio_receiver:control_output/1` dispatches through the selected stream
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
`ba_audio_presentation:output_deadline/2` to map the shared target minus
calibrated path delay. Source position denotes the first source sample governed
by the schedule; a new stream/clock timeline or revision invalidates an obsolete
association. A correction revision belongs to that same schedule. The ppm bound
is nonnegative, and a native implementation must reject out-of-bound corrections
or stale/unmappable schedules rather than reinterpret them as buffering requests.
Positive correction means consume source samples faster per local elapsed time.

The iPhone host opts in with local `BA_GSTREAMER_SCHEDULE=1`; only that
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
