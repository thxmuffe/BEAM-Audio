# Secure Swarm boundary and migration contract

Date: 2026-11-08. Step 1 design contract for the [active roadmap](PLAN.md).
This specifies the whole target boundary. Step 2's restricted signed status
exchange is now implemented; [its guide](SWARM_CONTROL_PROTOCOL.md) records the
actual scope and limits. Step 3's [local Handler/test Worker lifecycle](DEVICE_HANDLER.md)
and capability reads are implemented. Step 4's [test Contract/job flow](SWARM_JOBS.md)
is implemented; Passport/rejoin and audio contracts remain targets.
Existing implementation evidence stays in [PROGRESS.md](PROGRESS.md).
The vocabulary in PLAN.md applies here.

## Trust boundary and ownership

Each Device owns its runtime, installed code and resources. Devices exchange
validated application data; they never acquire each other's OTP connectivity,
PIDs, cookies, module/function invocation or process-spawn authority. Transport
encryption authenticates/protects a connection, not permission for every command.
OTP's own [security guidance](https://www.erlang.org/doc/system/secure_coding.html)
assumes connected distribution peers and loaded code are fully trusted.

| Owner | Authoritative state and decisions |
| --- | --- |
| Swarm membership/policy authority | Admitted identities, revocations, Contract revisions and designated Director. Initially one designated Device, pinned by public key; one local serialized policy writer. |
| Director | Job offers and their reported outcomes; shared coordination permitted by policy. This role may share the authority's Device, but offers confer no local resource ownership. |
| Device Handler | Local capabilities, consent, capacity, accepted obligations, worker ownership and reconciliation. It can refuse any offer that violates local limits. |
| Local OTP supervisors | Process startup/shutdown/restart mechanics. They do not admit remote Devices or decide Swarm permissions. |
| Worker/session | One local task and its native resources; reports completion/failure to its Handler. |
| Subscription owner | Durable receive/playback intent keyed by Swarm, publisher Device and source identity; separate live media execution per subscription. |
| Erlang clock/presentation code | Shared reference identity/quality, local mapping, packet targets and permitted corrections. The publisher assigns targets; receivers execute them or report failure. |
| Desk | Authenticated socket routes, mailbox capabilities and introductions; neither membership authority nor audio transport. |
| UI/platform host | Local user commands, consent/OS permissions, secure key storage and state display. No remote authorization or scheduling decisions. |

An authority's absence does not elect a replacement. New admissions, grants and
policy edits wait or fail visibly. Director failure likewise does not transfer
authority by timeout. Offline membership remains recorded; it is not evidence
that a cached policy is current. No federation or consensus service is required.

## Identity and durable state

- Device ID is the existing Ed25519 public key (64 uppercase hexadecimal
  characters). Keep its private seed in platform secure storage and preserve
  installation identity. OTP node names, Desk URLs and runtime PIDs are not IDs.
- Swarm ID is a stable random identifier (existing 128-bit/32-hex representation).
  An invitation pins the expected authority/introducer and identifies a Swarm;
  a mailbox capability grants delivery only. Neither is an operational grant.
- A Passport binds Swarm ID, Device ID and membership ID to its issuing authority
  and membership epoch. Rejoin proves current key possession with fresh challenges
  and checks current membership/epoch. It never reuses an old live session grant.
- Trust in the authority key comes from local creation or an explicitly accepted
  invitation/pairing, not an unsolicited policy claiming its own authority.
  Persist the selected authority key, membership and verified policy revisions.
- Session ID identifies one authenticated peer association; worker attempt,
  publication incarnation and native handle identify disposable execution.
  Stable source identity survives republishing; an incarnation prevents stale
  signaling from controlling a replacement publication. No PID travels on wire.
- Persist declarative intent and accepted policy changes when they happen.
  Never persist queues, monotonic deadlines, native handles or session replay
  counters. Existing local term checkpoints may remain local; they are not a
  format for decoding network traffic. Old checkpoints/tokens are not silently
  promoted into new Passport credentials. Step 5 defines their explicit migration.

For the step-2 proof, configure two existing Device keys and an explicit shared
Swarm policy fixture with a pinned authority and only status permission. That
fixture is not open admission or Passport implementation. Full invitations,
Passport issuance/revocation/rejoin and multiple Desks are step 5.

