# Development plan

## Accepted direction — secure Swarm architecture (2026-11-08)

This is the **next architecture roadmap** for BEAM Audio. It supersedes the older
trusted-cross-device-OTP-cluster design as the *target architecture*. Reuse useful
Mac/iPhone and Windows code without preserving old architecture solely for
compatibility. Superseded plans and exploratory proposals are preserved in
[old-ideas/](old-ideas/README.md), while current non-active topics are classified
under [discarded-ideas/](discarded-ideas/README.md) and
[possibly-useful/](possibly-useful/README.md). Build in small independently
verifiable increments; do not attempt a large-scale network optimization in
this phase.

### Reading order and status

This file is the single active implementation roadmap. Repository instructions
remain binding; design contracts and decisions explain interfaces, component
READMEs describe usage, and [PROGRESS.md](PROGRESS.md) records dated evidence
and validation limits. None of their older “next” instructions adds another
implementation sequence. If an existing contract conflicts with this target,
record and resolve it in step 1 before changing the affected runtime behavior.

**Ephemeral Swarms (step 9) are implemented and verified in the headless core.
Contacts/groups and Device Identity survive; gatherings and their runtime state
do not. Former abandoned-Swarm recovery is superseded. Next is step 10:
application acceptance (macOS → iOS → Windows); Mac and iOS implementations
are built for user testing. The earlier 8d maximum-Offset
continuity limitation remains open; this lifecycle work does not resolve it.** See
[canonical component names](TERMINOLOGY.md) and [API/configuration migration](NAMING.md). The
[boundary contract and code migration map](SWARM_CONTRACT.md) specifies identity,
authorization, ownership, local APIs and independent lifecycles. The opt-in
`swarm_control` runtime now provides signed, bounded status messaging through the
existing Desk without Distributed Erlang. The [local Handler/test Worker
lifecycle](DEVICE_HANDLER.md) and authenticated capability reads are implemented.
The [Contract/job proof](SWARM_JOBS.md) now covers a designated Director's offer,
local acceptance, completion/retry, cancellation/expiry and bounded failure cleanup.
The [Passport/rejoin and multi-Desk proof](SWARM_MEMBERSHIP.md) now adds durable
membership, current authority permissions and revocation. Local checks, the real
two-runtime WSS job proof and the two-service loopback Desk proof pass. This is
not arbitrary remote execution or app migration:
existing app bundles still use the older trusted OTP control path.
Mac-to-iPhone playback and retained subscription intent have user-reported
working evidence. The old single receive slot is replaced on the headless path by [independent PCM
subscriptions and mixing](SWARM_STREAMS.md). Native Opus decoded-audio handoff now
feeds that same mixer through the authenticated stream boundary. Sustained PCM,
full-range virtual buffering and clock/capture recovery checks pass; see the
[repeatable backend checks and limits](../tests/control/README.md).
Windows per-packet schedule execution and physical output alignment remain unverified/incomplete.
Migration may temporarily break apps, connections and playback; the user accepts
this. Do not add a parallel legacy stack or compatibility shims just to keep the
system working between steps. Preserve stored identity and the per-packet timing
contract; gain and Music settings are outside this architecture change.
Old version-1 Swarm/membership/Desk/subscription records are intentionally ignored
by new builds; identity keys remain separate and unchanged. No existing app was
launched, rebuilt or installed to perform that reset.

### Vocabulary and ownership

Use the 22 component names and boundaries in [TERMINOLOGY.md](TERMINOLOGY.md).
Under the **Ephemeral Swarms** model:
- A **Swarm** is temporary; its creator is Captain for its lifetime. When the
  gathering ends, the Swarm disappears.
