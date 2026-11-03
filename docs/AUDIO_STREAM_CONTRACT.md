# Audio, stream and subscription contract — draft 0.1

Date: 2026-11-01. Status: semantic draft with a first implemented PCM/WebRTC
binding below. This is not an interoperability or synchronized-playback claim.
The user accepted compact, known-layout packet profiles with stable properties
described at stream setup. Other encodings and richer layouts remain open.

## Scope and principles

Sources publish audio plus the information needed to select, interpret and
schedule it. Receivers can obtain a complete scene and select/render locally,
or receive a subset selected upstream. Configuration chooses that policy;
Parvi defines consistent descriptions and selection semantics.

Preserve heterogeneous source encodings/rates unless a processing or delivery
requirement calls for conversion. No cluster-wide audio format, automatic quality
ceiling, custom sample codec or universal platform library is specified here.
Input supplies full sample/media data, not just meter summaries. Metering is
one consumer alongside processing, network transmission and rendering.

## Stream setup

A descriptor, known before its packets are processed, establishes:

- A stream reference scoped to the publication/connection, and descriptor version.
- Its packet-layout profile: channel or point-object audio initially.
- Payload encoding and the parameters required to interpret it, including sample
  rate/channel configuration and PCM representation or codec setup as applicable.
- The timeline reference, timestamp units and mapping from media/sample position
  to intended presentation time.
- Coordinate frame, units and axes for spatial content; channel meanings for
  channel content. These are semantic descriptions, not properties inferred from
  the bytes or from a debug label.
- The exact header layout, including whether gain or other extensions are present.

Stable properties need not be repeated per packet. Descriptors/layouts do not
change silently: a change needs an identified replacement and an agreed activation
boundary. Unknown or unsupported profiles cannot be decoded by guessing.

## Packet profiles

The logical model is a flat header plus a binary payload. The version 1 PCM
binding below assigns concrete widths and transport; other bindings remain open.

| Profile | Per-block information |
| --- | --- |
| Channel audio | Presentation time and channel selection information |
| Point-object audio | Presentation time and X/Y/Z position |
| Profile-defined extensions | Fields explicitly declared in the setup layout, for example linear gain |

A value fixed for the stream can be supplied by its descriptor instead of
being repeated. Stream/profile identity can be implicit in a dedicated delivery
context, or explicit when several contexts are multiplexed. Ordering, loss
detection and framing must be supplied by the selected transport binding where
needed; do not duplicate existing transport fields without a reason.

Presentation time identifies the intended speaker emission time of the first
audio frame. Subsequent timing/duration follows the agreed format and media
position. For PCM, frame count can follow from payload size and sample layout;
compressed payloads need their specified duration rule. There is no universally
required per-packet sample rate, bit depth, byte length or frame-count field.

Channel and spatial descriptions can coexist through an explicitly agreed
layout; the initial families are parser profiles, not competing system designs.
No arbitrary optional-property dictionary scan is required in the media path.

## Property semantics

- Point position requires a resolvable X/Y/Z triple for spatial selection.
  Individual properties may be absent from general metadata; a selector requiring
  an unavailable property does not match. Missing is not zero.
- Proposed physical-room convention: metres, X right, Y forward, Z up, relative
  to an explicitly identified frame. This axis convention is a draft decision;
  source and speaker coordinates must share a frame or have a defined transform.
- Optional linear gain has a default of 1. It is rendering gain, not an implicit
  codec reconstruction scale or a promise of noise-free playback.
- Object ID/name and display colour are optional contextual/debug metadata.
  Object IDs need not be globally unique; when supplied, publisher scope suffices.
  Transport stream identity remains independent of named sound identity.
- Width/height/depth, orientation/directivity, interpolation, diffuseness,
  nearest-speaker lock and frequency-specific subscriptions are deferred.
  They are not mandatory members of the initial point profile.

## Subscriptions and lifecycle

The conceptual operations are request/open, accept or reject, and close.
Acceptance establishes a descriptor and delivery context before media begins.
A subscription selects a publication or collection, requested content mode and
an optional selector; available formats/layouts are agreed rather than assumed.

The first selectors are all content, a channel selection, or point objects
inside a sphere. A sphere matches when the object's position at presentation
time is within its configured radius, including the boundary, in the agreed
coordinate frame. Metadata interval/interpolation rules need to be fixed before
implementing moving-object filtering; arrival time is not the selection time.

Receiving the complete scene and filtering locally is a valid first configuration.
Upstream filtering is an alternative placement of the same selection semantics;
it must not discard content that could contribute under the active configuration.
Speaker layout, coverage, orientation, panning, EQ, crossover and orchestration
are system configuration/rendering policy, not one mandatory subscription topology.
Configuration can be dynamic; effective-time/version rules for updates remain open.