## Message authorization and session contract

Reuse the authenticated Desk client and existing WebRTC/Ed25519 building blocks.
Use a separate versioned Swarm application protocol; do not extend the opaque
OTP packet format or invoke its admission-to-distribution transition.

1. Bound input before decoding. Step 2 starts with JSON and at most 32 KiB for
   the complete application envelope, including signature encoding. Binary IDs
   remain binaries; only fixed names map to locally compiled operations.
   Reject unknown versions, operations, fields and invalid nested shapes.
2. Authenticate both peer identities with fresh challenge/response. Bind proofs
   to both identities, Swarm, both nonces and session; bind the WebRTC DTLS
   fingerprints when using that carrier. Sign exact encoded body bytes with a
   distinct `parvi-swarm-control/v1:` signature domain, not the old OTP-admission
   domain. The signed body includes version, sender, recipient, Swarm/session,
   sequence, policy epoch/revision, operation, request/reply correlation and payload.
3. The transport's peer/from binding must match the verified signer. A Desk's
   sender stamp alone is insufficient for end-to-end peer authentication.
   Signed control through a Desk is not a promise of payload confidentiality
   from that Desk. Private keys, old Erlang cookies and microphone/audio bodies
   are never application control payloads.
4. Establish a fresh, finite session authorization against the current policy.
   Step 2 uses a 10-second handshake timeout and a maximum 60-second proof
   session, measured by local monotonic time; there is no synchronized-clock
   prerequisite. Renewal needs fresh authorization, not merely a heartbeat.
   Rejoin without access to current policy cannot claim current revocation checks.
5. Use a strictly increasing sequence per sender/session on one ordered route.
   Reject duplicate/lower sequences and packets for closed/expired/old sessions.
   Unverified input cannot advance replay counters or create pending requests.
   Fresh challenges prevent handshake replay. Route replacement establishes a
   new session and fences the old one; multipath/reordering support is deferred.
6. Before dispatch, check current membership, policy epoch/revision, permitted
   operation, resource scope, local consent/capacity and expiry. Reject known
   revocation immediately. No membership, role label, connection or signature
   alone grants permission to publish, play, record or execute a job.
7. Bound pending work, replies and queues, and reject overload. The first proof
   allows at most 32 peer sessions and one outstanding status request per peer;
   timeouts/errors release those entries. Invalid input never reaches a worker.

Step 2's dispatch allowlist contains only `status.read` and its correlated
`status.reply`/bounded error response. Read permission exposes a fixed snapshot
of that Device's protocol/session availability, not arbitrary diagnostics or
secrets. Replies are accepted only for an outstanding request to that peer.
Requests such as `worker.start`, OTP RPC, code upload and remote module selection
are forbidden. Later operations are added with their implementing step:

| Operations | Required permission and additional scope |
| --- | --- |
| Capability advertisement/query (3) | Advertise only own Device; read only policy-visible capabilities. Advertising never activates hardware. |
| Job offer/accept/cancel/report (4) | Designated Director may offer/cancel its jobs; selected Handler may accept/report only its own attempt. Local resource checks still apply. |
| Admission/rejoin/policy (5) | Authority-only issuance and revision; join/rejoin proves the claimant's own identity. A higher revision without the authority's proof is rejected. |
| Publication/subscription/media signaling (6) | Publisher owns its publication; receiver owns its subscription. Both ends check permission for that peer, stream and incarnation. No generic SDP/ICE forwarding to arbitrary sessions. |
| Clock sampling and Offset requests/updates (7) | Query designated reference; authorized members request Offset changes. Only the designated policy writer commits ordered updates. |

Swarm policy is the outer permission limit; each Device Contract can narrow it.
Consent to publish music does not authorize microphones; consent to subscribe
does not automatically authorize speaker output. A local user may preauthorize
specific resources, so a prompt is not required for every valid repeated job.
Consent/OS permission withdrawal stops affected work and invalidates its grants.

## Local Handler/Worker API

These are local Erlang API responsibilities, not remotely callable functions.
Step 3 implements local test capability/consent/start/cancel and bounded status;
step 4 adds atomic test-job evaluation/acceptance, explicit local Contracts and
leases. General audio Worker integration remains a later step.
Reuse `gen_server`, existing session
`gen_statem`s and supervisor child specifications rather than another framework.

