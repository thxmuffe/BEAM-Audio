# BEAM Audio: Capability-Negotiated Media Providers

> **Archived 2026-11-08 — historical proposal or checkpoint.**
> Preserved for reference; statements such as “current”, “next”, and
> “accepted” below describe their original date. They do not set today’s
> implementation order or establish working features. Follow the
> [secure Swarm roadmap](../PLAN.md) and [archive notes](README.md).

## Codex implementation specification

**Version:** 0.1  
**Date:** 2026-11-01  
**Repository:** `thxmuffe/OpenSound`  
**Reviewed baseline:** `eeb173a38aa013ed88c17dce86fb257392040b23`  
**Status:** Proposed implementation plan; not implemented or performance-validated by this document.

**Implementation follow-up, 2026-11-01:** The accepted incremental sequence is
in [PLAN.md](PLAN-before-swarm-2026-11-08.md#implementation-record--sequence-begun-2026-11-01).
It prioritizes a minimal backend boundary and a real native playback proof before
general negotiation, and defers RAVENNAKIT and restoration. Erlang owns the master
time reference, local clock mapping, presentation schedule and correction policy;
native backends execute that policy and report device timing. Where milestone
order or synchronization ownership is ambiguous here, follow the current plan.
The subsequent priority update in that plan brings persistent cluster identity
and automatic rejoin ahead of native audio work; full media restoration remains
deferred.

**Architecture follow-up, 2026-11-02:**
[Decision 0006](../decisions/0006-audio-backend-boundary-and-clock-ownership.md)
records the accepted boundary and clock ownership. The compiled legacy wrapper
uses the existing subscription/receiver owners without an additional provider
process. This is the first extraction, not a finished native engine protocol or
a new device-playback validation. Follow `PLAN.md` for the next isolated proof.

**Clock follow-up, 2026-11-02:**
[Decision 0007](../decisions/0007-cluster-clock-pulls-and-monotonic-mapping.md)
records the first asynchronous clock implementation and its connected-peer
coordination limits. Physical reference/alignment validation remains separate.

## 1. Outcome and boundaries

Build a small, explainable audio-provider abstraction that lets each Erlang node negotiate and supervise the audio implementation appropriate to its device, peers and subscriptions.

The application addresses one stable local provider. It does not select GStreamer, manipulate RTP packets or decide quality independently of Erlang. A node may operate several streams through different backends simultaneously.

**Erlang owns intent, authorization, negotiation and lifecycle. Native engines execute approved media plans. Platform adapters bind those engines to OS audio facilities.**

Discover the implementations bundled with an app at startup; select the actual backend and format per subscription. Startup selection establishes defaults, not a permanent node-wide audio format.

### First prototype

- Preserve the existing Mac-to-iPhone WebRTC path as a baseline backend.
- Add a GStreamer native backend on macOS and iOS.
- Add an optional macOS RAVENNAKIT/AES67 evaluation backend, subject to its build and licensing gate.
- Prove capability negotiation, explainable selection, native handoff and safe lifecycle behavior before adding more platforms.

Windows, Android and Linux must fit the contracts, but implementing all their adapters is not part of the first prototype. A simulated backend is useful for tests but does not count as a third working media backend.

**Not in the first increment:** a universal plugin marketplace, downloadable executable plugins, a new cluster framework, automatic clock-leader election, transparent VM migration, arbitrary processing-graph optimization or a spatial renderer.

### Repository policy transition

The current `AGENTS.md` explicitly prefers Erlang audio algorithms until measurement justifies offloading, and the existing plan limits unsolicited tests, builds and deployment. This proposal changes the architecture direction, not those working practices. [R1, R2]

Before native integration, record a narrow architecture decision and reconcile the affected instructions: native third-party media backends are permitted as isolated experiments; the default path is replaced only after relevant measurements. Keep control policy in Erlang. Do not silently rewrite unrelated instructions or claim that performance has already justified migration.

Implementation must respect the user's build, test, signing and live-service approvals. The acceptance cases below define evidence to obtain, not permission to deploy or interrupt a running system.

## 2. What exists and what must remain working

At the reviewed revision:

| Existing component | Migration role |
|---|---|
| `parvi_audio.erl` | Preserve the public publication/subscription facade. |
| `parvi_audio_sup.erl` | Reuse the existing supervised audio branch; add one local provider, not another OTP application. |
| `parvi_audio_source.erl` | Keep publication ownership and discovery; eventually remove native-stream sample fan-out from its mailbox. |
| `parvi_audio_subscription.erl` | Keep the endpoint state machine and monitors; introduce backend preparation/activation behind it. |
| `parvi_media_channel.erl` | Retain as part of the legacy WebRTC backend. It currently uses unordered channels with zero retransmits. |
| `parvi_audio_packet.erl` | Preserve legacy packet definitions and selector behavior as compatibility references. |
| `parvi_audio_input.erl`, `parvi_audio_receiver.erl`, `parvi_audio_output.erl` | Keep the legacy path. Native backends must eventually bypass their per-buffer sample processing, while retaining control/status functions where useful. |
| `adapters/macOS/audio_input.mm` | Reuse the working Core Audio capture binding. |
| `adapters/iOS/IOSAudioOutput.swift` | Reuse the AVAudioEngine output binding; evolve its buffer connection rather than replacing the UI. |
| `parvi_clock.erl` | Preserve the current clock service while exposing explicit clock quality and backend clock mappings. |

The current subscription code filters at the sender before encoding selected packets. The current output code converts PCM into planar floats and rejects late/out-of-order buffers; this is not a reorder/recovery buffer. These are source-code observations, not proof of the cause of reported glitches. [R3-R9]

The first refactor must not alter the existing packet format, trust/admission protocol, default playback-delay behavior or Reception Desk. Preserve native invitations, source discovery, subscription setup, playback controls and source-stop cleanup.

## 3. Vocabulary and ownership

Use these names consistently in code and documentation:

| Name | Meaning |
|---|---|
| **Audio Provider** | One locally registered, supervised Erlang process per node. Stable application-facing control endpoint. |
| **Backend** | A bundled implementation, such as legacy WebRTC, GStreamer or RAVENNAKIT. |
| **Wire Profile** | A versioned interoperable network contract: payload, framing, timing, security, recovery and metadata rules. Not a library name. |
| **Device Adapter** | OS-specific capture/playback and route/capability binding. |
| **Media Plan** | The exact negotiated configuration for a subscription, including approved conversions and timing. |
| **Selection Policy** | A named ordering of preferences, applied only after hard requirements pass. |
| **Clock Domain** | An explicitly identified timeline and its mapping to local host/device clocks. |
| **Sync Group** | Receivers required to present related audio on the same timeline. Not the entire cluster by default. |

A backend is not necessarily transport-only: a library may provide buffering, resampling or timing too. Its manifest reports these functions. The plan assigns **one owner per function** so multiple libraries do not each buffer, resample or compensate latency independently.

```text
Swift / other platform UI
         | commands and status
parvi_audio public facade
         |
local Audio Provider <---- Erlang peer negotiation / cluster knowledge
         |
existing subscription state machine
         | prepare / activate / stop / status
native engine host
         |
backend media path <============> remote backend media path
         |
device adapter <----> OS / driver / ADC or DAC
```

Swift can control the native engine and OS on Erlang's behalf. Ordinary device and stream decisions go through Erlang; time-critical OS callbacks and native media processing do not round-trip through Erlang.

## 4. Provider and backend interfaces

### 4.1 Minimal Erlang structure

Use the existing `parvi_` module prefix. Proposed additions:

```text
src/Audio/src/
  parvi_audio_provider.erl       local gen_server; capability snapshot and dispatch
  parvi_audio_backend.erl        backend control behaviour
  parvi_audio_policy.erl         pure matching/ranking/explanation functions
  parvi_audio_backend_webrtc.erl  adapter around the existing implementation
  parvi_audio_backend_gst.erl    native-host control adapter
  parvi_audio_backend_ravenna.erl optional evaluation adapter

src/Audio/engine/
  include/parvi_audio_engine.h   small native control/buffer contract
  ...                           only the host/backend code actually needed

src/Audio/adapters/<platform>/   existing platform bindings remain here
```

Do not create separate services for the registry, each heuristic, policy configuration or capabilities. Use a build-time backend allowlist and ordinary data structures. A locally registered `gen_server` is the intended resource-management pattern. [D1]

Start the provider when the node's audio capability service starts, without opening a microphone, speaker or network stream. The audio branch may retain its existing lazy startup where necessary during migration.

### 4.2 Provider operations

These are proposed API responsibilities, not implementations to paste blindly:

```erlang
capabilities() -> Snapshot.
plan(SubscriptionIntent) -> {ok, Plan, Explanation} | {error, Rejections}.
apply(PlanId, ExpectedRevision) -> accepted | {error, Reason}.
stop(SessionId) -> ok | {error, Reason}.
status(SessionId) -> Status.
explain(PlanId) -> Explanation.
```

Reuse existing publication and subscription APIs where possible. `plan` has no side effects; `apply` starts bounded asynchronous work and returns a request/session identifier in the concrete implementation. Do not block the provider's mailbox on device opening, network negotiation or remote calls.

Backend control responsibilities are `probe`, `prepare`, `activate`, `stop`, `status`, plus optional `update_filter` and `update_limits`. Report unsupported operations explicitly. Use asynchronous events for completion and failure.

### 4.3 Runtime ownership

The existing subscription worker owns its backend session. Native handles are opaque, local and associated with an owner, session ID and generation. They are not persisted or transmitted to peers.

Owner death, provider restart, aborted setup and peer revocation must release native resources. Closing playback alone must remain distinct from closing a subscription. Idempotent stop/abort operations must not resurrect audio.

The legacy backend may still carry samples through Erlang. The completed native backend must not send audio payloads, per-packet decisions or per-sample meters through the provider or UI bridge. Report bounded summaries instead.

## 5. Capabilities, intent and the negotiated plan

Keep these three data structures separate. Capabilities say what is possible; intent says what is wanted; a plan says exactly what has been agreed.

### Capability snapshot

Include a schema version, node boot/session identity, revision and relevant route identity. Capabilities can be supported, unavailable, unknown or measured; never treat unknown as confirmed support.

Report:

- Backend availability, send/receive roles and complete wire-profile support.
- Valid format combinations: encoding, sample type, container bits, valid bits when known, sample rate, channels and layout. Do not advertise an arbitrary Cartesian product of independent ranges.
- Current device route, actual OS format, buffer constraints, reported latency and timing information.
- Clock domains, synchronization methods, uncertainty and drift-control capabilities.
- Supported sender/local selectors, recovery mechanisms and their applicable limits.
- Available processing operations, their location and any known resource/latency constraints.
- Media encryption/authentication and addressability requirements, including whether a profile is LAN-only.

Keep requested OS preferences separate from actual negotiated OS settings. Do not guess a DAC's effective precision from a 32-bit application buffer. Apple's preferred settings are requests; query the active result. [D2]

### Subscription intent

Include the source, destination role, selector, optional sync group, required properties, preferred properties and named policy. Separate:

**Hard requirements:** authorized peers; supported channel layout; required media security; allowed conversions; latency ceiling; synchronization requirement; failure/concealment behavior.

**Preferences:** PCM versus another allowed encoding; desired precision; preferred sample rate; energy or bandwidth economy; preferred backend; target latency below the ceiling.

A request must distinguish:

- `transport_sample_exact`: no lossy encoding of the negotiated transmitted samples.
- `preserve_source_samples`: no irreversible modification of the source samples.
- `bit_exact_device_output`: a stronger device-path constraint that may be incompatible with mixing or clock-drift resampling.

None means that an arbitrary network can guarantee zero missing audio at a finite deadline. Recovery performance is reported separately.

### Media plan

Record both endpoints' capability revisions, source/descriptor revision, plan ID/revision, chosen wire profile, local backend at each end, four distinct formats, conversions, selector location, recovery settings, security, timing budget, clock mapping, buffer bounds and activation boundary.

The four formats are **source**, **wire**, **processing** and **device** formats. Do not collapse them into one `bit_depth` field.

Only define fields needed by an implemented backend. Unsupported future properties must not become mandatory protocol baggage.

## 6. Named selection heuristics

Call the overall procedure **Best-Fit Negotiation**. It is deterministic, rule-based selection, not machine learning and not a promise of a globally optimal configuration.

| Rule name | Code identifier | Decision |
|---|---|---|
| **Compatibility Gate** | `compatibility_gate` | Reject unauthorized, unavailable or incompatible endpoint/profile combinations. Match wire contracts, not backend names. |
| **Evidence Gate** | `evidence_gate` | Never claim unmeasured precision, recovery or hardware acceleration. Strict requirements need sufficient evidence; experimental operation must be explicit. |
| **Source Fidelity** | `source_fidelity` | Preserve useful source information and avoid unnecessary transformations. Padding does not increase source precision. |
| **Receiver Fit** | `receiver_fit` | Consider the actual subscribers and their output/recording needs, not every device in the cluster. |
| **Deadline Fit** | `deadline_fit` | Fit capture, network/recovery, processing and output lead time into the agreed end-to-end budget. |
| **Clock Fit** | `clock_fit` | Require compatible timelines and an implementable drift/synchronization plan. |
| **Resource Economy** | `resource_economy` | Prefer lower measured/estimated bandwidth, CPU, memory and energy cost among otherwise suitable plans. |
| **Stability Guard** | `stability_guard` | Keep a valid active plan unless a relevant change or explicit optimization warrants replacing it. |

Store stable reason identifiers in the explanation, such as `no_common_wire_profile`, `conversion_not_authorized`, `clock_quality_unknown`, `latency_budget_exceeded`, `backend_not_bundled` and `active_plan_retained`.

### 6.1 Selection policies

Implement three named policies with transparent lexicographic ordering, not unexplained weighted scores:

| Policy | Ordering after hard requirements |
|---|---|
| `fidelity_first` | Least irreversible signal change; strongest demonstrated recovery within the budget; fewer conversions; lower resource cost. |
| `latency_first` | Lowest supported end-to-end delay within mandatory fidelity/security/sync constraints; then demonstrated robustness and resource cost. |
| `economy_first` | Lowest configured resource cost among explicitly allowed formats and quality levels; then fewer conversions and demonstrated robustness. |

`fidelity_first` is the default. Backend pinning is a diagnostic override, not a fourth quality policy. A pin does not bypass requirements.

Within equivalent candidates, prefer the active plan, then use a stable profile/backend identifier as the final tie-break. Define the finite candidate set from advertised valid profiles; do not build a generic optimization language.

If measurements are missing, use labelled estimates for soft ranking only. Do not invent comparable CPU/energy scores for engines that have never been measured. Select using the known dimensions and record the uncertainty.

### 6.2 Algorithm

1. Obtain current source, participating peer, local device and sync-group snapshots.
2. Enumerate mutually supported wire profiles and valid format tuples, including only authorized conversion paths.
3. Apply hard constraints and record every rejection.
4. Rank survivors using the selected policy and named rules.
5. Retain a still-valid active plan unless the change is explicitly required or approved.
6. Return the selected plan, alternatives and explanation. No survivor means a precise incompatibility result, not a silent downgrade.

At startup, discover and rank local defaults only. Run subscription negotiation once the peer's capabilities are known. Reconsider only affected subscriptions on route/source/capability changes, persistent deadline failures, explicit policy changes or reconnection. Do not replan the cluster for every packet or every unrelated join.

### 6.3 Quality decisions required by this design

| Scenario | Required behavior |
|---|---|
| Unprocessed 16-bit source; only suitable 16-bit delivery needed | Prefer 16-bit wire samples over padding them to 24-bit. A float device buffer may still be appropriate. |
| 24-bit source; 24-bit recorder plus 16-bit speaker | Keep the recorder's required precision. Convert the speaker branch only when permitted; choose source-side or local conversion according to actual cost and needs. |
| Only 16-bit playback subscribers, but 24-bit input | A 16-bit wire variant is eligible only if reducing source precision is permitted. Their presence does not override source-preservation requirements. |
| 16-bit input followed by mixing/EQ | Processing may generate values needing higher precision; do not force intermediates or processed network output back to 16-bit. |
| Receiver supports PCM float32 only at its API | Distinguish API representation from physical precision; negotiate an explicit conversion rather than inferring a 32-bit DAC. |
| A weak unrelated device joins the cluster | Existing streams remain unchanged. |

Do not silently quantize float32 capture to PCM24 because a chosen RTP payload happens to require integers. Log any deliberate quantization/resampling, and apply the agreed dither policy at intentional precision reduction, not repeatedly at every layer.

## 7. Endpoint negotiation and native handoff

Reuse `parvi_audio_subscription` for the state machine. Extend it rather than creating a second competing session manager.

```text
requested -> negotiating -> preparing -> ready -> active -> stopping -> closed
                    \---------- failure / abort --------------------/
```

The subscription initiator proposes a concrete plan. Each endpoint validates it against its own permissions, actual capabilities and available resources. Both must acknowledge the same wire/timing plan; neither endpoint can dictate unsupported settings to the other.

Use session IDs, plan revisions and local backend generations to reject stale replies. Prepare resources on both ends before activation. A bounded setup timeout or changed route aborts and cleans up both sides. This is a lightweight session handshake, not a new distributed transaction framework.

Once actual OS settings are known, revalidate the plan. A changed sample rate or latency cannot be hidden behind the original advertised preference. Native errors become explicit provider events.

For synchronized playback, agree on a future start boundary and prebuffer before rendering. For a backend that cannot switch seamlessly, report a controlled interruption and rebuffer; do not claim gapless switching.

Initial native deployment may use the existing local control bridge. Audio buffers must stay between native components: use an in-process buffer API where possible, or bounded IPC/shared memory for genuinely separate processes. Do not route PCM through Erlang merely to connect two native pieces.

The native engine may adapt its buffer/recovery behavior **within the limits in the approved plan**. Changing wire format, security, transport or the group's presentation delay requires Erlang renegotiation.

## 8. Prototype backend definitions

### A. `legacy_webrtc`

Wrap the current implementation without changing its default behavior. Advertise the existing Parvi PCM/WebRTC profile, supported channel/point selectors and actual formats. Mark native payload bypass as false and recovery capabilities honestly: the current media channel disables retransmission. [R4]

This is a baseline, not a claim that the present path already meets high-fidelity recovery requirements. An explicit experimental intent can use it; a strict intent it cannot meet must be rejected.

### B. `gstreamer_rtp`

Use GStreamer's native pipeline and RTP components rather than reimplementing reordering or retransmission. `rtpbin` includes jitter-buffer integration; retransmission requires a connected feedback/retransmission path, not just setting one property. [D3, D4]

Prototype order:

1. Native sender/receiver fixture on a controlled LAN, using standard PCM L16 and L24 profiles with appropriate test inputs.
2. Wire RTCP feedback and sender packet history into the receiver's retransmission requests; demonstrate recovery under a defined impairment profile.
3. Bind the native path to Mac capture and iOS output, preserving the existing application controls.
4. Add one explicitly selected FEC scheme only after retransmission works, if the benchmark requires it. Record its exact wire profile and recovery envelope.

**Format gate:** L24 is integer PCM, not a transparent carrier for arbitrary float32 samples. Prefer a standard lossless-preserving payload when one matches. For the existing float capture, either explicitly authorize a conversion or evaluate GStreamer's generic `X-GST` payload as a separately named experimental profile. `X-GST` has its own clock rate and is not AES67 or a universal audio interchange format. Verify buffer/timestamp preservation before advertising it. Do not invent a new generic PCM protocol merely to complete this milestone. [D5, D6]

Use a bounded native appsink/appsrc bridge if retaining the existing platform I/O. Assign one scheduling owner: avoid an appsink that waits until presentation time before giving the device adapter a buffer that needed to be submitted earlier. Account explicitly for pipeline clock, buffering and downstream device latency. [D7]

Start with direct LAN connectivity. Existing ExWebRTC control connectivity does not imply native UDP connectivity through NAT. Do not claim WAN, cellular or automatic ICE/TURN integration until implemented and tested.

Media authentication/encryption must be explicit. Either configure a verified secure RTP profile with authenticated control-plane key exchange, or restrict the initial unencrypted profile to an explicitly selected isolated-lab mode. Never silently downgrade from encrypted WebRTC media.

### C. `ravennakit_aes67`

Implement a separate optional macOS evaluation build. The upstream SDK lists macOS, Windows and Linux, AGPLv3/commercial licensing, and a virtual PTP follower. Do not advertise iOS support or PTP-grandmaster capability based on those claims. [R10]

Require an available suitable PTP reference and a deliberately configured professional LAN. Demonstrate channel PCM transmission/reception under the selected AES67 profile and documented clock conditions. A mock backend or a library that merely links does not satisfy this milestone.

RTP support in GStreamer alone is not proof of AES67 interoperability. Claim cross-backend compatibility only after matching payload, channel order, packetization, SDP, clock/PTP profile, presentation behavior and other required parameters, followed by a real check.

Do not insert private spatial extensions into a supposedly standard AES67 stream. Advertise unsupported object metadata and recovery/security modes as unsupported. Redundant network paths, if used, are distinct from single-path FEC or retransmission.

Keep this backend out of default distributable builds until the licensing decision is recorded. If it is unavailable, report a two-backend prototype and the outstanding gate, not a completed third backend.

### Build and licensing discipline

Pin exact library versions and dependencies when implementing; include notices and the bundled-plugin list. GStreamer supports iOS packaging, but platform packaging is not proof that every selected element is present. Check the exact build and applicable linking obligations. Do not change the repository's license automatically. [D8, D9]

## 9. Device, buffering and clock contracts

### Device boundary

The platform adapter provides actual capture/render format, frame count and sample position, local host timestamps, route changes, buffer requirements, latency reports and failure notifications. Optional functions such as mixing, conversion or hardware offload are advertised only when usable on that route.

Do not assume OS processing means chip acceleration. Do not enable voice processing, automatic gain control, noise suppression or spatialization on a fidelity path without policy authorization.

Real-time callbacks must not wait on Erlang, network I/O or UI work. Use bounded buffers and appropriate native scheduling; report underruns/overruns rather than concealing unbounded queue growth.

### Timing

Use one logical clock policy/reference per sync domain, with a local mapping/clock agent at every participating device. The first prototype uses an explicitly designated reference rather than inventing automatic singleton election.

The coordinator chooses the reference and allowed uncertainty. Each local implementation maps the session timeline to host and audio sample clocks. RAVENNAKIT may follow an external PTP source while a different backend uses another supported domain; do not pretend those domains are identical without a defined mapping.

Document timestamp units, epoch, reference identity, revision, mapping uncertainty and sample-clock rate estimate. Distinguish RTP sample ticks, local monotonic time and external time. Nanosecond units do not imply nanosecond accuracy.

The existing SNTP mapping is a starting point, not a sample-accurate speaker-alignment result. Do not pass abrupt wall-clock corrections directly into the playback schedule. One designated native component owns drift correction or resampling. Another resampler must not independently chase the same drift.

A sync group shares its presentation schedule. If one receiver needs more buffering, either fit it within the existing shared deadline, renegotiate the group at an agreed boundary, or reject/remove that receiver. It must not silently play later than the rest.

A coordinator loss does not trigger competing automatic leaders in v1. Use a declared bounded holdover only when clock quality supports it; otherwise stop admitting precise-sync streams and report sync loss. Automated failover is later work.

### Reliability

Track transport loss, late delivery, capture loss and output underruns separately. FEC/retransmission recover only within their tested conditions and available deadline. Concealment is not exact recovery.

Define what happens when recovery fails: controlled stop, silence-with-error, or explicitly permitted concealment. All are visible errors/degradations; none is counted as recovered original audio. Never label a finite-latency path universally lossless.

## 10. Spatial filtering without unnecessary payload delivery

Preserve three distinct options: sender-side selection, receiver-side selection, and sender selection followed by additional local filtering.

Erlang installs the selector; the media path evaluates packet/block metadata. Reuse the existing channel and sphere semantics, including coordinate frame and units. An update has a revision and effective boundary so peers cannot apply mismatched selectors unnoticed.

For native engines, filtering and rendering are separate capabilities. Knowing XYZ does not make a backend a spatial renderer.

Filtering at the receiver cannot undo network traffic already delivered. To save bandwidth, filter before transmission or at an upstream relay. A shared multicast packet cannot simultaneously have a different payload for every receiver; per-receiver selection needs appropriate separate delivery groups or unicast paths.

Intentional filtering must not appear as network loss. For per-subscription unicast, select before assigning delivery sequence numbers. Receiver-only discard counters remain separate from transport-loss counters. Recovery must not retransmit deliberately unselected audio.

The first native backend may initially advertise channel-only support. Preserve point selection in the legacy backend; add native point metadata only as a separately versioned, tested profile. Do not postpone the entire provider abstraction to implement spatial rendering.

## 11. Reconfiguration, restoration and observability

### Reconfiguration

On a relevant route/capability change, increment its revision and identify affected plans. Keep valid sessions running. Replan only those that need it. Native refusal or unexpected actual settings cause an explicit failure/reproposal, never silent fallback.

For v1, prefer manual backend switching plus event-triggered replanning. Continuous metric-driven backend switching and elaborate hysteresis are deferred. Bounded native jitter/recovery adaptation may still operate inside the existing plan.

### Desired-state restoration: later milestone

Persist a versioned declarative record: logical device/source IDs, subscriptions, selectors, policy, permitted conversions and user settings. Do not persist live PIDs, native handles, sockets, RTP replay state or a VM memory dump. Credentials use platform-appropriate secure storage and are not diagnostic fields.

On return: authenticate, rediscover sources, refresh capabilities, reacquire clock mapping, renegotiate and create new media endpoints. Admission revocation overrides stored intent. Live audio resumes at an explicit current/future boundary; missed live audio is not replayed unless a separate recording/replay feature exists.

A lightweight server may store desired state, but is optional and does not become a required audio relay. iOS lifecycle/background restrictions remain real; state restoration is not permission for indefinite background execution.

### Required diagnostic snapshot

Expose the selected backend and wire profile, four formats, policy, rule-based reasons, rejected alternatives, clock quality, planned/actual latency and health counters. Summaries must be bounded and contain no PCM or credentials.

Counters should distinguish captured frames/drops, selected/filtered blocks, transmitted/received packets, outstanding/recovered gaps, final unrecovered data, duplicates/reordering, late drops, queue depth, device underruns and restarts. Mark unavailable measurements as unknown. The current gap counter is not a final-loss measurement because late packets are tracked separately. [R3]

Provide `explain` output that can answer, for example:

```text
Selected: gstreamer_rtp / <negotiated-profile>
Policy: fidelity_first
Reason: compatible endpoints; source preserved; deadline fits
Kept wire precision: source needs it for the recording subscriber
Rejected alternative: required clock evidence unavailable
Conversions: one documented device-layout conversion
Unknown: physical speaker alignment has not been measured
```

This example is illustrative, not a measured result.

## 12. Staged implementation and exit criteria

Implement one small, reviewable milestone at a time. Preserve unrelated work. Do not rename the project, rebuild the cluster layer or remove the baseline as part of this plan.

### Milestone 0 - Align the plan

Read current instructions and source, compare with the reviewed commit, and record the architecture decision plus any narrow instruction amendments. Update `docs/PLAN.md` with the new sequence. Identify library build/licensing gates. Do not modify the Reception Desk.

**Exit:** source changes required by this plan and scope conflicts are explicit; no unsupported feature is described as implemented.

### Milestone 1 - Provider with legacy backend

Introduce the provider, backend behaviour and build-time allowlist. Wrap existing WebRTC setup and status; preserve the packet/data path. Reuse the current supervisor and subscription lifecycle. Add a minimal snapshot showing the selected backend and legacy limitations.

**Exit:** existing Mac-to-iPhone behavior remains reachable through the stable provider; provider/owner failure cleans up; no new media dependency is required.

### Milestone 2 - Best-Fit Negotiation

Add capability/intent/plan records and pure policy functions. Use real legacy capabilities and clearly labelled fixtures for unavailable backends. Add explanations and capability revision checks to subscription setup. Implement prepare/activate/abort semantics only to the extent needed by actual backends.

**Exit:** the quality and compatibility examples in section 6 have deterministic outcomes; impossible requests are rejected; unknown capabilities are not treated as support.

### Milestone 3 - GStreamer desktop media proof

Build the isolated native backend and a bounded control/buffer interface. Exercise L16/L24 with suitable fixtures, reordering and retransmission. Record format, timing, security and connectivity limits. Compare loss accounting and resource usage with the baseline under the same test conditions.

**Exit:** actual packets and recovered sample data are verified; setting a property or compiling a library is not counted as recovery proof.

### Milestone 4 - Native Mac-to-iPhone path

Integrate the backend with Mac capture and the iOS native engine host/output binding. Resolve float-capture transport explicitly. Keep controls in Erlang and reuse Swift UI. Demonstrate that native-stream payloads bypass Erlang and that backend switching does not require a new application architecture.

**Exit:** source discovery, negotiated native delivery, audible output, stop and route-change handling work on actual devices when those runs are authorized. Report measured and unmeasured timing separately.

### Milestone 5 - Clock and filtering consequences

Make timing ownership explicit; add the first bounded drift-control path and sync-group coordination. Compare two outputs with a suitable acoustic/electrical measurement, not only submitted-buffer counters. Implement native selector support only for an explicitly defined metadata profile.

**Exit:** claimed alignment and filtering behavior have reproducible evidence; a filter change does not create fake transport loss; deadline-incompatible routes fail visibly.

### Milestone 6 - RAVENNAKIT evaluation

Add the gated macOS backend, obtain a suitable clock/network setup and exercise a real AES67 stream. Test the provider with its different requirements. Evaluate GStreamer interoperability only against a fully matching profile.

**Exit:** three real backends are demonstrated, or the exact outstanding RAVENNAKIT gate is recorded and the prototype remains labelled two-backend. Do not fake completion with fixture capabilities.

### Milestone 7 - Restore desired state

Add persistent identity/intent as a separate change, preserving existing trust boundaries. Recreate sessions after restart using fresh handles, authentication and timing. Add server-assisted storage only if local restoration proves insufficient.

**Exit:** returning devices restore valid intent without reusing obsolete execution state or replaying missed live audio unexpectedly.

## 13. Focused acceptance cases

Use these as the bounded test specification. Follow repository approval rules before adding automated suites or running hardware/deployment tests. Reuse existing test facilities and add only relevant cases.

| Case | Expected result |
|---|---|
| Legacy smoke path | Current subscription/playback/stop behavior preserved. |
| 16-bit source and suitable receiver | No needless wire upconversion; processing/device representation may differ. |
| Mixed 16/24-bit subscribers | Recorder precision retained; only authorized branch conversion. |
| Unknown physical precision | No fabricated bit-depth/quality claim. |
| Different backend names, identical validated wire profile | Candidate allowed; implementation names alone do not reject it. |
| Same backend name, incompatible profile/security/clock | Candidate rejected with a specific reason. |
| Native backend absent from build | Never selected; existing backend still usable when requirements permit. |
| Strict preservation with float32 source and integer-only payload | Reject unless a reversible path exists or conversion is explicitly authorized. |
| Route changes during prepare | Stale plan rejected; partially opened resources released. |
| Provider/owner dies | No orphan playback or resurrection of obsolete sessions. |
| Controlled loss/reorder | Exact recovery verified within the specified test envelope; recovered/late/unrecovered totals are distinct. |
| Sender selector excludes blocks | Payload not sent to that subscription; exclusion is not reported as packet loss. |
| Local selector excludes blocks | Delivery bandwidth remains accounted for; local discard is separate. |
| Different output delays in one sync group | Shared presentation time retained or incompatibility reported. |
| Clock quality disappears | Declared holdover or visible sync failure; no false precise-sync status. |
| Unrelated node joins/leaves | No restart or quality downgrade of unaffected sessions. |
| Restored subscription was revoked | Restoration refused regardless of saved settings. |

For every benchmark record source format, wire format, conversion chain, hardware/routes, backend versions, network/impairment settings, latency budget, duration, CPU/memory observations and missing/recovered frames. Compare transport sample identity before permitted rendering conversions; assess device alignment separately. Do not compare unlike quality/latency configurations and call the difference a backend speedup.

## 14. Codex reporting and first task

For each milestone report only the files changed, behavior implemented, checks actually performed, known limits and next smallest step. Distinguish source edits, compilation, automated tests, real-device execution and measured performance.

Do not commit, push, deploy, install on devices, purchase a license or change the running service unless separately requested. Keep generated dependencies/artifacts under `builds/` and update `docs/PROGRESS.md` with honest validation limits.

**Suggested first instruction to Codex:**

> Read this specification and the repository instructions. Implement Milestone 1 after reconciling the architecture decision in Milestone 0. Preserve the existing working media path. Do not add GStreamer or RAVENNAKIT yet. Add the smallest local provider/backend boundary needed for later negotiation; retain existing ownership and cleanup. Follow the repository's approval rules for tests, builds and deployment, and report exactly what was and was not verified.

## 15. Source manifest

Repository observations were checked against the baseline identified above. Library documentation was consulted on 2026-11-01. Re-check exact versions and capabilities when implementing. Normative design choices in this document are proposals, not claims made by the referenced libraries.

```text
R0  Reviewed OpenSound commit
    https://github.com/thxmuffe/OpenSound/commit/eeb173a38aa013ed88c17dce86fb257392040b23
R1  Repository instructions
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/AGENTS.md
R2  Current development plan
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/docs/PLAN.md
R3  Subscription state machine and packet selection
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/Audio/src/parvi_audio_subscription.erl
R4  Current WebRTC media channel
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/control/src/parvi_media_channel.erl
R5  Current output conversion and scheduling
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/Audio/src/parvi_audio_output.erl
R6  Existing audio supervisor
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/Audio/src/parvi_audio_sup.erl
R7  iOS native output adapter
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/Audio/adapters/iOS/IOSAudioOutput.swift
R8  Current input policy
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/Audio/src/parvi_audio_input.erl
R9  Current clock service
    https://github.com/thxmuffe/OpenSound/blob/eeb173a38aa013ed88c17dce86fb257392040b23/src/control/src/parvi_clock.erl
R10 RAVENNAKIT README: scope, PTP follower and licensing
    https://github.com/soundondigital/ravennakit/blob/main/README.md
D1  Erlang gen_server concepts
    https://www.erlang.org/doc/system/gen_server_concepts.html
D2  Apple: configuring device hardware and checking actual settings
    https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/OptimizingForDeviceHardware/OptimizingForDeviceHardware.html
D3  GStreamer rtpbin
    https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpbin.html
D4  GStreamer retransmission receiver and feedback integration
    https://gstreamer.freedesktop.org/documentation/rtpmanager/rtprtxreceive.html
D5  GStreamer L24 RTP payload format
    https://gstreamer.freedesktop.org/documentation/rtp/rtpL24pay.html
D6  GStreamer generic X-GST RTP payload
    https://gstreamer.freedesktop.org/documentation/rtp/rtpgstpay.html
D7  GStreamer appsink
    https://gstreamer.freedesktop.org/documentation/app/appsink.html
D8  GStreamer iOS development packaging
    https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html
D9  GStreamer deployment and static-linking considerations
    https://gstreamer.freedesktop.org/documentation/deploying/index.html
```
