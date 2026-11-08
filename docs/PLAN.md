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

**Step 1 complete as design; next: step 2 — secure Swarm messaging.** The
[boundary contract and code migration map](SWARM_CONTRACT.md) specifies identity,
authorization, ownership, local APIs and independent lifecycles. No new runtime
security boundary is implemented yet. Existing apps still use the older trusted
OTP control path; they have not become secure Swarm participants through this edit.
Mac-to-iPhone playback and retained subscription intent have user-reported
working evidence. The receiver still has one receive slot; Windows per-packet
schedule execution and physical output alignment remain unverified/incomplete.
Migration may temporarily break apps, connections and playback; the user accepts
this. Do not add a parallel legacy stack or compatibility shims just to keep the
system working between steps. Preserve stored identity and the per-packet timing
contract; gain and Music settings are outside this architecture change.

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

6. **Independent Streams and Subscriptions.** Refactor the current receiver's
   **single** receive slot and stored intent into a collection keyed by
   publisher/source identity. Support multiple simultaneous audio sources,
   independent lifecycle and pause/resume, subscriptions surviving source pause,
   and local mixing with bounded gain/limiting. Keep subscription identities
   independent of media transports and preserve the proven packet-target rule.
   **Exit:** two sources play together on one receiver; either can pause, resume,
   unsubscribe or disappear without disturbing the other.

7. **Time and Playback Offset over Swarm control.** Adapt clock discovery,
   sampling and policy updates that currently depend on `pg`, `erpc` or
   fully trusted OTP peers to the restricted Swarm messaging boundary. Preserve
   UTC-referenced per-packet broadcaster-assigned targets, real deadline execution,
   explicit failures, and clock quality diagnostics. Distribute revisioned
   Playback Offset updates from any authorized device, without divergent local
   overrides. **Exit:** devices share an authenticated timeline/Offset setting,
   recover after reconnect, and reject stale/unauthorized updates; separate
   software scheduling from physical-speaker alignment claims.

8. **End-to-end verification and migration.** Run two-device/one-Desk and
   multi-Desk tests: join, retained membership, revoked Passport, Director/job
   failure, worker crash, reconnect, independent streams, pause/resume,
   clock/Offset updates and cross-device output timing. Verify Mac/iPhone and
   Windows paths against their actual current support, with explicit limitations.
   **Exit:** repeatable scripted checks plus real listening/timing evidence,
   documented remaining gaps and no remaining dependency on the old cross-device
   Distributed Erlang control path. Obsolete pieces may be retired earlier when
   their replacements are verified; keeping old apps working is not a gate.

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
- Step 6 implements independent audio collections; full playback may remain
  incomplete until step 7 replaces clock/Offset control. The migration is not ready for untrusted
  devices while any required discovery, subscription, diagnostics, clock or
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

### Outside the eight steps

The [future ideas list](IDEAS.md) keeps longer-term possibilities separate from
this roadmap. Cinema/5.1, spatial rendering, DSP algorithms, acoustic calibration,
large-event scaling, new platforms, business tiers and new media backends do not
add prerequisites or extra steps here. Revisit them explicitly after the current
roadmap; preserve useful ideas without treating them as approved implementation.

Resume at step 2: implement the secure messaging proof described in
[SWARM_CONTRACT.md](SWARM_CONTRACT.md#exit-and-next-increment). Step 1 is complete
as a design deliverable; message schemas/code and runtime evidence are still pending.
