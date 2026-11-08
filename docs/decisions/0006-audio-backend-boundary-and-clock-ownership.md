# 0006 — Audio backend boundary and Erlang clock ownership

> **Migration status — 2026-11-08:** This decision records earlier implementation
> boundaries and evidence. The [secure Swarm roadmap](../PLAN.md) supersedes its
> cross-device trust assumptions and old next-step instructions. Retain useful
> local OTP/media ownership; use the [engine interface](../AUDIO_ENGINE_INTERFACE.md)
> for the current independent per-packet target rule and platform limits.

Date: 2026-11-02. Status: accepted; legacy boundary implemented in source.

Superseding follow-up: [decision 0008](0008-replaceable-audio-stream-handlers.md)
defers GStreamer integration and names the implementation boundary **stream
handler**. The original module names and next-step proposal below describe the
earlier extraction; follow the current plan and decision 0008 for new work.

Follow-up requested 2026-11-02: `PLAN.md` now puts explicit master restoration,
one-time external acquisition and asynchronous per-node 30-second pulls before the
native media proof. The first clock implementation and focused tests are now
recorded in [decision 0007](0007-cluster-clock-pulls-and-monotonic-mapping.md);
the original clock description below is the baseline at this decision's creation.

## Decision and scope

Use a small Erlang backend behaviour behind the existing audio API and OTP
workers. Preserve the working WebRTC/PCM path as `legacy_webrtc`. Permit an
isolated GStreamer media experiment next; adopting a mature engine does not
require first proving that Erlang is incapable of good playback. Replacement of
the default requires relevant playback, recovery and timing evidence.

`parvi_audio` remains the public facade. Publication discovery/ownership stays
with `parvi_audio_source`; `parvi_audio_subscription` retains endpoint state,
readiness, monitors and cleanup; `parvi_audio_receiver` retains its consumer and
playback owner. The existing audio supervisor retains all child lifetimes. A
stateless backend module is sufficient for this increment: there is no second
session manager, registry, provider process or OTP application.

The repository's Erlang-first policy now explicitly permits the isolated native
experiment and approved media transport. This does not transfer cluster trust,
admission, routing decisions, synchronization policy or UI logic into native code.
Existing platform-independent Erlang sources and platform adapter locations stay
intact. There is no new dependency or native engine in this increment.

## Implemented legacy interface

`parvi_audio_backend` declares the callbacks and explicitly selects the only
bundled implementation, `parvi_audio_backend_webrtc`. Each subscription/receiver
pins that module for its lifetime. No runtime switching, automatic ranking or
unsupported backend setting is introduced with only one real implementation.

| Callback | Responsibility in the legacy path |
| --- | --- |
| `info/0` | JSON-compatible identity and factual limitations; not negotiated capabilities. |
| `bind/3` | Expect/open media on an already authorized peer connection; return its controller PID. |
| `send/3`, `close/2` | Submit/close that subscription's media token from its actual owner. |
| `output_available/0` | Report whether the existing platform output adapter is configured. |
| `start_output/2` | Start the existing temporary supervised output worker. |
| `push_output/3`, `stop_output/1` | Feed/stop that existing playback worker. |

Callbacks run in their existing owner process. In particular, media calls still
originate from the subscription PID used by the controller's permission checks.
Binding does not itself mean readiness: the existing `{media, Controller, Token,
Event}` notifications still drive activation/closure, and the controller still
monitors its subscription owner. Playback retains its existing status messages,
owner monitor and device-close behavior. There is no extra forwarding mailbox.

Packet encoding/decoding, sequence accounting and sender selection remain where
they were. The output worker retains the same PCM conversion, presentation
deadline mapping, reported-latency subtraction and late/out-of-order rejection.
Stopping playback remains separate from stopping a subscription. No change to
wire bytes, selectors, retries, clock service, packet timing or default delay is
intended. `parvi_audio:backend/0`, subscription status and receiver snapshots
expose the selected backend and its limits.

The callbacks above describe the current legacy integration. They are not a
finished native engine protocol. A native stream must not be forced through
`send/3` or `push_output/3` just to fit this first behaviour. Add its actual
prepare/activate/stop control and timing feedback only when the isolated proof
establishes what is needed; retain the current callbacks for the baseline.

## Clock and synchronization authority

The accepted target has one explicitly designated Erlang master establishing
universal time for the participating receivers. Every local Erlang node maps
that reference to its monotonic clock, decides when audio should be heard,
accounts for its output route and directs correction. A backend has no authority
to pick a different master, change the shared presentation deadline or silently
delay one receiver relative to its group.

