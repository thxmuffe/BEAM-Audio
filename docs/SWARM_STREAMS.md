# Independent Streams and Subscriptions — steps 6–8d

The headless `swarm_control` runtime now has a collection of independent PCM/Opus
subscriptions and one local scheduled mixer. The old single receive slot and
remote-PID discovery/subscription path have been replaced. Installed apps and the
platform audio outputs have not been migrated or launched.

## Identity and ownership

`ba_audio:publish/2` creates a local supervised publication with an explicit
stable `source_key` and fresh incarnation. Its local capture owner supplies every
packet's target. Source pause keeps that publication/incarnation and its idle
transports; unpublish or owner death ends the incarnation. Republish with the same
key creates a new incarnation, preserving the logical source identity.

The receiver owns up to 16 subscription records, each with a local random ID and
Swarm/publisher Device/source identity. Endpoint PID, control session, incarnation,
connection attempt and lease are separate volatile state. Each active endpoint is
a temporary local OTP worker owning an independent ExWebRTC PeerConnection with a
PCM data channel or Opus audio track. Failure or pause of one endpoint does not select, stop or retime another.
`ba_audio_sup` starts the mixer before the receiver with `rest_for_one`;
receiver failure resets dependent temporary media workers/publications. The mixer
also monitors its receiver owner and discards its queues/output on owner death.

## Local API

First start the [membership runtime](SWARM_MEMBERSHIP.md), explicitly grant the
receiver `stream_read` and `stream_subscribe`, and establish a fresh control session
to each publisher. The two additional grants are separate from status, capability
and job grants; existing members do not gain them automatically. Discovery and
subscription requests require the corresponding grant on the receiving publisher.

A local capture worker publishes, pushes and pauses its own source:

```erlang
D = #{encoding => pcm,sample_format => pcm16_le,sample_rate => 48000,
      channel_count => 1,clock => SharedClockId}.
{ok,Source} = ba_audio:publish(
    #{name => <<"Music">>,source_key => <<"music">>,profiles => #{channel => D}},self()).
{ok,_} = ba_audio:push(Source,channel,
    #{playback_time => PacketTargetNs,channel_id => 0},PCM).
ok = ba_audio:pause(Source,true).
ok = ba_audio:pause(Source,false).
```

Publication is an explicit local operation; remote requests cannot start capture.
Both ends separately install the same current Contract ID/revision for this
publisher/receiver/source relationship. These local permissions are not restored
from checkpoints:

```erlang
%% On the publisher:
ok = ba_audio_receiver:set_contract(publish,ReceiverId,<<"music">>,ContractId,1).
%% On the receiver:
ok = ba_audio_receiver:set_contract(receive_audio,PublisherId,<<"music">>,ContractId,1).
ok = ba_audio_receiver:refresh(PublisherId).
%% Wait for the authenticated catalogue offer in snapshot/0.
{ok,SubscriptionId} = ba_audio_receiver:subscribe(PublisherId,<<"music">>,channel).
%% Wait for state => active before enabling its output.
ok = ba_audio_receiver:playback(SubscriptionId,start).
ok = ba_audio_receiver:playback(SubscriptionId,stop).
ok = ba_audio_receiver:stop(SubscriptionId).
```

Receiver pause retains subscription and transport while removing that stream's
queued contribution from the mixer. Source pause also retains intent/transport.
Unsubscribe removes only that local intent and endpoint. `stop/0` deliberately
unsubscribes all. `gain(Id,0.0..1.0)` controls only that subscription's mixer input;
existing product gain/Music settings are untouched. `clear_contract/3` closes only
the affected direction/device/source's work; remaining subscriptions continue.
Installing the identical current Contract ID/revision is a no-op: publications,
Media Sessions and buffered output are preserved. An older revision of the same
Contract is rejected. Changed authorization bindings are reauthorized only for
their own scope; persistent intent and Source identity remain separate.

`snapshot/0` exposes `subscriptions` keyed by local ID, authenticated `offers`,
publication/provider counts, per-Subscription/provider transport diagnostics and
mixer counters/errors. It exposes no session PIDs,
SDP, ICE secrets or PCM. The old singular snapshot/UI command shape is replaced;
app adaptation belongs to step 9.

## Transport and authorization

Control uses the existing signed `stream.message` operation, strict flat schemas
and existing session sequence/deadline checks. Catalogue requests return bounded
individual offers and a correlated end marker; an incomplete/expired reply does
not replace the previous catalogue. Catalogue refresh polls established peers
every five seconds, without connecting them through OTP.

Subscribe/accept/reject/close/state and SDP/ICE are bound to the authenticated
peer, control session, source key/incarnation, local subscription ID and fresh
attempt ID. Unknown or old attempts cannot acquire an endpoint or forward generic
signaling. Contracts are checked before provider creation. Before dispatch the
receiver rechecks the current local control context and deadline, including when
its own mailbox was delayed by other work. Actual session loss, expiry or policy
invalidation stops live endpoints while retaining declarative intent. Losing one
Desk does not itself cancel permission or media through healthy routes.