| Local operation/event | Required behavior |
| --- | --- |
| Handler `capabilities()` / `status()` | Bounded snapshots of supported, unavailable or unknown resources and their limits; no device activation. |
| Handler `evaluate(VerifiedOffer)` | Check authenticated context, policy, consent, lease and capacity; reject or reserve a bounded local obligation. No network-supplied start specification. |
| Handler `accept(JobId)` / `cancel(JobId)` | Commit/release the local reservation; select a predefined installed worker implementation and ask the local supervisor to start/stop it. Return a correlated result. |
| Worker `start_link(LocalSpec)` | Called by its local supervisor using Handler-produced parameters, owner and attempt identity. Resource opening reports readiness/failure asynchronously. |
| Worker `cancel(Pid, Reason)` | Bounded, idempotent local stop; native resource cleanup also follows owner/session death. Never wait on network from a real-time callback. |
| Worker event `{worker_event, JobId, Attempt, Event}` | Handler verifies the current local worker identity/attempt before recording ready, completed or failed. Reports are observations, not physical-output proof. |

Reuse `parvi_audio_sup` and session ownership where possible. The Handler is a
permanent supervised service. Finite job/session workers are temporary children;
a crash reports failure, and any replacement requires a still-valid local
obligation and a fresh attempt. Do not blindly restart expired work. Handler
death must terminate its owned attempts before the replacement accepts work;
use a local supervisor failure domain/owner monitoring to enforce this in step 3.
Local `pg` notifications and monitors remain useful, but remote process-group
membership/remote monitors no longer describe Devices in a Swarm.

## Independent lifecycles and failure behavior

| Entity | Transitions and persistence |
| --- | --- |
| Membership | Unadmitted → admitted → revoked. Offline/online is a separate observation. Re-admission is explicit, with a fresh membership identity; transport loss never revokes membership. |
| Session | Disconnected → authenticating → authorized → closed/expired. Reconnect creates fresh authorization and replay state; no privileged operation during authentication. |
| Job | Offered → locally accepted → running → completed/failed/cancelled/expired. Rejected offers start nothing. Accepted work has Job ID, Director/assignee IDs, Contract revision, scope, local attempt and finite lease. |
| Subscription intent | Wanted (playing/paused) → waiting/preparing/active as observations change. Unsubscribe removes intent; source pause/disappearance retains it. Revocation blocks activation regardless of saved Play choice. |
| Media execution | Preparing → ready → playing/paused → closed/failed. Always disposable; its absence is not cancelled membership or deleted intent. |

The first job implementation stops session-dependent work on session loss or
lease expiry and releases its local reservation. Cancellation targets only that
job/attempt; Worker death affects its own obligation. Other subscriptions and
unrelated local work continue. Director/session return requires fresh acceptance;
stale “completed” reports cannot finish a replacement attempt.

Use correlated acknowledgements and bounded deduplication through the job's
validity period: an identical retry returns the same acceptance/outcome; the same
ID with a different offer is rejected. Cancellation/expiry fences later results.
A messaging acknowledgement confirms a protocol step, not Worker completion.
A timeout means an unknown outcome until reconciled. Do not claim exactly-once
execution across crashes; the first job must be idempotent, with no automatic
replay of uncertain side effects after restart. The implemented step-4 schemas
and limits are in [SWARM_JOBS.md](SWARM_JOBS.md).

The initial control-outage rule is to close session-dependent media/jobs once
their authorizing session is lost, rather than continue with uncertain grants.
Keep desired intent and unrelated local tasks. Reconnect checks current policy,
consent, capability and clock readiness before opening new native resources;
never replay expired packets. Source and receiver pause retain subscriptions;
receiver pause stops its output. Forget clears local rejoin/subscription intent,
not the persistent Device key or everybody else's membership. New protocol
revocation uses explicit authority policy; legacy mutual-removal UI semantics
must be mapped deliberately in step 5, not silently exposed as broad authority.

## Streams, Time and Playback Offset

Each subscription is keyed by Swarm, publisher Device, stable source identity
and a local subscription ID; current stream incarnation/transport is separate.
Two publishers and their pause, failure or unsubscribe operations are independent.
Step 6 adds local mixing with bounded gain/limiting, not general DSP placement.

