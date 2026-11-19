# Audio Engine interface

## Native stream decision — 2026-11-18

**Use GStreamer for the first complete native stream implementation.** Keep OTP
responsible for authorization, supervision and Session timing policy. GStreamer
owns capture through transport to playback, including encoded packets. The
default path remains legacy. A development-only native AAC implementation now
follows part of this contract; see [usage and limits](../src/Audio/README.md#native-aac-development-trial).
It is not a synchronized or device-qualified replacement yet.

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
still needs broader format negotiation. The owner approved AAC-LC at 320 kb/s
stereo for music on 2026-11-19. The first profile accepts 44.1/48-kHz stereo float
capture, explicitly converting to the Apple GStreamer encoder's 16-bit input;
Its result is lossy AAC, not preserved float samples. Other formats are rejected.
No new backend fallback, plugin registry or OTP application is needed.

Implementation boundary after the first cleanup pass (2026-11-19):

- `ba_native_media_session` owns the complete native stream control socket;
  `ba_audio_native_clock` translates Session timing policy into native calibration.
- `GStreamerStreamHost` implements the native pipeline and independent lifetime
  guard. iOS static-plugin setup lives separately in `IOSGStreamerRuntime`.
- The earlier receiver-only engine selector, unstarted iOS receiver hosts and
  unused Windows launcher were removed. The libwebrtc comparison remains under
  `src/Audio/experiments/gstreamer/`, outside app packaging.
- The ordinary PCM path and opt-in Erlang/Opus handler are still implemented.
  They are migration references and remain distinct from the native AAC trial.

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
engine cannot be allowed to keep running merely to preserve the UI. The new native AAC host implements this guard and forced-exit path; the iOS
source passes syntax checks, but actual iPhone lifecycle behavior remains
unverified. It is enabled only by an explicit development-trial flag.

The initial cleanup bound is 1.5 seconds after owner loss is detected, independent
of the requested audio buffer. Teardown starts immediately and discards queued
audio rather than draining up to ten seconds. This is a bounded software-stop
requirement, not zero-time crash detection or an acoustic-silence claim: OS
scheduling and already-submitted device audio must be measured separately.
Control closure is an enforcement trigger, never a stop acknowledgement.

### Replacement control contract

This section specifies the complete replacement contract. The AAC trial implements
hello/prepare/signalling, heartbeats, play/pause, gain, stats, confirmed stop,
initial/periodic clock mapping and native scheduled presentation. Clock-rate
correction is bounded and phase-preserving; continuous hardware playback,
effective-sample revisions and changing buffer policy remain unqualified or
unimplemented. The trial uses packet-4 JSON control framing with a
version/capability handshake before creating media resources. Payloads
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

The new `ba_native_media_session` owns its native control socket directly and
registers with the existing permission machinery. The Mac source owns its helper
port. Both monitor required owners; the native host enforces closure and a
separate control-liveness deadline. Requested stop acknowledges only after
pipeline teardown; a stalled media context forces helper/host exit. The earlier
receiver-only adapters have been removed; unsupported native
profiles cannot silently substitute another backend.

The AAC trial reports `synchronized=false` and requires explicit
`BA_NATIVE_STREAM_TRIAL=1` locally. Its `gst_aac_rtp_v2` profile requires a native
clock mapping before prepare. OTP supplies Session policy and refreshes the
mapping every five seconds; native RTP/RTCP reconstructs capture time and output
adds Session Response time. Mapping expiry ends media after twelve seconds even
with live heartbeats. A changed timeline or Response-policy revision ends/recreates
the stream rather than changing queued targets. Status exposes local control
RTT, not a global uncertainty bound. Synthetic tests verify prompt RTCP mapping,
software scheduling, decode, normal stop and independent guards. The iPhone
host has source/bridge checks, not a deployed or listening result. See
[current validation](PROGRESS.md#native-session-clock-scheduling--2026-11-19).

Implementation references: GStreamer's [RTP/RTCP synchronization and reference
timestamp metadata](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpbin.html),
[sender-report requests](https://gstreamer.freedesktop.org/documentation/rtpmanager/RTPSession.html)
and [clock calibration](https://gstreamer.freedesktop.org/documentation/gstreamer/gstclock.html).

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

## Retained legacy media paths

The default PCM/data-channel path and the opt-in Opus handler still carry media
through Erlang and use the existing Mixer/output bindings. They remain until the
native replacement has real-device acceptance; this cleanup does not switch the
default or remove the path currently used by the apps. See
[src/Audio/README.md](../src/Audio/README.md#legacy-implementation).

The unused receiver-only `ba_audio_engine` selector and its libwebrtc/GStreamer
adapters were removed in the first cleanup pass. Their packet-by-packet native
scheduling API is not a supported compatibility contract. Historical details and
measurements remain in Git and PROGRESS.md; the replacement contract above is
the current design. The isolated comparison/scheduling experiments are retained
for explicit research, not included as alternative app backends.
