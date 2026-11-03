# Audio runtime and platform adapters

See [audio/stream/subscription draft 0.1](../../docs/AUDIO_STREAM_CONTRACT.md)
for the shared semantic boundary and its first PCM/WebRTC binding. It is not
an interoperability or synchronized-playback claim.

## Plan A: WebRTC Opus audio

`handlers/webrtc/` implements the selected audio handler, `webrtc_audio_opus`.
Mac uses libopus for capture encoding and ExWebRTC for RTP; iOS uses native
libwebrtc for NetEq/decoding with an output-only RemoteIO binding. BEAM owns
signaling and supervised session lifecycle. Windows output now uses GStreamer
webrtcbin/Opus/WASAPI in `adapters/Windows/webrtc_output.py`; iPhone retains
libwebrtc/NetEq. Both currently use local playback timing rather than executing
the shared presentation schedule. See the
[November 3 playback review](../../docs/AUDIO_PLAYBACK_REVIEW_2026-11-03.md)
for current findings and validation limits. Older GStreamer-deferral statements
below refer to the separate native RTP experiment and earlier implementation state.

The current Mac switch is labelled “Opus / NetEq comparison”; select it before
broadcasting, subscribe on iPhone and tap Play. The label comes from the initial
bring-up; an A/B comparison is not required. Opus is lossy (48 kHz stereo,
20 ms packets, 192 kb/s VBR target). Native adaptive playback is **not yet cluster
synchronized**. Foreground Mac-to-iPhone music playback is user-confirmed. Reported jitter was
about 4 ms; perceived delay was estimated at 100–200 ms, not instrumentally measured.