Preserve [the packet-target contract](AUDIO_ENGINE_INTERFACE.md). Transport
binding and descriptor translation cannot replace a packet's target with an
arrival-time estimate, periodic media anchor or receiver-chosen deadline.
Erlang owns shared UTC-reference identity, freshness, uncertainty, mapping and
presentation policy. Native engines execute supported schedules and report
device observations or explicit failure. Missing calibration remains unknown;
software scheduling never proves physical speaker alignment.

Step 7 carries clock discovery/samples over restricted operations, preserving
four-timestamp measurements and current filtering/mapping policy where applicable.
Reference incarnation/revision changes invalidate obsolete samples. Offset edits
are requests to the single designated writer, serialized into revisioned policy;
authorized Devices share that committed setting. Stale updates are rejected,
same-revision conflicting content is an error, and reconnect fetches current
policy. No local override, leader election or new clock algorithm is required.

## Migration map grounded in existing code

These are confirmed source dependencies, not statements about installed builds.
Step numbers describe where behavior is implemented; all cross-device OTP
dependencies must be removed from the Swarm path before step 8 qualifies it.

| Existing code and dependency | Keep / replace | Step |
| --- | --- | --- |
| [`parvi_cluster_store`](../src/control/src/parvi_cluster_store.erl): `identity`, `load/save`, `node_name` | Keep secure seed input and local checkpoint mechanism; replace network identity based on OTP names with Device IDs. No VM snapshot/store rewrite. | 2, 5 |
| [`parvi_relay`](../src/control/src/parvi_relay.erl): raw delivery, signed Desk hello, `send/open/watch`; [`parvi_reception_sessions`](../src/Services/ReceptionDesk/relay_src/parvi_reception_sessions.erl): sender-stamped scoped routes | Reuse WSS/mailbox introduction. Add end-to-end application validation/authorization; presence is not membership. Cross-Desk routing is missing. | 2, 5 |
| [`parvi_cluster_auth`](../src/control/src/parvi_cluster_auth.erl): Ed25519 envelopes, nonces and DTLS binding | Reuse OTP crypto/patterns with a separate protocol/signature domain. Invitation parsing is not operational permission. | 2, 5 |
| [`parvi_cluster_desk`](../src/control/src/parvi_cluster_desk.erl): `channel`, trust `authorized` event, `net_kernel:connect_node`, node monitoring, same-URL `parse_link` | Replace admission-to-distribution transition with Swarm sessions; retain useful route/retry handling. Step 5 removes the one-Desk constraint. | 2, 5 |
| [`parvi_dist_channel`](../src/control/src/parvi_dist_channel.erl) and [`parvi_webrtc_dist`](../src/control/src/parvi_webrtc_dist.erl): opaque native frames, `dist_ctrl_*`, OTP handshake | Swarm path must never instantiate these as an authorization shortcut. Reuse WebRTC library primitives, not an OTP carrier with its dangerous frame type hidden. | 2; retire old path by 8 |
| [`parvi_cluster_trust`](../src/control/src/parvi_cluster_trust.erl): `grant` creates node/cookie atoms and routes distribution; `authority` calls a remote registered server; `reconcile_member` accepts same-epoch additive cached policy | Replace grants with scoped sessions and authority-verified policy freshness. Existing stale peer checkpoints cannot prove non-revocation. | 2, 5 |
| [`parvi_cluster_authority`](../src/control/src/parvi_cluster_authority.erl): caller identity from `node(Pid)`, `publish/retire/take_over` via erpc, Offset writer | Retain serialized local policy ownership. Authenticate Device IDs at ingress; replace remote calls with scoped messages. Authority transfer/failover is deferred. | 5, 7 |
| [`parvi_sup`](../src/control/src/parvi_sup.erl), [`parvi_audio_sup`](../src/Audio/src/parvi_audio_sup.erl) | Reuse local supervision; add Handler and explicit owned-worker failure behavior. Current temporary source/session workers and permanent receiver are useful starting points. | 3 |
| [`parvi_audio`](../src/Audio/src/parvi_audio.erl), [`parvi_audio_source`](../src/Audio/src/parvi_audio_source.erl): pg source PIDs and remote describe/subscribe that starts provider sessions | Local facade/worker ownership can remain. Wire catalogues use stable IDs; only the local Handler authorizes provider creation. | 3, 6 |
| [`parvi_audio_subscription`](../src/Audio/src/parvi_audio_subscription.erl), [`parvi_webrtc_audio_session`](../src/Audio/handlers/webrtc/parvi_webrtc_audio_session.erl): remote PID requests, monitors and SDP/ICE casts | Keep local state machines and engine cleanup. Replace peer PIDs with authenticated stream/subscription/attempt messages and explicit session-loss events. | 6 |
| [`parvi_media_channel`](../src/control/src/parvi_media_channel.erl), [`parvi_audio_stream_handler`](../src/Audio/src/parvi_audio_stream_handler.erl): media permission tied to distribution controller/node | Preserve selected handler/engine distinction; media authorization binds peer Device, stream and subscription, independent of distribution readiness. | 6 |
| [`parvi_audio_receiver`](../src/Audio/src/parvi_audio_receiver.erl): `connect_sources` uses erpc/PIDs; single receive/output slot; [`subscription_intent`](../src/Audio/src/parvi_audio_subscription_intent.erl) stores one node/source | Replace catalogue transport, key intent by Device/source, expand independent sessions and mixing. Retain fresh-clock/restoration gates; add current Contract/consent checks. | 6, 7 |
| [`parvi_clock`](../src/control/src/parvi_clock.erl): pg clock discovery, node/PID incarnation, `erpc:send_request` | Keep pure clock filter/mapping/sync modules and local worker; replace peer discovery/exchange identity and transport with authorized clock operations. | 7 |
| [`parvi_node_api`](../src/control/src/parvi_node_api.erl), [`parvi_inspector`](../src/control/src/parvi_inspector.erl), [`parvi_node_diagnostics`](../src/control/src/parvi_node_diagnostics.erl): membership implies broad commands; direct/one-hop erpc | Local UI/inspection APIs may stay. Remote access requires per-operation/resource grants; no generic function dispatcher or erpc forwarding under JSON. | 2 boundary; relevant commands in 3–7; verify 8 |
| [`parvi_chat`](../src/control/src/parvi_chat.erl), [`parvi_network`](../src/control/src/parvi_network.erl), [`parvi_native_bridge`](../src/control/src/parvi_native_bridge.erl): pg/node liveness, graph probes/commands | Carry admitted chat/events as explicit messages if retained; bridge shows separate membership/session/job/media observations. Keep [`parvi_events`](../src/control/src/parvi_events.erl) local notifications. Legacy swarm/bridge/direct profiles do not become a second permission source. | Integrate before 8 |