Step 8d's fresh two-way nonce proof renews eligible control authorization in place,
retaining its session ID/replay sequence. The authenticated control owner passes
the new deadline to matching Media Sessions and the Mixer. Queues, publication
identities, decoder processes and original packet targets are retained. Stale
expiry timers cannot terminate renewed sessions. No cached state or timer alone
extends authorization, and an expired endpoint is not resurrected.

Buffer admission and execution are separate: authorized receivers may queue future
targets within the bounded 31 s lead even when those targets cross the current
lease. This permits sustained 30 s Offset. Before handoff, the Mixer checks the
current deadline and limits the output span so it cannot execute beyond that
permission. Failed renewal/expiry removes affected contributions and future queues;
revocation still fences them. A late renewal after a handoff has already been denied
can recover output but cannot replay missed audio or choose a replacement target.
Changed policy or a restarted control owner may still require a new media attempt.
General peer reconnection/automatic eligible work remains app integration in step 9.

Lightweight `diagnostics` contain bounded reason counters and a last-error code:
buffer full, late/overlapping/missing targets, missed handoffs, unavailable clocks,
transport/owner/Mixer mailbox overload and native decoder failures. Counts describe
events at each component's boundary; `sent` means submitted, not remote receipt.
Signaling overload ends a failed attempt visibly instead of silently stalling setup;
PCM overload drops are counted. Permission fencing/renewal is not dropped behind
PCM. OTP failure reports redact PCM/internal messages; counters are live process
state, not a persistent monitoring/history service.

The signed SDP carries the expected SHA-256 DTLS fingerprint; ExWebRTC performs
the DTLS certificate checks. A dedicated data-channel label binds subscription
and attempt. PCM travels directly through WebRTC/SCTP/DTLS, never through the Desk
or OTP distribution. The existing PCM packet codec carries the broadcaster's
independent 64-bit playback target in **every** packet. The channel is unordered,
with zero retransmissions. There is no new jitter buffer, loss concealment or
clock-recovery algorithm, and no claim of Internet media quality from this proof.

## Mixer, timing and supported formats

Erlang converts PCM16/24/32 and float32 mono/stereo into stereo float32 for local
summation, applies bounded per-input gain, then clips the summed output to [-1,1].
Each input has its own bounded queue; overlap, malformed/late packets, missing
targets, wrong clock IDs and excess queue limits are rejected rather than retimed.
Targets are converted to sample indices arithmetically; no neighbouring packet,
arrival time or periodic anchor supplies a missing target. An absent input is
silence in that input's interval and does not move another source's target.

The first playing stream selects the output rate/reference. Concurrent mixed
streams must share that rate/reference; incompatible output returns an explicit
error while its independent subscription/transport remains available. Sources
keep their original formats/rates. There is no implicit resampler or narrowing of
the publication descriptor. Pausing/removing all playing inputs releases the
output, so another supported rate can subsequently be selected.

A locally configured `audio_output_adapter` implements the existing `open/1`,
`write/4`, `close/1` OS-binding interface. The mixer plans handoff using the shared
clock and the adapter's reported latency, with at most 20 ms ahead of handoff
passed to the sink. Software scheduling does not establish calibrated DAC timing.
Already submitted mixed output cannot be selectively removed after a pause.
The supported code path needs a valid common clock: default `ba_swarm_clock` now supplies [authenticated shared Time/Offset](SWARM_TIME.md)
in the new headless profile. It never fabricates a fresh clock from membership or local arrival.

Opus publications explicitly select `stream_handler => webrtc_audio_opus`,
`encoding => opus`, `sample_format => opus`, 48000 Hz stereo and
`rtp_timestamp_semantics => global_playback_48k_v1`. They use the **same** signed
catalogue/Contract/subscription/SDP boundary, with a direct ExWebRTC Opus audio
track. The local capture owner submits `{push_encoded,Timing,OpusPayload}` to its
source; the existing `ba_audio_rtp_time` encodes each target into that packet's
RTP timestamp. There is no Opus-to-PCM transport fallback.

The approved GStreamer binding `adapters/gstreamer/pcm_bridge.py` uses its existing
`rtpjitterbuffer` (20 ms), depayloader and Opus decoder. After jitter buffering it
associates each RTP packet's PTS with its own RTP target; only decoded buffers
whose PTS matches that association are handed to Erlang as stereo float32.
Unmapped/concealed GAP buffers are rejected explicitly, with no neighbouring
target inferred. Erlang resolves the existing RTP wrap contract and feeds the
same scheduled mixer. The helper never opens an audio device, chooses a shared
clock or schedules presentation. Bounds include 64 native input buffers, 32
output buffers, 128 target associations and 4096 frames per decoded block.