Multiple subscriptions can refer to one publication. A subscription creates a
delivery relationship and possibly supervised workers, not a new BEAM node.
For native OTP peers, providers monitor subscriber owners and end active delivery
on DOWN, including noconnection. Supervision manages local worker lifecycle;
connection failure detection is not instantaneous. Cleanup does not revoke
cluster admission or claim that an unreachable device has died. Non-native
transports need an equivalent owner/session-closure mapping, still to be selected.

## Implemented PCM binding — version 1

This is the first concrete binding of the semantic contract, implemented in shared
Erlang, using the project's existing ex_webrtc/ex_sctp dependencies. It supports
`channel` and `point` layouts without an optional-field dictionary in each packet.
Compressed/encrypted application payloads, extensions and descriptor changes are
not implemented; WebRTC itself encrypts the connection.

### Descriptor

An offer maps each profile to a descriptor with these required properties:

| Property | Version 1 meaning |
| --- | --- |
| `encoding` | `pcm` |
| `sample_format` | `float32_le`, `pcm16_le`, `pcm24_le` or `pcm32_le` |
| `sample_rate` | Positive integer, frames per second |
| `channel_count` | Positive integer, interleaved samples per frame |
| `clock` | Nonempty binary identifying the timestamp domain |
| `coordinate_frame` | Point profile only: nonempty binary identifying the spatial frame |

`packet_version` defaults to `1`; `time_unit` defaults to `nanosecond`. Other
values are rejected. PCM integer formats are signed, float is IEEE 754; sample
bytes remain little endian. Each subscription has one immutable descriptor.
Changing it requires closing/opening a subscription, not changing packets silently.

