# Independent Streams and Subscriptions — step 6

The headless `swarm_control` runtime now has a collection of independent PCM
subscriptions and one local scheduled mixer. The old single receive slot and
remote-PID discovery/subscription path have been replaced. Installed apps and the
native Opus receiver have not been migrated or launched.

## Identity and ownership

`parvi_audio:publish/2` creates a local supervised publication with an explicit
stable `source_key` and fresh incarnation. Its local capture owner supplies every
packet's target. Source pause keeps that publication/incarnation and its idle
transports; unpublish or owner death ends the incarnation. Republish with the same
key creates a new incarnation, preserving the logical source identity.

The receiver owns up to 16 subscription records, each with a local random ID and
Swarm/publisher Device/source identity. Endpoint PID, control session, incarnation,
connection attempt and lease are separate volatile state. Each active endpoint is
a temporary local OTP worker owning an independent ExWebRTC PeerConnection/data
channel. Failure or pause of one endpoint does not select, stop or retime another.
`parvi_audio_sup` starts the mixer before the receiver with `rest_for_one`;
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
{ok,Source} = parvi_audio:publish(
    #{name => <<"Music">>,source_key => <<"music">>,profiles => #{channel => D}},self()).
{ok,_} = parvi_audio:push(Source,channel,
    #{playback_time => PacketTargetNs,channel_id => 0},PCM).
ok = parvi_audio:pause(Source,true).
ok = parvi_audio:pause(Source,false).
```

Publication is an explicit local operation; remote requests cannot start capture.
Both ends separately install the same current Contract ID/revision for this
publisher/receiver/source relationship. These local permissions are not restored
from checkpoints:

```erlang
%% On the publisher:
ok = parvi_audio_receiver:set_contract(publish,ReceiverId,<<"music">>,ContractId,1).
%% On the receiver:
ok = parvi_audio_receiver:set_contract(receive_audio,PublisherId,<<"music">>,ContractId,1).
ok = parvi_audio_receiver:refresh(PublisherId).
%% Wait for the authenticated catalogue offer in snapshot/0.
{ok,SubscriptionId} = parvi_audio_receiver:subscribe(PublisherId,<<"music">>,channel).
%% Wait for state => active before enabling its output.
ok = parvi_audio_receiver:playback(SubscriptionId,start).
ok = parvi_audio_receiver:playback(SubscriptionId,stop).
ok = parvi_audio_receiver:stop(SubscriptionId).
```

Receiver pause retains subscription and transport while removing that stream's
queued contribution from the mixer. Source pause also retains intent/transport.
Unsubscribe removes only that local intent and endpoint. `stop/0` deliberately
unsubscribes all. `gain(Id,0.0..1.0)` controls only that subscription's mixer input;
existing product gain/Music settings are untouched. `clear_contract/3` closes only
the affected direction/device/source's work; remaining subscriptions continue.

`snapshot/0` exposes `subscriptions` keyed by local ID, authenticated `offers`,
publication/provider counts and mixer counters/errors. It exposes no session PIDs,
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
its own mailbox was delayed by other work. Session/policy/Desk loss drops live
endpoints while retaining declarative intent. Each endpoint independently expires
with its authenticated control-session lease and checks it on media send/receive.
The mixer independently expires input queues and rejects packet spans extending
past their authorization deadline, even if receiver cleanup is delayed.
There is no silent lease renewal or uncertain packet replay.

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
The supported code path needs a valid common clock: default `parvi_clock` remains
unavailable in the new headless profile until step 7 migrates its discovery and
Offset policy. It never fabricates a fresh clock from membership or local arrival.

The unchanged native libwebrtc/GStreamer Opus path bypasses Erlang PCM and still
uses its earlier signaling path. This collection explicitly rejects that native
source format; it neither silently converts an Opus publication to PCM transport
nor claims native multi-source playback. Native decoded-audio handoff/mixing and
its platform execution remain integration gates before full backend/app acceptance
in steps 8–9. This increment proves the Erlang PCM/default-path collection and
mixing architecture, not replacement qualification of the approved Opus engine.

## Retained intent and limits

`audio_subscriptions.term` stores only a format-1 collection inside the existing
version-2 checkpoint envelope: stable IDs, Swarm/device/source keys, labels,
profile, playing intent and per-input gain. The former single `audio_subscription`
record is deliberately not imported. No contracts/consent, incarnations, endpoint
PIDs, nonces, leases, audio or packet targets persist. Restart cannot reopen media
until current local Contracts, matching catalogue, current membership/control
session and fresh clock are available. Suspension/network handover drops live
resources and requires fresh clock evidence after resume.

Bounds: 16 publications, subscriptions and outgoing provider endpoints each;
32 local direction/device/source Contracts, 16 catalogue offers per peer, five
seconds for catalogue replies, ten seconds for endpoint setup, 32 queued PCM
blocks per playing input, 4096 frames per input block, 16 KiB media packets and
64-message input queues. First-packet target lead is limited to one second.
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
PARVI_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py
```

The test uses OTP's direct launcher to preserve that local library path; it changes
no downloaded/generated dependency files. Three disposable unnamed BEAM runtimes
use a temporary instance of the existing Desk service for real signed signaling
and real WebRTC media. A test-only shared clock and scheduled PCM sink verify
mix values and per-packet targets, two simultaneous publishers, scoped pauses,
receiver restart without restored permissions, source disappearance/new incarnation,
unsubscribe and Contract revocation. No product app, native output device,
installed identity/state, cross-device clock accuracy or physical listening is
involved. These software checks are distinct from steps 7–9 acceptance.

Mechanisms reuse [OTP local supervision](https://www.erlang.org/doc/system/sup_princ.html)
and the pinned [ExWebRTC PeerConnection API](https://hexdocs.pm/ex_webrtc/0.17.0/ExWebRTC.PeerConnection.html).