Configure this decoder locally with `BA_GSTREAMER_PCM_HELPER` (absolute helper
path) and `BA_GSTREAMER_PYTHON` (GI-capable Python executable).
`BA_GSTREAMER_RUNTIME` optionally locates the existing bundled GI libraries and
plugins. Missing configuration keeps intent in `waiting_for_backend` with
`opus_decoder_unavailable`; it does not create repeated PeerConnections. PCM
remains the default publication path. This qualifies the **headless decoded-audio
handoff**, not replacement of native platform output or libwebrtc qualification.

On a valid new shared clock instance, PCM capture and the Mac Opus capture adapter
rebind their existing source key to a fresh publication incarnation and descriptor.
The receiver sends scoped closes for old endpoints, drops their queues and
restores retained intent from refreshed catalogues/Contracts. It never retargets
old audio. Capture logging uses local events/logger, without starting old chat.
The obsolete remote-PID native session and OTP-distribution PCM carrier are retired.

## Retained intent and limits

Step 9 replaces `audio_subscriptions.term` with gathering-owned ETS storage.
The format-1 collection still contains stable intent IDs, Swarm/device/source
keys, labels, profile, playing intent and gain. It survives receiver recovery
within this gathering, not its end or a VM restart. Old subscription files are
ignored. Contracts/consent, incarnations, endpoint PIDs, nonces, leases, audio and
packet targets are never restored. Receiver recovery cannot reopen media until
current local Contracts, a matching catalogue, current authorization and a fresh
clock are available. See [Ephemeral Swarm lifecycle](SWARM_MEMBERSHIP.md).

Bounds: 16 publications, subscriptions and outgoing provider endpoints each;
32 local direction/device/source Contracts, 16 catalogue offers per peer, five
seconds for catalogue replies, ten seconds for endpoint setup, 4096 queued blocks
per playing input, 8192 blocks/32 MiB total PCM, 4096 frames per input block,
16 KiB PCM media packets and 64-message owner-notification queues. PCM queues hold
stereo float32 binaries rather than sample lists. Admission lead is at most 31 s,
covering the maximum 30 s Offset; the memory budget is shared across inputs, not
a promise that all 16 inputs can each buffer 30 s. Opus payloads are at most 1275 bytes.
Overload drops/rejections are visible; these limits are not a capacity benchmark.
Restored subscriptions retry with a fresh attempt; automatic peer reconnection
and simultaneous-open resolution are not supplied.

## Validation

From `src/control`, run warnings-as-errors compilation and the relevant EUnit
modules; collection, fresh-clock/Contract gates, format conversion, independent
pause/targets, clipping/gain and signed stream schemas are covered. Old tests for
the retired singular receiver were replaced with collection/restore checks.

From the core root:

```sh
python3 tests/control/audio-streams-smoke.py
```

This needs the existing compiled `BeamTransport` ExWebRTC dependencies and local
Elixir libraries. On this Homebrew Mac the precompiled libsrtp dependency requires:

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py
```

The test uses OTP's direct launcher to preserve that local library path; it changes
no downloaded/generated dependency files. Three disposable unnamed BEAM runtimes
use a temporary instance of the existing Desk service for real signed signaling
and real WebRTC media. A test-only shared clock and scheduled PCM sink verify
mix values and per-packet targets, two simultaneous publishers, scoped pauses,
receiver restart without restored permissions, source disappearance/new incarnation,
unsubscribe and Contract revocation. No product app, native output device,
installed identity/state, cross-device clock accuracy or physical listening is
involved.

Step 8 adds `--swarm-time --sustained`: four seconds of continuous production
capture at the default 1000 ms Offset, zero mixer drops, queue drain and automatic
publication recovery after reference restart. A virtual-time EUnit proof queues
and drains two complete 30-second sources (23,040,000 PCM bytes) at their exact
targets. Step 8d subsequently verifies real loopback WebRTC playback across renewal
at 30-second Offset; this still does not qualify arbitrary Internet paths or
successful execution at a 5 ms lead on every backend.
`--swarm-time --opus` uses real GStreamer-encoded sine packets and the decoder,
checks two-source mixing, independent lifecycle, targets and headless handoff.
Reproduction commands and platform limits are in [the backend checks](../tests/control/README.md).

Mechanisms reuse [OTP local supervision](https://www.erlang.org/doc/system/sup_princ.html)
and the pinned [ExWebRTC PeerConnection API](https://hexdocs.pm/ex_webrtc/0.17.0/ExWebRTC.PeerConnection.html),
[GStreamer RTP jitter buffering](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpjitterbuffer.html)
and [appsink decoded-buffer access](https://gstreamer.freedesktop.org/documentation/app/appsink.html).