A clock name is identification, not clock synchronization. `playback_time` means
the desired first-frame speaker emission time in that named domain, carried
unchanged. The separate [application clock service](../src/control/README.md#independent-application-clock)
now supplies a UTC/POSIX-to-local-monotonic mapping when the descriptor names
`parvi-utc-posix-ns/v1`. Other clock-domain translations, output latency
compensation and actual scheduling remain unimplemented. Mock publishers must say `mock => true`
and identify their mock clock/frame; receiving these bytes is not playback.

Point coordinates are float64 metres, X right/Y forward/Z up relative to the
named frame. Selectors use that same frame. There is no coordinate transform,
interpolation or motion model: one position applies to the complete block.
A sphere includes its boundary. This is block selection, not spatial rendering.

### Binary message

One DataChannel binary message is exactly one audio packet; its channel context
already identifies the subscription/profile/descriptor. Header integers and
coordinates use network byte order. The PCM payload retains its declared layout.

| Layout | Fields in byte order | Header size |
| --- | --- | --- |
| `channel` | Signed int64 `playback_time`, uint32 `sequence`, uint32 `channel_id` | 16 bytes |
| `point` | Signed int64 `playback_time`, uint32 `sequence`, float64 X/Y/Z | 36 bytes |

`channel_id` selects a logical bundle of the descriptor's `channel_count` channels,
not an individual sample inside an interleaved frame. For example a stereo bundle
can have ID 3 and `channel_count => 2`. Filtering keeps/drops that complete bundle;
it does not silently remove one stereo channel or remix it. Meaningful channel
labels/speaker assignments remain configuration metadata to add with their use.

The body must contain at least one complete PCM frame. Frame count is derived
from body length; neither count nor length needs another header field. The total
message must be at most 16,384 bytes. Producers split larger blocks at frame
boundaries and advance their timestamps accordingly; this API rejects oversized
or unaligned input and never truncates it. Width, gain, colour, object labels and
other extensions are not encoded by version 1.

A provider assigns sequence numbers from zero, modulo 2^32, per subscription,
after selection. DataChannel does not expose a media sequence number to the
application, so this field provides observable gaps/reordering without a custom
retransmission protocol. Receiver `sequence_gaps` counts forward gaps observed
so far, not definitive lost packets: late packets can still arrive. Duplicates
and older packets increment `reordered`; received blocks are delivered as they
arrive. This is not a jitter buffer.

### Subscription-to-media binding

The receiver registers a random 16-byte subscription token with its existing
local authorized PeerConnection owner before requesting provider readiness over
native OTP control. The provider opens a DataChannel labelled
`parvi-audio/v1/<uppercase hex token>`, `ordered => false`, `max_retransmits => 0`.
ex_webrtc/SCTP supplies channel negotiation and framing; no custom UDP handshake,
ACK/retry layer or new ICE connection is added. The token names the delivery
context, not a globally identified sound object. Unexpected incoming media
channels are closed, not attached to a guessed subscription.

`ready/1` completes after the provider's channel and the receiver's channel are
open. Media and control can overtake each other, so a bound receiver may process
media while the final ready reply is in flight. `active` means the media channel
is open, not that samples have arrived. Counters distinguish those conditions.

Session workers monitor the carrier and each other; the carrier monitors each
local media owner and closes/removes its channel even if that owner is killed.
Media closure ends the subscription without shutting down the native OTP channel.
There is no local in-VM/fake-media fallback when no authorized peer connection
exists. `listen/2` attaches one optional local consumer worker; losing that
observer detaches it without changing subscription ownership.

`push/4` validates a local producer's block and fans it out to session workers;
each applies its selector and sends a binary media message. Samples never use
native distribution as their cross-node delivery path. Send success means
local enqueue, not remote acknowledgement. A PC-mailbox limit reports `busy`,
but does not bound SCTP's internal buffers or slow consumers. Producer pacing,
network congestion and consumer queue policy need evidence from real streaming;
no sustained throughput/latency guarantee is made by this increment.

Validation: compilation plus a focused check with two local OTP nodes and real
WebRTC, using provisioned probe trust, verified exact PCM bytes/time/derived
frames, channel/point filtering, media closure and source-down cleanup while
native distribution remained connected. This did not exercise native apps,
Render invitations, WAN delivery, sustained capture, rendering or synchronization.

## First Mac-to-iPhone subscription lifecycle — researched 2026-11-01

Step 1 implementation update: the shared `parvi_audio` API now implements
publication/discovery and accepted/ready session ownership, documented in the
[audio component guide](../src/Audio/README.md#subscription-control--step-1).
The audio supervisor is attached on demand to preserve existing app startup.
Step 2 now adds PCM media delivery; the version 1 binding and component guide
describe the implementation and its separate two-node WebRTC check.

The user requested this concrete increment: join Mac and iPhone through native
invitations, enable the Mac's system-output publication, discover its offers on
iPhone, submit a valid subscription (mock configuration values are acceptable),
and start delivering real audio packets. This expands the previous Mac-only
scope to iPhone discovery/subscription/reception. Speaker rendering and proven
acoustic synchronization are separate from showing actual packet reception.

### OTP ownership model

Use existing OTP facilities, without an additional broker or cluster manager:

- A source `gen_server` owns the publication descriptor and input lifecycle.
  It joins an audio-source group in the existing `parvi_pg` scope only when ready.
  `pg` provides live process discovery; descriptions are fetched from the source.
  A local catalogue can observe group changes for UI snapshots, without becoming
  another membership authority. A stale discovery result is validated on open.
- Each node has a local dynamic `one_for_one` supervisor for subscription workers.
  Session endpoints use `gen_statem` with opening, waiting-ready and streaming
  states, plus termination on close/failure. State timeouts bound incomplete setup.
- One logical subscription has receiver ownership on iPhone and a provider-side
  delivery worker on Mac. Workers are `temporary` children initially: ending a
  session does not restart an obsolete subscription. A future desired-subscription
  policy can explicitly open a fresh session after recovery.
- Session endpoints monitor each other; provider delivery also depends on its
  source and transport owner. Monitors express session dependency, while local
  supervisors own restarts. Subscription ownership belongs to the runtime,
  not a disposable window/view. No central subscription authority is required.
  The source and peer owner also monitor delivery workers so a killed session
  removes their forwarding entries without relying on its terminate callback.
  If the `pg` scope restarts, restart/rejoin publication owners through supervision;
  group membership is not automatically retained across a scope restart.

### Open and start sequence

1. Complete existing invitation/admission and native OTP connection establishment.
   `pg` then exposes directly connected peers' published source processes.
2. Enabling Mac capture starts the thin Core Audio tap adapter and source worker.
   A ready publication advertises its description, offered profiles/formats and
   required subscription parameters. An offer is not yet an active subscription.
3. The iPhone UI reads available offers through its Erlang runtime. Selecting one
   starts a local receiver session, which sends an asynchronous open request to
   the Mac source with its actual owner PID, a correlation reference and requested
   profile/selector/configuration. Mock coordinates are marked as mock and are not
   measurements of position, clock offset or output latency. The first system-mix
   publication can offer channel audio without inventing object metadata.
4. The source validates the request and starts a monitored provider session.
   Acceptance supplies the descriptor, provider endpoint and media-context identity.
   The receiver monitors the provider. Both endpoints establish the media channel;
   the receiver installs the known-layout parser and sends ready. The provider
   starts forwarding only for the matching live session once setup is complete.
5. Captured PCM flows through the Erlang source into the subscription's binary
   media context. Metering observes this stream rather than replacing it with
   level summaries. The iPhone records real received audio/format/counter state.
   Declaring reception does not claim that an iPhone speaker is already rendering
   on the presentation timeline. Media does not pass through the UI JSON bridge,
   source catalogue or shared message log.
6. The receiving Erlang worker validates/depacketizes the agreed initial PCM
   profile, updates packet/sample counters and reuses `parvi_audio_meter` to
   calculate peak/RMS from the received samples. No new metering algorithm or
   packet-level callback into Swift is needed.
7. The iPhone app displays a volume/activity meter from those Erlang summaries,
   alongside a receiving state/counter. Silent received audio must remain
   distinguishable from no packets arriving. This is the visible completion
   criterion for the first subscription/reception increment; it does not imply
   speaker playback or verified synchronization.

Use correlated OTP asynchronous requests so a remote open does not block the
source or receiver event loop. A request timeout alone does not undo a remote
operation: an expired/cancelled receiver session must terminate. If a provider
is created after its requester has gone, monitoring that owner still reports DOWN.
Automatic retries/idempotent reopens are not needed for the first explicit-open
increment; a later reconnect opens a new session rather than reviving stale PIDs.

### Control and media transport

Do not implement TCP-like reliability on raw UDP. Native OTP control already
uses the reliable ordered WebRTC DataChannel. The third-party SCTP/DataChannel
stack provides delivery modes and its channel-establishment handshake.

Implemented first media binding: a separate binary DataChannel on the existing
authorized peer connection, with unordered delivery and no retransmissions
(`ordered: false`, `max_retransmits: 0`). This is a prototype binding for our
heterogeneous payloads/headers, not a claim that DataChannels replace RTP media
or provide audio clock synchronization. RTP/media facilities remain candidates
when codec/receiver needs justify that binding. No ICE/DTLS connection is needed
per subscription; media/control can share the peer connection while using
different logical channels. They still share capacity/congestion.

The `parvi_dist_channel` peer owner now delegates additional media contexts to
`parvi_media_channel`, routing events by actual local DataChannel references to
registered session owners while preserving native framing/admission. Library channel references are local, not
portable Erlang references shared between devices. Closing audio must not close
the native control connection. The binding needs app-visible packet sequencing
where the library does not expose ordering/loss information.

### Ending sessions and removing ghosts

Explicit unsubscribe ends the receiver owner; its peer observes DOWN and removes
the forwarding route. Receiver/provider crash, source stop, channel closure and
native connection loss end affected sessions as dependencies fail. `pg` removes
dead source processes. Runtime loss also releases that VM's in-memory resources.
No periodic sweep of a permanent subscription table is necessary.

This is event-driven cleanup after failure detection, not instantaneous remote
death detection. A network partition produces noconnection when OTP detects it;
an unreachable phone is not proof of a dead device. Bound media queues and discard
expired work while detection is pending. Native admission permission remains
separate from active subscription ownership. Explicit closure/removal must remove
forwarding routes even if best-effort cleanup callbacks cannot run.

A media channel can fail while native control remains alive; its library events
must end that media session independently. `send_data` returning `ok` currently
only enqueues work locally, not a delivery acknowledgement; sender handoff and
library queues need actual limits. A muted/silent source is not by itself a dead
subscription. Clock synchronization, pacing and backpressure are independent
from the application open/ready handshake, not a new homemade TCP protocol.

The current `pg` implementation is eventually consistent and its view is not
transitive through an arbitrary partial mesh. The two-node direct case fits;
broader discovery/topology policy remains separate work.

References: [OTP pg](https://www.erlang.org/doc/apps/kernel/pg.html),
[gen_statem](https://www.erlang.org/doc/apps/stdlib/gen_statem.html),
[supervisors](https://www.erlang.org/doc/apps/stdlib/supervisor.html),
[process monitors](https://www.erlang.org/doc/apps/erts/erlang.html#monitor/2),
[asynchronous gen_server requests](https://www.erlang.org/doc/apps/stdlib/gen_server.html#send_request/2),
[WebRTC DataChannels](https://www.rfc-editor.org/rfc/rfc8831.html) and
[DataChannel establishment](https://www.rfc-editor.org/rfc/rfc8832.html).
The pinned `ex_webrtc` 0.17.0 source was also inspected for channel open/close,
unordered/retransmission options and local-reference semantics. This is a selected
implementation approach; no new source/subscription/media worker is implemented
by this research update.

### Reuse boundary verified before implementation

Use built-in `pg`, `gen_server`, `gen_statem`, supervisors, monitors and binary
handling, plus the pinned WebRTC/SCTP libraries and public Core Audio APIs.
Reuse the existing Erlang PCM meter. Do not introduce a broker, replacement
registry/membership system, custom reliable-UDP protocol or new audio codec.

OTP supplies the mechanisms, not a turnkey audio subscription product. Parvi
still needs small behavior callbacks connecting publication descriptions,
request validation, open/ready/close transitions and cleanup to media-channel
operations. It also needs the native capture/buffer adapter, UI snapshot wiring
and audio packet/descriptor encoding. These are application integration, rather
than newly invented supervision or transport algorithms. Their correctness is
not established merely by using tested dependencies.

The native WebRTC distribution carrier/admission integration already in this
repository is Parvi-specific; it is not an OTP-provided WebRTC transport.
This increment reuses that existing boundary. OTP/WebRTC do not by themselves
supply common audio-clock synchronization, hardware-output delay compensation
or a spatial renderer. Those remain explicit later work rather than promises
attached to the receive meter.

## Timing and rendering

Receivers map the presentation timeline to their local clock and compensate for
their remaining processing/output-path delay. Clock offsets, rate drift and
device delays are estimates; requested presentation time is not a measured
accuracy guarantee. Acoustic arrival at a listening point additionally depends
on geometry and any configured propagation compensation.

The independent application clock now provides a first shared UTC/POSIX timeline
and reports freshness/uncertainty; it does not establish measured acoustic alignment.
No packet profile alone establishes clock synchronization, sufficient arrival
lead time or deadline handling. The transport/rendering binding must define
these. A missed deadline must not silently shift the agreed timeline.

## Existing models to reuse

- [ADM object metadata](https://adm.ebu.io/guidelines/reference/adm_elements/audio_channel_format_objects.html)
  supplies established meanings for position, extent, gain, diffuseness and
  rendering controls. Its documented Cartesian convention uses normalized
  coordinates; our proposed physical metres require an explicit mapping, not a
  claim of identical semantics or ADM conformance.
- [Serial ADM](https://www.itu.int/rec/R-REC-BS.2125-1-202205-I) is the reference
  to examine for live metadata evolution. Neither ADM XML nor its full feature
  set is required as our hot-path packet representation.
- [RTP](https://www.rfc-editor.org/rfc/rfc3550.html) and
  [RTP header extensions](https://www.rfc-editor.org/rfc/rfc8285.html) are candidates
  for media framing and negotiated metadata. An RTP sampling timestamp is not
  automatically an intended speaker playback timestamp; a playout mapping is needed.
- [RTP clock signalling](https://www.rfc-editor.org/rfc/rfc7273.html) distinguishes
  media/sample clocks and reference clocks. The independent SNTP/peer application
  clock supplies an initial timeline; a rate-drift/output-clock discipline is unselected.
- [NMOS](https://www.amwa.tv/nmos-getting-started) demonstrates separation of
  sources/flows/senders/receivers and connection management. Reuse those distinctions
  where helpful; no NMOS registry, REST stack or replacement for OTP supervision
  and the existing Reception Desk is proposed.

Dolby Atmos is a conceptual object-audio reference, not a selected codec,
wire format or compatibility target. Ordinary captured stereo does not recover
the separate authored objects and trajectories of an Atmos production.

## Decisions before implementation and later refinements

The first PCM binding above now fixes header representation, nanosecond units,
named clock/frame domains, immutable descriptors, observable sequence gaps and
subscription closure. Mac capture/publication is now connected to that shared
path in source, with a provisional 250 ms capture-to-presentation allowance.
Its real tap/permission flow awaits the deferred Mac app build/run; the next
source step is the iPhone receive UI/meter. This need not expand into a complete
renderer or recovery programme.

Still open: clock synchronization/uncertainty and output-latency measurement;
the first renderer/coverage policy and motion interpolation; source spatial metadata
for captured mixes; format changes and dynamic subscription activation; filtered
stream gaps versus packet loss; codec/metadata transport mapping; and the relationship
between timeline lead time, source monitoring and Bluetooth/device buffering.
Listener layouts, advanced object extent, colour conventions, adaptive encodings,
per-subscription quality conversion and new codecs can wait for an actual need.

The shared cross-node PCM binding and Mac audio adapter are implemented in
source. Real Mac capture remains unverified; iPhone subscription/meter UI is next.