Timing feedback uses the existing bounded statistics channel (once per second).
Erlang derives session-mean jitter-buffer delay as `1000 * jitterBufferDelay /
jitterBufferEmittedCount` when samples have been emitted; no value is invented
before that. See the [W3C statistics definition](https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-jitterbufferdelay).
iOS reports [output latency](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputlatency)
and the actual [I/O cycle duration](https://developer.apple.com/documentation/avfaudio/avaudiosession/iobufferduration)
from AVAudioSession. These do not measure complete capture-to-speaker delay,
current buffer depth or physical alignment, and are not summed into a total.
The iPhone UI now prefers a recent interval mean calculated in Erlang as
`1000 * delta(jitterBufferDelay) / delta(jitterBufferEmittedCount)` when samples
were emitted and counters did not reset. The session mean remains in snapshots;
new subscriptions clear old native statistics. No timing correction is applied
by this reporting step.

Capture/RTP timeline observation adds local helper packet 8 (the original capture
host ticks, source sample position, dropped callbacks, flags, buffer count and
input frame count, plus the encoded-output position before conversion) and a 20-byte timing prefix on packet 6 (encoded 48 kHz sample
index, Opus lookahead, converter leading/trailing input frames). The prefix never
enters RTP: only the Opus payload is sent. The helper and bundled Erlang adapter
must be rebuilt together. Real-time capture callbacks are unchanged.

`parvi_webrtc_audio_timing` interprets observations in Erlang. Host/BEAM midpoint
calibration retains its measured round trip; encoded positions use a nominal
48 kHz mapping within each capture segment. Discontinuous positions, changed
drop counts or invalid timestamps invalidate the estimate without resetting RTP.
The next valid segment anchors current host time to the encoder's separate
output position; a subsequent consistent observation permits estimates again.
Packets spanning its nominal output boundary and track observations preceding
that boundary remain unavailable. This recovery is compiled, not yet verified
on devices. Converter state/audio are not reset or repaired by this metadata. The mapping does
not yet compensate converter priming, Opus lookahead or measured oscillator drift.
[Opus lookahead](https://www.opus-codec.org/docs/opus_api-1.5/group__opus__encoderctls.html)
is queried from the encoder rather than hard-coded.

Receivers request `timing_observations` when subscribing. Providers then send
capture/RTP anchors once per second, plus segment/continuity changes, over BEAM signaling. iOS reads the
public SSRC track-delivery timestamp and RTP timestamp, and reports its host clock
for a local midpoint mapping. The upstream [Apple WebRTC clock implementation](https://webrtc.googlesource.com/src/+/main/rtc_base/system_time.cc)
uses Mach absolute time; observations outside its plausible ten-second source
window are not correlated. The derived nominal capture-to-track time is not
speaker/DAC time. It must not drive group correction until actual sample output
timing/control and codec/converter delay are integrated. NetEq playback policy
and the cluster master remain unchanged in this observation-only step.

The upstream [C++ receiver interface](https://webrtc.googlesource.com/src/+/refs/heads/main/api/rtp_receiver_interface.h)
has `SetJitterBufferMinimumDelay`, which sets a minimum and does not guarantee
exact playout time. `WebRTCReceiverControl.mm` now binds it through the framework's
internal `nativeRtpReceiver` accessor, compiled against the exact release source
revision (M156 `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d`). This is a version-coupled
library interface: update binary and headers together. No dependency source is
patched and no copied class/vtable layout is used.

`parvi_audio_receiver:minimum_playout_delay(Milliseconds)` accepts integers
0–10000, or `automatic` to restore NetEq defaults, for an active native subscription.
The local JSON command is `set_audio_minimum_playout_delay` with string `delay_ms`
(e.g. `"200"` or `"automatic"`). The supervised session waits for a matching native
acknowledgement with a two-second named timeout. A success reports
`guarantee=minimum_only`; it does not report an exact achieved buffer depth.
Initial buffering stays automatic. Readiness and requested delay appear in the
existing bounded statistics stream. An actual output-time measurement and
calibrated timing are still needed before group correction; nominal track latency
alone is insufficient.

Preparation downloads only source-header archives, pins a sorted SHA-256 manifest
of each extracted name/content set (archive timestamps are not stable), and
checks decoded private-header/notice hashes. Generated files remain in `builds/`.
Abseil's notice and WebRTC's patent grant accompany the iOS runtime resources.

`handlers/webrtc/prepare.py` pins libopus 1.5.2 from downloads.xiph.org and the
stasel WebRTC M156 XCFramework release, checking SHA-256 before extraction.
Apple build preparation includes their license notices. This prototype has not
completed a redistribution/release review or network-impairment measurement.

## Stream-handler boundary — 2026-11-02

GStreamer integration is deferred. `parvi_audio_stream_handler` is the behaviour;
`default/0` selects the legacy implementation,
`parvi_audio_stream_handler_legacy`. Existing OTP capture/publication/subscription/
receiver workers select a handler from the source descriptor. No registry or forwarding process is added.

The legacy adapter, custom packet codec and playback worker are isolated in
`handlers/legacy/`. Shared control code delegates descriptor/packet operations
to the handler and retains lifecycle, readiness, monitors and cleanup. The
publication validates blocks without constructing a throwaway full packet;
selected packets are encoded for sending inside the handler. The wire layout,
format preservation, WebRTC channel settings and deadlines are unchanged.

`parvi_audio:handler/0` reports actual handler facts. `backend/0` and snapshot
`backend` keys remain compatible with the current Apple clients. The identity is
still `legacy_webrtc`, with `data_path=erlang_pcm`, unordered data channels,
zero retransmissions, no jitter/reorder buffer, no loss concealment and no
sample-clock correction. Those are limitations, not capabilities inherited from
native WebRTC's audio engine.

Common callbacks cover information, descriptor validation, binding/close and
output lifecycle. Optional per-buffer callbacks implement the installed legacy
PCM path. A native replacement must add its actual control/handoff and feedback
operations; merely implementing this legacy behaviour does not provide native
payload bypass. See [decision 0008](../../docs/decisions/0008-replaceable-audio-stream-handlers.md)
for the boundary, current limits and next selection step. We will use established
jitter/recovery machinery rather than writing more audio algorithms here.

Erlang owns the master reference, local presentation decisions and correction
policy; native media code may execute approved timing/processing and report
device feedback. The backend extraction itself did not change clock policy. See
[decision 0006](../../docs/decisions/0006-audio-backend-boundary-and-clock-ownership.md)
for the earlier ownership/packaging decision. GStreamer remains deferred and
is not integrated. This refactor is not a new device-playback validation.
The isolated [fixed L16 desktop experiment](experiments/gstreamer/README.md)
provides a fixture, native RTP sender, raw recorder, device receiver and finite
measurement runner. Mac playback now uses a standard bounded queue to separate
blocking device writes from jitter-buffer delivery; the repeated device run
delivered all frames without reported drops. Simulated reordering preserved
samples, while loss/excessive delay left visible unrecovered gaps. These are
local experiment results. They do not change backend selection, the app capture
path or Erlang clock policy; real LAN and synchronization evidence remain pending.

The subsequent [clock revision](../../docs/decisions/0007-cluster-clock-pulls-and-monotonic-mapping.md)
adds asynchronous discovery/pulls and a slewing mapping. Capture now calls
`parvi_clock:map_times/1` for capture/expiry times from one snapshot; output uses
its deadline inverse. A usable holdover mapping remains available to the legacy
prototype, with quality/coverage reported separately. This does not implement
DAC resampling or prove synchronized speakers. Updated device playback with
these changes remains unverified.

The source boundary is:

```text
src/Audio/
  src/                 shared Erlang control, clock policy, sources and subscriptions
  handlers/legacy/     current WebRTC adapter, packet codec and output worker
  adapters/macOS/      Core Audio Erlang binding and native audio_input.mm
  adapters/Windows/    WASAPI Erlang binding and native audio_input.cpp
  adapters/iOS/        local Erlang output/clock binding and Swift AVAudio binding
```

`src/` has no platform-adapter dependencies. `parvi_audio_input` owns publication
lifetime, metering, presentation delay/expiry policy, packet splitting and delivery
counters. It is an ordinary Erlang state module called from the adapter's existing
OTP worker, with no additional process, queue, driver registry or native engine.

The input boundary is interleaved PCM plus a descriptor (`encoding`,
`sample_format`, `sample_rate`, `channel_count`) and the first frame's capture time
in this VM's Erlang monotonic nanoseconds. Source formats remain heterogeneous;
this boundary does not impose a common rate, precision or channel count.
`parvi_audio_input:open(Name, Descriptor)` publishes under the calling worker's
ownership and adds the shared clock ID. `captured(PCM, CaptureMonoNs, State)`
returns updated state; `status/1`, `stop/1`, `failed/2` and `close/1` provide shared
reporting/lifetime behavior. These functions run in the adapter owner, which
retains the returned context and forwards its source-monitor DOWN event.

Platform adapters own helper/port lifetime, OS format/flag interpretation, raw
buffer packing and translation from hardware timestamps into local monotonic
time. `parvi_mac_audio` and `parvi_core_audio` now live with their native helper
under `adapters/macOS/`. The adapter hands normalized PCM/time to the shared input
policy; it no longer owns presentation delay, expiry, metering or network packet
sizes. Source names and platform diagnostics stay at the adapter boundary.

The Windows adapter and native helper moved together under `adapters/Windows/`
without behavior changes. Its existing local meter still uses the shared
`parvi_audio_meter`; it has not been connected to publication/network delivery.
The reorganization does not silently add broadcasting to the legacy Windows app.

The shared `src/control/rebar.config` compiles portable sources and platform adapter
folders into the existing `parvi` application; Windows packaging uses the same
source directories. Native builds select only their platform's helper. No extra
OTP application or service was introduced. See the [Windows guide](../Apps/Windows/README.md),
[Mac broadcast guide](../Apps/macOS/README.md#broadcast-default-output), and
[binding decision](../../docs/decisions/0004-windows-audio-library-trial.md).
Real Mac capture, physical iPhone receive metering and audible iPhone playback
are verified (playback by user observation). Timing/alignment remain unmeasured.
Android remains future work.

## Subscription control — step 1

`parvi_audio` exposes source offers and subscription lifecycle control using
`pg` discovery, a `gen_server` per publication and `gen_statem` endpoints under
a dynamic `one_for_one` supervisor. The audio supervisor starts on demand as the
last child of `parvi_sup`; merely starting an app does not start capture or
advertise audio. Existing startup profiles, app UIs and Windows capture are unchanged.

The API requires Parvi to be running. On a fresh VM, `parvi:start(native_cluster)`
starts the core without the desk unless explicitly configured. Native peer
connections expose remote source PIDs through `pg`; the legacy WebSocket relay
does not distribute process-group membership.

## Audio streams — step 2

Offers now require an implemented descriptor. For example, on the producer node:

```erlang
{ok, Source} = parvi_audio:publish(#{
    name => <<"Mock system output">>, mock => true,
    profiles => #{channel => #{encoding => pcm, sample_format => float32_le,
        sample_rate => 48000, channel_count => 2, clock => <<"mock-clock">>}}}).
```

On an already connected native peer, from a local consumer/runtime process
(the example assumes one remote publication):

```erlang
[Source] = [P || P <- parvi_audio:sources(), node(P) =/= node()].
parvi_audio:describe(Source).
{ok, Subscription, Descriptor} = parvi_audio:subscribe(Source,
    #{profile => channel, selector => all}).
ok = parvi_audio:listen(Subscription, self()).
ok = parvi_audio:ready(Subscription).
parvi_audio:status(Subscription). % state = active, media = open; received may be 0
```

Call `ready/1` within five seconds of acceptance. It now registers the receiver's
media context, requests provider readiness and waits for the real media channel
to open. Each unfinished state expires after five seconds. There must be an
existing authorized native WebRTC peer connection; a same-VM metadata subscription
can be accepted, but readiness returns `no_peer_connection` and closes it.
No new ICE connection or TCP/UDP protocol is created by a subscription.

The producer's local capture/runtime worker feeds blocks, for example explicit
mock stereo PCM (one frame, both samples zero):

```erlang
{ok, Results} = parvi_audio:push(Source, channel,
    #{playback_time => 1000000000, channel_id => 0}, <<0.0:32/little-float, 0.0:32/little-float>>).
```

`Results` contains `{ProviderPid, ok | filtered | {error, Reason}}` per current
provider. Not-yet-active providers return an error; no subscribers gives `[]`.
`ok` means locally enqueued, not acknowledged reception. The provider assigns
sequence numbers; callers supply time and the profile's selectors. The local
receiver consumer gets `{parvi_audio, Subscription, Header, PCM}`; Header includes
the decoded fields and derived `frame_count`. Without a consumer, reception is
counted and sample bodies are discarded. `listen/2` replaces the sole observer;
its death detaches it without ending the runtime-owned subscription. Consumers
must keep up with notifications; no consumer queue/pacing policy is supplied yet.

Supported descriptor fields/formats, byte layout, size limit and clock semantics
are specified in the [version 1 binding](../../docs/AUDIO_STREAM_CONTRACT.md#implemented-pcm-binding--version-1).
Each offer's `profiles` map may contain `channel` and/or `point`. Point descriptors
also require a binary `coordinate_frame`; push headers require X/Y/Z in metres.
Descriptors are immutable and unsupported encodings are rejected. There is no
resampling, bit-depth conversion, arbitrary clock-domain conversion or playback.
The separate [application clock](../control/README.md#independent-application-clock)
provides UTC/POSIX-to-local-monotonic conversions for descriptors using its clock
ID; mock-clock timestamps have no automatic mapping.

Requests require `profile` and `selector`. Selectors are `all`,
`#{channels => [0, 1]}` for logical channel-bundle IDs, or
`#{x => 0, y => 0, z => 0, radius => 1.4}` for point audio. All includes every
block in the selected profile. Channel selectors keep whole bundles, including
all interleaved sample channels declared by their descriptor. Sphere selectors
keep whole blocks whose point is within the inclusive radius. They use the
source's coordinate frame; there is no spatial renderer or interpolation.
`describe/1` supplies offered descriptors and fixed request requirements.

`close/1` ends a local endpoint; `unpublish/1` stops a source. Peer/source/carrier
monitors and actual media-channel closure clean up the relationship. The carrier
removes forwarding entries and closes media channels on owner DOWN, including
killed owners. Closing one media channel leaves native distribution intact.
Temporary children do not resurrect obsolete sessions/publications.

`sessions/0` lists local provider/receiver endpoints. `status/1` reports state,
role, source/peer, request/descriptor, sent/received counters, invalid packets,
last header and observed sequence gaps/reordering. Gaps are provisional when
late packets arrive; there is no reorder/jitter buffer. `watch_sources/0` uses
`pg:monitor/2`; stop it with `pg:demonitor(parvi_pg, Ref)`. Scope/runtime restart
ends publications and sessions; republishing/reconnection is not automatic.

Validation: warnings-as-errors compilation and a focused manual two-node WebRTC
check verified exact PCM bytes/timestamps/frame count, channel/point filtering,
media-close and source-down cleanup while native distribution stayed connected.
This used provisioned probe trust, not a Render invitation or native app run.
No new automated test cases were added. Sustained operation, overload behavior,
Mac capture, iPhone UI/meter, clock synchronization and playback are unverified.
The existing PC mailbox guard is not full SCTP/network backpressure.

The [current architecture discussion](../../docs/PLAN.md#audio-adapters-and-heterogeneous-streams--discussion-2026-10-31)
describes a shared Erlang audio-stream boundary with small platform adapters.
Streams may retain different source formats; a common description does not imply
a common sample rate or bit depth. Capture is for processing and IP delivery to
cluster receivers, with the meter as one consumer. The Mac process-tap input is
now implemented in source and awaits real capture validation. The [subscription lifecycle](../../docs/AUDIO_STREAM_CONTRACT.md#first-mac-to-iphone-subscription-lifecycle--researched-2026-11-01)
now also covers iPhone discovery, subscription and real packet reception, using
OTP supervision/monitors and a separate WebRTC media context. This supersedes
the earlier Mac-only scope; iPhone speaker rendering remains a separate step.

## Capture-owned publications

`parvi_audio:publish(Offer, OwnerPid)` optionally binds a publication to a local
runtime worker. The source monitors that owner and stops on DOWN, cleaning its
provider/receiver sessions through their existing dependencies. This is used by
the Mac capture worker, whose own source monitor also stops a capture that has
lost its publication. `publish/1` keeps the previous independent runtime-owned
lifetime. Owners are processes, never disposable views.

Mac buffer transfer uses a binary OTP port with four-byte big-endian message
lengths. Payload tag 1 carries ASBD fields and mach timebase; tag 2 carries host
ticks, sample position, cumulative callback drops, timestamp flags and raw buffer
planes; tag 3 carries OSStatus/context. An Erlang `r` credit yields tag 5 (current
host tick calibration), up to eight buffers, then tag 4 (drain complete). Native
integers/PCM use the Apple Silicon host's little-endian ABI. This is a local
binding protocol, separate from the network audio-packet format.

Capture preservation, clock mapping and the initial 250 ms presentation allowance
are documented in the Mac guide. A synthetic port-to-WebRTC check passed; native
permission, real capture and sustained performance remain unverified. No Mac app
build or hardware recording was performed for step 3.

## Runtime receive catalogue and meter

`parvi_audio_receiver:snapshot()` starts the receiver/catalogue on demand and
returns `#{offers => [...], receiver => Status}`. Offers contain opaque UI IDs,
source names/nodes and supported descriptor summaries. The worker watches pg
membership and asynchronously requests each remote source description once;
it excludes local publications. IDs are looked up in that catalogue, never
converted from user text into PIDs/atoms.

`parvi_audio_receiver:subscribe(Id, channel | point)` queues asynchronous setup
with the existing `all` selector and returns immediately; inspect the snapshot
for opening/activating/readiness or an error. `stop/0` closes it. One session is
active at a time. The endpoint explicitly monitors this runtime owner so a killed
catalogue/consumer cannot leave delivery running. Ordinary direct subscriptions
retain their previous ownership behavior.

The consumer calculates peak/RMS from decoded sample notifications, keeping only
summaries/counts. States distinguish waiting for first audio, recent packets
(including silence), no recent packets and closure. Swift receives summaries only;
there is no playback buffer, renderer or device output adapter. Real WebRTC
reception by this new UI/consumer remains unverified until app builds/device work;
focused checks used standard OTP control and synthetic packet notifications.

## Output boundary — first iPhone implementation

`parvi_audio_receiver:playback(start | stop)` controls one temporary supervised
`parvi_audio_output` process, owned by the receiver. Playback requires a channel
subscription. Its configured `parvi` environment `audio_output_adapter` supplies
`open(Descriptor)`, `write(Device, RenderMonoNs, Frames, PlanarFloat32)` and
`close(Device)`. The portable worker owns PCM conversion, deadline/order policy
and counters; its adapter owns local sockets, native-clock mapping and OS calls.
No native output is configured on Mac or Windows by this increment.

The iPhone adapter connects to an app-local loopback listener configured through
`PARVI_AUDIO_PORT`, separate from the existing JSON UI bridge. Records use a
32-bit big-endian body length. Configure is `1, rate:u32, channels:u16`, answered
by `1`. Clock request `3` returns `3, host_ns:u64, latency_ns:u64`. Buffer transfer
is `2, host_ns:u64, frames:u32, planar_float32_le_bytes`. These are private device
binding records, not new network-audio packets. Calibration occurs after engine
startup. Native queue/buffer scheduling is AVAudioPlayerNode; no custom real-time
render loop, playback DSP or NIF is introduced.

The output uses packet presentation time minus reported downstream latency,
rejects expired/out-of-order and over-one-second-future blocks, and silences by
closing the binding when ownership ends. The first binding supports mono/stereo
at 8–192 kHz. It has no jitter reordering, drift correction, mixing or acoustic
calibration; see the [iPhone usage/limits](../Apps/iOS/README.md#speaker-output-step-5).

## Inspecting an audible jump

Use the [inspector API](../Apps/Inspector/README.md) to compare `capture` on Mac,
`inspect` on the receiver and `clock` on each node. New source builds expose
capture segment and host residual, clock offset/slew/uncertainty, and optional
native `insertedSamplesForDeceleration`, `removedSamplesForAcceleration`,
`concealmentEvents`, `silentConcealedSamples`, `jitterBufferTargetDelay` and
`jitterBufferMinimumDelay`. Counters are cumulative; compare successive samples.
Their presence depends on the linked native library. Route latency is reported
separately. No counters prove causation without matching the audible event.

The current Opus playout is adaptive, not driven by cluster presentation times.
[NetEq](https://webrtc.googlesource.com/src/+/c8abb0469dfb1ea4c5a55a56e897bafebbfdaf8d/modules/audio_coding/neteq/g3doc/index.md)
can accelerate/decelerate to adjust buffer delay. The shared clock already slews;
this increment does not change either policy or implement quiet-passage cuts.

Focused timing checks (from the repository root):

```sh
cd src/control
rebar3 eunit --module=parvi_webrtc_audio_timing_tests,parvi_clock_mapping_tests
```

Seven recovery/timestamp checks plus three clock-mapping checks pass. They use a
deterministic clock mapping and validate segment boundaries, sample-position
mapping and stale-estimate removal; device/audio recovery still needs a matched
Mac/iPhone run.