Native code reports its actual device sample position/rate, host timestamp,
latency, queue depth, underruns and clock quality where available. It executes
Erlang's approved scheduling and bounded correction instructions without waiting
for Erlang in a real-time callback. One native component may resample or servo
the device clock against the supplied target/limits; it does not independently
decide the cluster synchronization policy. A new route, obsolete clock mapping
or insufficient deadline is reported to Erlang for a decision.

GStreamer's pipeline clock/base-time and the device's sample clock are local
execution coordinates, not alternative cluster masters. The proof must map
Erlang's monotonic presentation target to those coordinates explicitly. Account
for pipeline staging and downstream output latency once, and identify one final
scheduling owner. In particular, avoid a jitter-buffer/appsink path that waits
until the audible deadline before passing a buffer to an OS adapter that needed
it earlier. Do not run two independent drift controllers.

This refactor does not implement that complete synchronization target. Existing
`parvi_clock` still defaults to per-node METAS SNTP queries and already supports
an explicit `{node, Master}` reference. Its generic clock ID is not proof that
receivers share the same configured reference or precise acoustic timeline.
Master configuration/distribution, smooth native clock mapping and sample-clock
correction belong to the upcoming proof/integration steps. No clock accuracy or
two-speaker alignment improvement is claimed here.

## Native experiment and platform arrangement

Start with a desktop fixture using one fixed integer PCM format, standard RTP
L16 or L24, and established jitter-buffer/retransmission components. Connect the
feedback and packet-history path and verify actual recovery; setting a property
is insufficient. Float32 capture transport requires a preserving profile or
explicitly allowed conversion before application integration.

For macOS, use a port-controlled native helper for the isolated pipeline. Erlang
owns that helper's lifecycle and control messages. For iOS, the engine must live
inside the application process behind a small C/Objective-C/Swift control
binding. Keep long-running media work off BEAM schedulers. Platform host/binding
code belongs under `src/Audio/adapters/<platform>/`; genuinely shared native
engine code may be introduced under `src/Audio/engine/` when it exists.

Reuse the current capture/output bindings where their buffer/timestamp contract
fits. Native audio travels directly between capture, engine and render components;
Erlang receives bounded summaries. Reusing AVAudioEngine must not retain a second
scheduler competing with GStreamer. Native selector/format changes must remain
explicit; the first channel-only experiment does not remove the legacy point
selector. Direct LAN connectivity is the initial scope; existing WebRTC/TURN
reachability does not establish native RTP reachability.

## Build and licensing gates before native integration

- Pin an exact GStreamer release and dependency/plugin set when implementing the
  fixture; record which RTP, recovery, format and device elements actually exist
  on each target. No version is selected or library installed by this decision.
- Official iOS documentation provides an XCFramework packaging route. Verify its
  exact device/simulator slices and elements against our app before claiming
  compatibility; package availability alone is not integration evidence.
- Record the chosen static/dynamic linking arrangement, notices and required
  redistribution/relinking materials for that exact build. GStreamer's licensing
  advisory and deployment guide identify library/plugin/linking considerations;
  this decision does not settle them or change OpenSound's license.
- Keep generated SDKs and experiment artifacts under ignored `builds/`. Do not
  modify the running Reception Desk or default app media path for the fixture.
- Configure media security explicitly before app use; no silent downgrade from
  authenticated/encrypted WebRTC. RAVENNAKIT/AES67 remains deferred.

## Validation and next step

Compilation establishes that the behaviour, adapter and callers agree; it does
not prove unchanged audio on devices. The current apps remain on their previously
built code until a requested rebuild/deployment. New automated tests, hardware
runs and performance claims require their own actual evidence.

Next: the isolated fixed-format desktop GStreamer proof, including Erlang-directed
timing and drift execution. General capabilities, backend negotiation and full
native Mac-to-iPhone integration follow demonstrated requirements.

## Primary references

- [OTP design principles](https://www.erlang.org/doc/system/design_principles.html)
  and [gen_statem](https://www.erlang.org/doc/system/statem.html): existing process
  ownership and callback/state-machine patterns.
- [GStreamer clocks](https://gstreamer.freedesktop.org/documentation/application-development/advanced/clocks.html):
  pipeline/base-time, latency and device clock-rate distinctions.
- [GStreamer iOS packaging](https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html).
- [Deployment](https://gstreamer.freedesktop.org/documentation/deploying/index.html)
  and [licensing advisory](https://gstreamer.freedesktop.org/documentation/application-development/appendix/licensing.html).

Library references checked 2026-11-02; these architecture choices are OpenSound's
decisions, not a claim that a library supplies the entire cluster policy.