- **Contacts and groups** belong to Devices (like a phone's address book).
  No mutual friendship, approval or synchronization is required.
- A **Source** has a stable identity, a **Stream** is its audio
  publication, a **Subscription** is persistent intent to receive that Source, and
  a **Media Session** is a temporary transport. The **Swarm Clock** owns the shared
  timeline and **Playback Offset** policy; Audio Engines execute approved
  Presentation Targets. Device Identity and Passport are separate credentials.

Core-owned names use `ba_`, application `ba_core` and configuration `BA_*`;
[NAMING.md](NAMING.md) records the migration and retained identity/wire spellings.
Use **BEAM Audio** for the core and **OpenSound App** for the commercial UI.
Trusted Distributed Erlang terminology belongs only to explicitly historical
trusted-cluster code; it is not the current Swarm boundary.

### Implementation sequence — approved order

1. **Specify boundaries and contracts.** Write down the vocabulary, identity,
   message authorization, state ownership, Device Handler/Worker API, and
   membership/session/job/subscription lifecycles. Distinguish policy from
   observations of connectivity. Identify existing trusted-OTP dependencies.
   **Exit:** a small design contract and migration map grounded in current code.

2. **Secure Swarm messaging, before jobs or new workers.** Extend the existing
   authenticated Desk/WebRTC control path to carry versioned, allowlisted
   messages with sender authentication, replay protection, size bounds and
   per-operation authorization. No arbitrary OTP RPC, executable terms,
   remote process spawn or shared Erlang cookie across untrusted Devices.
   Keep distributed Erlang only inside explicitly fully trusted deployments.
   **Exit:** two independent runtimes exchange approved commands; a forbidden
   command, forged sender and stale replay are rejected without remote execution.

3. **Device Handlers and Workers.** Introduce a device-local OTP supervisor
   hierarchy and Handler; advertise capabilities and their limitations. Workers
   own their local source, sink, stream and DSP tasks; the Handler alone decides
   when to create, stop or restart its workers, including on local user consent.
   Reuse existing audio supervisor/session processes where practical.
   **Exit:** remote requests cannot directly spawn workers; local lifecycle and
   worker-crash recovery are demonstrated.

4. **Contracts and Jobs.** Implement Director job advertisements, Device Handler
   evaluation/acceptance, minimal job IDs, ownership, acknowledgements, lease or
   expiry, cancellation and idempotent retry. Publishing audio can request a
   Swarm job to maintain subscriptions, but receivers accept according to their
   Contracts; no blanket authority over microphones or speaker output.
   **Exit:** a Director offers a non-audio test job, another Device's Handler
   accepts it, a Worker completes it, and an unauthorized job is rejected.

5. **Desks, Passports and rejoin.** Extend existing persistent Ed25519 device
   identity, stored membership and challenge/response. Separate durable Passport
   from ephemeral sessions and initial invitations; enforce revocation/epoch
   updates on return. Make several ephemeral Desks introduce devices to the
   *same* Swarm, with explicit cross-desk discovery/routing or introduction;
   merely starting isolated replicas does not suffice.
   **Exit:** two Desks admit/reconnect devices to one Swarm; a previously admitted
   device rejoins without a new invitation, while a revoked device cannot.
   **Complete:** [membership implementation and limits](SWARM_MEMBERSHIP.md);
   two independent temporary Desk services share one durable authority and route
   devices across Desks. Authority/member restarts and revoked return are verified.

6. **Independent Streams and Subscriptions.** Refactor the current receiver's
   **single** receive slot and stored intent into a collection keyed by
   publisher/source identity. Support multiple simultaneous audio sources,
   independent lifecycle and pause/resume, subscriptions surviving source pause,
   and local mixing with bounded gain/limiting. Keep subscription identities
   independent of media transports and preserve the proven packet-target rule.
   **Exit:** two sources play together on one receiver; either can pause, resume,
   unsubscribe or disappear without disturbing the other.
   **Implemented for PCM:** [collection, scoped WebRTC control and mixer](SWARM_STREAMS.md).
   A real two-publisher media proof uses a test clock/sink, including receiver
   restart without restored Contracts. Concurrent output requires one common rate
   and clock; incompatible output is explicit and does not remove its subscription.
   Step 8 subsequently integrates native Opus decoded-audio handoff into this mixer;
   native platform output remains step 10.

7. **Time and Playback Offset over Swarm control.** Adapt clock discovery,
   sampling and policy updates that currently depend on `pg`, `erpc` or
   fully trusted OTP peers to the restricted Swarm messaging boundary. Preserve
   UTC-referenced per-packet broadcaster-assigned targets, real deadline execution,
   explicit failures, and clock quality diagnostics. Distribute revisioned
   Playback Offset updates from any authorized device, without divergent local
   overrides. **Exit:** devices share an authenticated timeline/Offset setting,
   recover after reconnect, and reject stale/unauthorized updates; separate
   software scheduling from physical-speaker alignment claims.
   **Implemented:** [Time/Offset](SWARM_TIME.md), retaining existing timestamp
   measurement, median and slew policy. Two-Desk authority/reconnect checks and
   real WebRTC PCM with production capture stamping pass using a headless output
   sink. Step 8 subsequently verifies sustained buffering, capture recovery and
   production-cadence acquisition across control-session renewal. Native platform
   output qualification remains step 10.

8. **Backend end-to-end verification and migration.** Run two-device/one-Desk and
   multi-Desk tests: join, retained membership, revoked Passport, Director/job
   failure, worker crash, reconnect, independent streams, pause/resume,
   clock/Offset updates and backend scheduling boundaries. Use headless runtimes;
   app launches and physical listening/output evidence belong to step 10.
   **Exit:** repeatable scripted backend checks, explicit platform/measurement
   limitations and no remaining dependency on the old cross-device
   Distributed Erlang control path. Obsolete pieces may be retired earlier when
   their replacements are verified; keeping old apps working is not a gate.
   **Complete for the headless backend:** [repeatable checks](../tests/control/README.md)
   cover real PCM/Opus mixing, continuous 1000 ms scheduling, full 30-second virtual
   buffering, clock-instance capture rebind, the actual 20 × 5-second clock window
   across session renewal and earlier membership/job/failure checks. Removed the
   obsolete remote-PID native session and retired the old PCM carrier. Installed
   app profiles and physical output are explicitly unqualified until step 10.

   **Approved backend follow-ups before step 9 — 8a–8c verified; 8d qualification open:**

   **8a. Isolate Desk failures.** Supervise each Desk connection independently,
   using established OTP supervision. A connection crash or disconnect must not
   restart membership, Device Handlers/Workers, control or the Swarm Clock, or
   reset sessions routed through healthy Desks. Remove both restart cascades and
   global disconnect handling; making the child supervisor `one_for_one` alone
   is insufficient. Bound failed-Desk recovery and scope availability changes to
   affected routes. Desk loss itself is not revocation; authorization freshness
   and expiry still apply. **Exit:** with two Desks and active work, disconnect
   and crash either connection; unaffected process/session identities and work
   survive, and the failed connection can recover independently.
   **Complete:** independent temporary relay Workers, bounded desired-connection
   reconciliation, isolated runtime supervision and alternate-Desk routing. The
   two-Desk proof preserves core/session/Worker identities through three relay
   crashes and one service crash, then recovers and continues rejoin/revocation.

   **8b. Make Contract installation idempotent.** Reinstalling the unchanged
   current Contract is a no-op. Preserve publications, Subscription intent,
   Media Sessions, Workers and queued audio. Changed permissions or removal
   invalidate only the affected work, where actually required; repeated updates
   must not create duplicate resources. **Exit:** repeated identical installation
   preserves live resource identities/buffers; actual permission withdrawal still
   stops the affected work without disturbing another Source.
   **Complete:** unchanged installs preserve resources/buffers; stale revisions
   of the same Contract are rejected. Continuous media proofs reinstall identical
   publisher/receiver Contracts every second without changing live identities.

   **8c. Make failures observable.** Count packet drops, mailbox overload,
   missing targets, missed deadlines and buffering/decoder failures by clear
   reason at the relevant Source/Media Session/Mixer boundary. Expose bounded
   counters and last-error details through existing scoped diagnostics; use
   rate-limited logs where useful, not a log entry per packet or a new monitoring
   framework. Signaling overload must produce a visible failed attempt rather
   than a silently stalled setup. **Exit:** deliberately exercise each supported
   failure path and observe its reason without unbounded diagnostic state or
   disclosure of credentials/audio payloads. UI presentation follows in step 10.
   **Complete:** bounded owner-local counters/last-error codes, per-transport
   diagnostics and explicit signaling-overload failure. Unit checks cover failure
   reasons, overload, expiry and PCM redaction; supervisor child arguments contain
   no private key. No new monitoring service or packet-by-packet logging was added.

   **8d. Renew authorization without interrupting eligible media.** Proactively
   renew control authorization and media permissions with fresh authenticated
   evidence. Separate credential/session renewal from Media Session lifetime;
   reauthorize eligible active work without rebuilding transports, clearing valid
   buffers, duplicating providers or changing packet Presentation Targets.
   Preserve replay protection, policy/Contract fencing, explicit revocation and
   expiry enforcement. No cached permission or timer alone extends authority;
   unsuccessful renewal must stop affected work at expiry. **Exit:** continuous
   two-Source playback across multiple renewal cycles, including default and
   maximum Playback Offset, retains eligible Media Sessions and original targets
   without renewal-induced gaps; withheld renewal and revocation still stop
   unauthorized playback and buffered output at the required boundary.
   **Implemented; continuity qualification remains open:** fresh nonce renewal
   retains session IDs/replay sequence, Media Sessions, decoders and buffered
   targets. Real two-source PCM passes 125 s at 1000 ms Offset with exact frame,
   full-sample and target accounting at production 60 s authorization lifetimes.
   Earlier 85 s/30000 ms runs passed, but repeat runs miss output deadlines despite
   stable identities and correct mixed samples. The latest run drops seven
   256-frame output blocks; no late output is submitted. Do not mark this exit
   complete until the maximum-Offset scheduling issue is understood and resolved.
   Clock sampling is explicitly accelerated in these fixtures. Withheld-proof
   and post-renewal revocation checks discard future audio; Opus lifecycle passes
   repeated renewal with accelerated leases. See [reproduction and limits](../tests/control/README.md).


   These are backend corrections, not new app UI or a new clock algorithm.
   Verification used isolated headless checks; no product app was launched.

9. **Implementation Step — Ephemeral Swarms.**
   Even simpler: no friends list. Just saved contacts and groups. Like a phone's
   address book. No mutual friendship, approval or synchronization required.

   1. **Create:** Every Swarm is new. Its creator is Captain for its lifetime.
   2. **Join:** Devices voluntarily join, subscribe and leave. Each controls its
      own permissions.
   3. **Remember:** A Device can save participants as contacts or a named group.
   4. **Invite:** Select contacts or a saved group and invite them into a new Swarm.
   5. **End:** When the gathering ends, the Swarm disappears. Contacts and groups remain.

   **Architecture:** Swarms are temporary; contacts and groups belong to Devices.
   No snapshots, elections, mutual friendship requirements or permanent Swarm membership.
   Use existing OTP components and keep the implementation minimal:
   - Device-local storage for contacts and groups (`ba_contacts`).
   - Ephemeral Swarm supervision tree lifecycle: initialized with a fresh random
     Swarm ID, creator as Captain/authority/Director for its lifetime, clean
     process teardown on end without persistent Swarm snapshots or durable
     registry.
   - Voluntary join, leave, subscribe under local Device Handler control.
   - Invitation dispatch to saved contacts or groups via Desk mailbox (or QR/URI).
   **Exit — verified:** the [core proof](../tests/control/README.md) uses saved-group
   invitation URIs, voluntary admission, real two-source PCM, leave/rejoin and
   Captain end. It checks full process/ETS/Desk teardown, contacts surviving cold
   restart, fresh creation IDs, and Captain crash followed by actual lease expiry.
   [Lifecycle/API details](SWARM_MEMBERSHIP.md). Contacts never grant permission;
   automatic unsolicited invitation delivery is outside this URI-based proof.

10. **Update and verify the applications — macOS, then iOS, then Windows.**
   **In progress:** the macOS implementation is compiled for user-led acceptance.
   [Current app behavior, native evaluation and limits](MACOS_APP.md). No app or
   hardware was launched by the agent. The iOS migration now also compiles for
   user-led acceptance: [current iPhone behavior and limits](OpenSound/iOS/README.md).
   It reuses the shared Swarm UI and Device Handler, with native mic/speaker and
   iOS 27 system-picker audio broadcast. Windows remains unmigrated. The CLI hardware test
   entry point below is planned, not implemented. Native mixing/RTP adoption and
   the earlier 8d maximum-Offset continuity qualification remain open.

   Integrate the new runtime and permission/state model into each app in that
   order, with the **same functionality, layout and information hierarchy on
   every platform**. Start with forgotten old Swarms/subscriptions rather than
   restoring them. Supporting platform code may change earlier when needed, but
   do not launch product apps during backend development: installed versions can
   auto-restore old connections/audio. Build/install/launch for this explicit phase.

   **macOS first — runtime and audio integration:** adopt the renamed `ba_*` /
   `BA_*` interfaces, secure Swarm runtime, local consent/Contracts and scoped
   chat/graph/diagnostic APIs. Begin the macOS audio work with a small combined
   evaluation of the two approved proposals below, before finalizing its Audio
   Engine boundary. This is part of macOS integration. iOS migration is now authorized;
   launches and hardware acceptance remain user-led. Do not make a speculative engine/format rewrite a condition
   for starting the app integration or polishing its common UI.

   **Native mixing evaluation:** keep mixing local to the receiving Device,
   preferably through an established Audio Engine/OS facility and existing
   approved backends. Erlang continues to own Swarm coordination, consent,
   Contracts, shared time and scheduling/correction policy; the engine executes
   approved targets. The production direction is native mixing rather than
   ordinary PCM sample processing in Erlang. Keep the Erlang Mixer as a reference
   and the current path until the candidate demonstrates relevant playback,
   independent-source behavior, timing, renewal and recovery evidence. Adopting
   it as the default requires recording that evidence and explicitly updating
   the existing Erlang-first processing guidance/architecture decision. Do not
   write a new native mixer or move unrelated DSP merely to complete this step.

   **RTP timing evaluation:** prototype standard RTP sampling timestamps plus a
   negotiated header extension carrying each packet's independent absolute
   Presentation Target. Evaluate it alongside native mixing so the macOS engine
   is not finalized against an untested timing boundary. Verify target precision
   and preservation through WebRTC, jitter buffering and decode, including loss,
   reordering, wrap and Playback Offset changes. Missing/unsupported targets must
   fail explicitly; neither arrival time nor neighbouring packets supplies one.
   Keep the current format until the isolated prototype justifies a documented,
   versioned adoption decision; add no speculative compatibility stack. Finer
   timestamp resolution alone is not evidence of better physical synchronization.

   **CLI hardware test entry point (approved follow-up):** add a command to the
   existing CLI that starts an ordinary Device Handler with explicit `--mic`,
   `--speaker` and `--broadcast` capability flags, using the same production OS
   adapters, consent, Contracts, scoped Jobs and clock/packet scheduling as apps.
   Support explicit new-Swarm creation or invitation joining, show real device /
   permission / clock / job failures and stop resources on exit. Do not restore
   old Swarms or start capture merely by opening the CLI; actual hardware use
   requires the selected flags and OS permission. Keep it a thin local command
   entry point, not a second runtime or media implementation. This is planned
   work for quick user-driven checks, not a hardware test run in this session.

   **macOS acceptance, then platform reuse:** complete and verify the common UI
   and real macOS capture/output below. Record native-mixing/RTP evaluation results
   and the selected interfaces before porting audio to iOS. The iOS implementation
   retains the current reference Mixer/packet targets and is now built; next run
   user-led Mac/iPhone acceptance, then update Windows. Preserve the same
   functionality and information hierarchy. An inconclusive prototype is recorded plainly and does not become
   an unverified production default.

   **Address book (Contacts & Groups):** show saved contacts and named groups.
   Allow adding contacts by Device ID or invite, organizing into groups, and
   starting a new Swarm by inviting contacts or a group. No friends list or mutual
   approval is shown.

   **Swarm:** show the current ephemeral Swarm name, ID, and Captain status.
   Allow ending (Captain) or leaving (participant) the gathering.

   **Graph:** show Device Handlers and their children; the master Swarm clock and
   the time it keeps; the Director with its jobs; and inspectors. Adapt the
   necessary scoped state/inspection APIs as part of this integration; do not
   expose arbitrary remote OTP inspection or execution to implement the graph.

   **Audio:** use three symbol toggle switches, with text labels as tooltips:
   speaker, microphone, and send audio to Swarm. Provide accessible text/help on
   platforms without hover while retaining the same controls and layout.
   Enabling **send audio to Swarm immediately starts broadcasting the default
   output**. Enabling microphone immediately starts its capture/publication;
   enabling speaker immediately starts receiving/playing eligible Swarm audio.
   Speaker may be enabled by default. These toggles are both permission and
   action: do not add separate Subscribe or Start/Stop Playback controls. Turning
   a toggle off stops its corresponding active work. Request required OS access
   at the point of action and report real failures/unavailable state; a permission
   flag alone is not a successful capture/playback start. Runtime subscriptions,
   Contracts and jobs remain internal bookkeeping behind the toggles. Place the
   shared **Swarm Offset** control here.

   **Device exclusions:** from either a device in the graph or its audio entry,
   let the user choose “Don't connect with this device” and later undo it. In
   general, accept/do authorized eligible jobs automatically according to the
   enabled capabilities, while allowing specific devices to be excluded. Persist
   exclusions locally per Swarm/device for that live gathering (retained through
   worker recovery, discarded at gathering end), prevent automatic connections/jobs/
   audio, and stop affected existing work without disturbing other devices.
   Exclusion is distinct from authority revocation or deleting membership. If
   excluding a required clock/authority removes availability, display that state
   rather than silently bypassing the exclusion or inventing another authority.

   **Chat:** retain its existing behavior and layout. Make Passport/membership
   details reachable here, for example through a small system entry/details view;
   **do not add a Passport tab**. Show membership identity/status/details rather
   than private signing keys or invitation secrets.

   **Exit:** all three apps expose this same layout and behavior, with immediate
   audio actions, automatic eligible work, scoped exclusions, visible clock/jobs/
   inspectors and reachable Passport details. App/device checks establish join/
   rejoin, authorized jobs, independent streams, pause/resume, clock/Offset,
   automatic eligible peer reconnection, sustained playback across control-session
   renewal at the chosen Offsets, and
   real listening/output-timing evidence. Record actual platform limitations;
   software tests alone do not qualify physical speaker alignment.

    **Former step 10 superseded:** Returning to an abandoned Swarm is removed.
    Swarms are temporary gatherings; when a gathering ends, the Swarm disappears.
    Contacts and groups remain on Devices.

### Scope constraints and immediate milestone

- Keep BEAM/OTP local for supervision and decisions; use authenticated,
  capability-limited messages at Device trust boundaries. A valid Passport does
  **not** automatically authorize active microphone, playback or job operations.
- Reuse existing WebRTC/Opus and GStreamer media engine boundaries and preserve
  per-packet playback timing. Working app behavior between steps is not required.
- Follow-ups 8a–8c are complete; 8d maximum-Offset continuity qualification
  remains open before app integration. Native mixing and RTP header-extension
  work are bounded evaluations during macOS audio integration; neither changes
  the accepted default or packet format without evidence and a recorded decision.
- Paused Streams retain logical subscriptions; idle transports may remain open
  for simplicity. Multiplexing, packet bundling, RabbitMQ, MQTT/EMQX, Redis,
  PostgreSQL, federation and large-scale routing are **not required** now.
- First integrated job proof (step 4, after the step-2 messaging proof):
  **Director advertises one job; a second Device Handler
  verifies/accepts it, starts a local Worker, and reports completion via secure
  Swarm messaging**. No audio-engine rewrite is needed for this proof.
  Implemented and verified in [step 4](SWARM_JOBS.md).

### Dependencies and migration boundaries

- Step 1 specifies the minimum identity, session and permission rules needed by
  step 2. Step 2 reuses existing Ed25519 identity and fresh challenge/response;
  the complete Passport/rejoin and multi-Desk behavior is implemented in step 5.
  Membership proof authenticates a relationship; it never grants all operations.
- Steps 2–4 establish a small proof between independent runtimes with no
  cross-device Distributed Erlang connection. No parallel compatibility path is
  required. Step 3 uses predefined local test
  workers; mentioning DSP Workers does not require a DSP engine or algorithm.
- Step 5 connects multiple Desks to **one** Swarm. Federation of different Swarms
  and automatic Director failover are outside this roadmap. A Desk introduces
  devices; membership/revocation policy belongs to the explicit Swarm authority
  defined in step 1, independently of where a Desk is hosted.
- Steps 6–8 implement the PCM/Opus collection, authenticated clock/Offset path,
  decoded-audio handoff, bounded sustained buffering and capture recovery.
  Product apps still require step-10 integration. The migration is not ready for untrusted devices while any required
  discovery, subscription, diagnostics, clock or
  policy operation still crosses a device boundary through OTP distribution.
  Temporary broken consumers do not justify granting untrusted OTP connectivity.
- Publisher pause retains subscriptions. Receiver pause retains its subscription
  while stopping local output; Unsubscribe removes that intent. Disappearance
  changes availability and releases live resources, without silently revoking
  membership or deleting subscription intent. Restored intent is reauthorized
  against current Contracts before any new playback session is enabled.
- Step 8 verifies the complete replacement and removal of legacy dependencies.
  Clock quality, software deadline execution and measured physical output timing
  remain separate evidence. No new numerical alignment guarantee is implied.

### Outside the ten steps

The [future ideas list](IDEAS.md) keeps longer-term possibilities separate from
this roadmap. Cinema/5.1, spatial rendering, DSP algorithms, acoustic calibration,
large-event scaling, new platforms, business tiers and new media backends do not
add prerequisites or extra steps here. Revisit them explicitly after the current
roadmap; preserve useful ideas without treating them as approved implementation.

Next: **step 10 — user-led macOS app acceptance**, including
the combined native-mixing/RTP timing evaluation. Finalize and verify the
macOS audio boundary before updating iOS, then Windows. No product app is launched
for the preparatory backend work. Preserve independent packet targets, stored
Device Identity and the common UI requirements; start updated apps with forgotten
old Swarms/subscriptions. Former abandoned-Swarm recovery is superseded by
ephemeral Swarms. Step 9 is verified; the earlier 8d maximum-Offset issue remains
open and must not be described as fixed. App/device
listening and physical output timing remain unqualified.
See [Time/Offset](SWARM_TIME.md), [streams](SWARM_STREAMS.md),
[membership](SWARM_MEMBERSHIP.md) and [jobs](SWARM_JOBS.md).
