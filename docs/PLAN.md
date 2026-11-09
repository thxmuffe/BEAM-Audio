# Development plan

## Accepted direction — secure Swarm architecture (2026-11-08)

This is the **next architecture roadmap** for BEAM Audio. It supersedes the older
trusted-cross-device-OTP-cluster design as the *target architecture*. Reuse useful
Mac/iPhone and Windows code without preserving old architecture solely for
compatibility. Superseded plans and exploratory proposals
are preserved in [old-ideas/](old-ideas/README.md). Build in small independently
verifiable increments; do not attempt a large-scale network optimization in
this phase.

### Reading order and status

This file is the single active implementation roadmap. Repository instructions
remain binding; design contracts and decisions explain interfaces, component
READMEs describe usage, and [PROGRESS.md](PROGRESS.md) records dated evidence
and validation limits. None of their older “next” instructions adds another
implementation sequence. If an existing contract conflicts with this target,
record and resolve it in step 1 before changing the affected runtime behavior.

**Steps 1–8 complete for the headless backend; next: step 9 — update macOS,
then Windows, then iOS with the common UI below.** The
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

- **Swarm:** logical organization of independent, potentially untrusted devices.
  Joining does not grant remote execution, hardware control or implicit trust.
- **Device:** autonomous participant, running its own local Erlang/OTP runtime.
  A Device may leave or disconnect at any moment, without revoking membership.
- **Desk:** temporary/public authenticated entry and introduction endpoint.
  Many Desks may lead to one Swarm. A Desk is not the Swarm authority and does not
  carry audio. The current Reception Desk is the starting implementation.
- **Passport:** persistent device identity and Swarm membership proof, permitting
  fast, challenge-verified rejoin while membership is valid and not revoked.
  Live session credentials and permissions are refreshed upon each return.
- **Contract:** explicit, enforceable permission and responsibility boundary.
  Local resource ownership remains with the Device Handler.
- **Director:** Swarm coordinator that offers jobs and coordinates shared policy,
  **not** a remote administrator of another device or a central worker dispatcher.
  Initial scope can use one designated Director; failover/federation are later.
- **Device Handler:** the device-local OTP owner of capability advertising,
  contract evaluation, job acceptance and worker supervision.
- **Worker:** local OTP process for an audio input, output, playback-stream,
  DSP or other capacity. A Worker is **not** a separate distributed Erlang node.
- **Capability:** discoverable description of a worker/device function and its
  limits, including required user/OS permissions.
- **Job:** scoped offer published by a Director, independently considered by
  Device Handlers; acceptance establishes a bounded, cancellable obligation.
- **Stream:** an independently identified audio publication carrying its
  descriptor and per-packet authoritative presentation targets.
- **Subscription:** persistent logical intent to receive a Stream. It is distinct
  from a live WebRTC/media connection, current playback and Swarm membership.
- **Active Player:** an admitted audio publisher whose stream should remain
  subscribed; pausing may stop audio packets without cancelling subscriptions.
- **Mixer / Stream Handler:** local mixing and output safety / replaceable
  native transport, codec, buffering and execution respectively.
- **Time:** common UTC-referenced Swarm presentation timeline; reference identity,
  freshness and uncertainty matter, not merely agreement on a label.
- **Playback Offset:** a versioned, Swarm-wide playback setting. Any admitted
  device permitted by the Swarm Contract can request an update; policy ordering
  resolves concurrent edits. This is not an unsupervised local preference.

Use **BEAM Audio** for the open-source technology. **OpenSound** refers only to
the commercial product. Use Swarm/Desk in new user-facing architecture and
documentation; preserve legacy `parvi_*` module names, established invitation
formats and stored identities until deliberate compatibility migrations.

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
   native platform output remains step 9.

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
   output qualification remains step 9.

8. **Backend end-to-end verification and migration.** Run two-device/one-Desk and
   multi-Desk tests: join, retained membership, revoked Passport, Director/job
   failure, worker crash, reconnect, independent streams, pause/resume,
   clock/Offset updates and backend scheduling boundaries. Use headless runtimes;
   app launches and physical listening/output evidence belong to step 9.
   **Exit:** repeatable scripted backend checks, explicit platform/measurement
   limitations and no remaining dependency on the old cross-device
   Distributed Erlang control path. Obsolete pieces may be retired earlier when
   their replacements are verified; keeping old apps working is not a gate.
   **Complete for the headless backend:** [repeatable checks](../tests/control/README.md)
   cover real PCM/Opus mixing, continuous 1000 ms scheduling, full 30-second virtual
   buffering, clock-instance capture rebind, the actual 20 × 5-second clock window
   across session renewal and earlier membership/job/failure checks. Removed the
   obsolete remote-PID native session and retired the old PCM carrier. Installed
   app profiles and physical output are explicitly unqualified until step 9.

9. **Update and verify the applications — macOS, then Windows, then iOS.**
   Integrate the new runtime and permission/state model into each app in that
   order, with the **same functionality, layout and information hierarchy on
   every platform**. Start with forgotten old Swarms/subscriptions rather than
   restoring them. Supporting platform code may change earlier when needed, but
   do not launch product apps during backend development: installed versions can
   auto-restore old connections/audio. Build/install/launch for this explicit phase.

   **Swarm:** show the Swarm name and ID.

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
   exclusions locally per Swarm/device, prevent their automatic connections/jobs/
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

10. **Return to an abandoned Swarm.** Establish and implement the lifecycle when
    every participating OTP runtime has stopped, then a former member returns.
    A Swarm is a durable logical identity/pointer, independent of its currently
    running processes; returning to an old Swarm should remain possible. Preserve
    its identifier and remembered membership rather than silently creating a new
    Swarm or fork. Distinguish remembering/opening that identity from obtaining
    current permission to resume operations. Determine what retained metadata,
    discovery and authority recovery are required when an ordinary member returns
    before the former authority. Do not turn a stale Passport into authority or
    reset old revocations merely because no process is online.
    **Existing foundation:** step 5 persists authority registry, Swarm identity and
    member Passports; the same authority seed/state reopens that Swarm after a
    total shutdown. Members currently require that authority online for fresh
    authorization. This does not yet solve ordinary-member-first recovery.
    **Exit:** stop all runtimes; verify both authority-first and ordinary-member-first
    return to the same old Swarm, with explicit dormant/recovering state where
    needed, no identifier fork, and preserved permissions/revocations. Record
    authority-loss/state-loss limitations and verify safe recovery behavior.

### Scope constraints and immediate milestone

- Keep BEAM/OTP local for supervision and decisions; use authenticated,
  capability-limited messages at Device trust boundaries. A valid Passport does
  **not** automatically authorize active microphone, playback or job operations.
- Reuse existing WebRTC/Opus and GStreamer media engine boundaries and preserve
  per-packet playback timing. Working app behavior between steps is not required.
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
  Product apps still require step-9 integration. The migration is not ready for untrusted devices while any required
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

Resume at step 9: integrate the verified backend into macOS first, then Windows,
then iOS, with the common UI and immediate audio actions specified above. Package
and verify native decoding/capture/output and record actual listening/timing limits.
Time, Offset and media control now use restricted Swarm messages; preserve
independent packet targets and subscriptions. No product apps were launched during
step 8; build/install/launch belongs to the explicit app phase. Start with forgotten
old Swarms/subscriptions. Abandoned-Swarm recovery remains step 10.
See [Time/Offset](SWARM_TIME.md), [streams](SWARM_STREAMS.md),
[membership](SWARM_MEMBERSHIP.md) and [jobs](SWARM_JOBS.md).