## Exit and next increment

Step 1 delivers this boundary, ownership/API/lifecycle contract and dependency
map. It adds no runtime processes, schema implementation, app build or deployment.
Temporary broken consumers/apps during migration are accepted by the user; no
parallel legacy stack, compatibility shim or playback-preservation gate is needed.
Preserve stored identity and the final packet timing semantics. Obsolete code can
be removed when its replacement is verified, no later than step 8's final checks.

Step 2 now supplies the bounded signed control protocol and two independent
runtimes exchanging authorized status messages through the existing Desk/mailbox
path. Its checks cover allowed request/reply, forbidden operations,
forged signer/recipient, stale session/sequence replay, expiry and oversize input;
none may create an OTP connection or job/audio worker. The real-Desk proof and
focused tests pass; WebRTC control is not integrated. Step 3 adds the local
Handler/test Worker and authenticated capability queries, retaining the ban on
arbitrary remote Worker start. Step 4 implements the scoped offer/acceptance and
non-audio Worker result proof. Next is step 5's Passport/rejoin and multi-Desk
work, keeping membership separate from resource permission. Product apps and
their device/listening checks are step 9, macOS then Windows then iOS.

OTP references checked 2026-11-08: [security](https://www.erlang.org/doc/system/secure_coding.html),
[supervision](https://www.erlang.org/doc/system/sup_princ.html),
[gen_statem](https://www.erlang.org/doc/system/statem.html), and
[pg scope/liveness semantics](https://www.erlang.org/doc/apps/kernel/pg.html).
These support the local OTP design; the grants/lifecycles above are project
decisions, not features automatically supplied by OTP or the Desk.
