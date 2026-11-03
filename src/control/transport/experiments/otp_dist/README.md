# Native OTP distribution over WebRTC experiment

Steps 1, 2 and 2a of the trusted-cluster plan: independent OTP **29.1.2 / ERTS 17.1.1**
VMs use a reliable, ordered binary WebRTC DataChannel as their native Erlang
distribution carrier. The reusable carrier, admission and desk modules have
moved to `src/control/src/` for Mac app integration. This directory retains the
isolated probe drivers. See [Mac usage](../../../../Apps/macOS/README.md) for the
new app path, which has not yet been connection-tested.

## Run

First build the existing pinned WebRTC dependencies using the instructions in
[the transport README](../../README.md). Then run from the repository root:

```sh
python3 tests/transport/otp-dist-smoke.py
python3 tests/transport/otp-trust-smoke.py
```

The carrier script compiles these experimental modules with warnings as errors,
under `builds/intermediates/OTPWebRTCProbe`. The trust script also compiles and
loads the shared `control` application. Both check the installed OTP version.
It uses the same local Elixir library paths and Mac OpenSSL 3 search path as the
existing direct-transport experiment. Per-VM logs are in that build directory.
It does not launch, install or modify any Parvi app or Reception Desk.

## Shared OTP foundation (step 2a)

The trust probe starts `parvi:start(native_cluster)`, which runs the existing
`pg` scope and chat `gen_server` under `parvi_sup`. No custom swarm, relay-chat,
direct application router, discovery or network/topology worker starts. The
third-party WebRTC libraries carry native distribution; OTP supplies remote
PIDs, process groups, casts, monitors and supervision. Invitation records
continue to express admission permission, independently of live `pg` membership.

The trust smoke exercises four independent VMs, shared chat in both directions,
one observer notification per test send, dead-observer cleanup (core EUnit),
chat-worker restart with retained observers, scope restart with explicit
resubscription, group pruning after removal/disconnection and fresh re-admission.
It also checks surviving chat during admission-actor outage. History remains
local, transient and best effort; this adds no delivery acknowledgment or replay.

The local harness explicitly establishes the tested native links. Automated
connection topology, internet recovery and mobile packaging remain later steps.
Mac and iPhone sources now select the native profile with a supervised desk
connector; Windows retains the compatibility runtime. New Apple app execution
remains unverified, and previously installed apps are unchanged. Names and UI labels are
deliberately unchanged, except the native cluster's display name.

## Reception Desk introductions (step 3a, compiled only)

`parvi_cluster_desk` replaces the local probe parent's SDP/ICE forwarding for
an initial pair of nodes. It reuses `parvi_relay` and the existing desk protocol;
the public service and working apps are unchanged. The relay client now accepts
an explicit Erlang owner and raw-envelope delivery. Its default still decodes
swarm messages for current apps.

The inviter creates a cluster and opens a mailbox. Its link wraps the existing
native invitation with the desk URL, relay identity and mailbox capability:

```text
parvi://cluster/v2?desk=URL&node=RELAY_ID&mailbox=CAP&invitation=NATIVE_V1_INVITATION
```

All values are percent encoded. This is an experimental link, not a shipping
app link. Both endpoints must already use the same configured desk URL, from
the existing default/override settings. The relay key addresses a desk socket;
the separate native key pinned by the inner invitation authorizes VM trust.

The joiner opens a reply mailbox and requests a connection. SDP/ICE goes through
the desk. Once the library opens the DataChannel, the existing signed,
DTLS-bound handshake validates admission and installs the native route/cookie.
The inviter admits the controller and the joiner calls `net_kernel:connect_node/1`.
OTP then handles process messaging, RPC, `pg` and failure detection. Native
packets, admission proofs and cookies travel through the DataChannel. The desk
carries introductions only; the connector does not route chat or decode terms.

Compile from the repository root (after the existing transport build):

```sh
(cd src/control && rebar3 compile)
erlc -Werror +debug_info -o builds/intermediates/OTPWebRTCProbe \
  src/control/transport/experiments/otp_dist/src/*.erl
```

For later manual use, launch independent named VMs with the core, transport and
experiment library paths, `-proto_dist parvi_webrtc`, `-start_epmd false` and
`-kernel connect_all false dist_auto_connect never`, as in the probe launcher.
Then, after `net_kernel` is started:

```erlang
parvi:start(native_cluster).
parvi_cluster_desk:start_link().
parvi_cluster_desk:status(). % Wait for desk.connected = true.
% On the inviter:
parvi_cluster_desk:create().
parvi_cluster_desk:invite(259200).
% On the joiner, with the returned link:
parvi_cluster_desk:join(Invitation).
% After OTP/pg shows the peer, use parvi:send/1 and history/0.
```

`join/1` returning `ok` confirms submission to the relay client, not successful
admission/connection. `status/0` shows the latest event and OTP connected nodes.
Failed joins currently require restarting the connector; retry/session repair
is deferred. The connector establishes only the inviter/joiner edge, with no
automatic mesh or additional membership registry.

`parvi_transport`'s `native_ice_servers` setting is passed to the library's
`ice_servers` option. Its default uses `parvi.direct_stun_urls`. Explicit maps
can include TURN `urls`, `username` and `credential`. No TURN service or
credentials are provisioned here. Reception Desk is not TURN and does not carry
native-distribution fallback traffic.

**Validation: compilation only, as requested.** The connector flow, separate
Internet networks, TURN and operation during desk outage remain unverified.
Reconnection/arbitration, cancelled joins, authority recovery and backpressure
are still later parts of step 3. No new tests or deployment in this slice.

## Responsibilities

- `parvi_webrtc_dist`: OTP carrier callbacks and bindings for pre-established
  channels. Reuses `dist_util` for cookie handshakes, negotiated distribution
  flags, connection supervision and ticks. A logical listener accepts channels;
  it opens no TCP distribution listener and does not register with EPMD.
- `parvi_dist_channel`: the process registered with ERTS as distribution
  controller. It passes opaque packets between `dist_ctrl_get_data/1`,
  `dist_ctrl_put_data/2` and the third-party `ex_webrtc`/`ex_sctp` libraries.
  Native terms, PIDs, atom caches, remote spawn, RPC and monitors are handled by
  OTP, not decoded or reimplemented here. Typed length framing separates admission
  control envelopes from native packets; 16 KiB chunks allow a native packet to
  span several SCTP messages. Native frames are rejected before their bodies
  arrive unless the connection has been authorized.
- `parvi_dist_probe` and `otp-dist-smoke.py`: test orchestration. The parent
  passes only SDP/ICE introductions between app-owned stdin/stdout pipes. It
  stops forwarding those signals before the native handshake starts. Test
  command results contain assertions/metadata, not the native payload stream.

Only this carrier is selected with `-proto_dist parvi_webrtc`; EPMD startup is
disabled. Automatic transitive connections are disabled. The step-1 test
explicitly configures a local fixture admission policy and provisions its cookie.
The carrier's default is now `parvi_cluster_trust`: missing policy, missing trust
manager, unknown controller or mismatched peer name denies native distribution.
The step-2 test does not provision shared cookies through its parent process.

## Invitation admission and cluster removal

Each VM's `parvi_cluster_trust` worker generates an in-memory Ed25519 key pair.
There is no account, permanent device identity, certificate issuer service or
shared cluster cookie. The new experimental invitation is explicitly a grant of
whole-VM cluster trust:

```text
parvi://cluster/v1?v=1&cluster=ID&issuer=PUBLIC_KEY&node=NAME&invite=ID&secret=SECRET&expires=TIME
```

The actual URI uses standard percent encoding. It contains an expiring bearer
capability and the inviter's public-key pin, never an Erlang cookie. Invitations
default to 72 hours in the probe; the authority accepts TTLs up to seven days.
Both endpoint parsing and the authority's stored expiry are checked. Changing
the URL expiry does not extend the capability.

Admission takes place over the established encrypted DataChannel, before OTP:

1. The inviter signs a fresh challenge using OTP `crypto` Ed25519. It includes a
   binding to the actual local/remote DTLS certificate fingerprints, obtained
   through the existing SDP library. The recipient verifies the pinned key.
2. The joiner signs its ephemeral public key, native node name, invitation
   capability, fresh nonce and the challenge/binding. The inviter verifies key
   possession and asks the admission actor to validate the live invitation.
3. The inviter returns a signed, nonce-bound grant and fresh pairwise OTP cookie
   inside DTLS. Both endpoints install the connection grant. The carrier checks
   it before setup, incoming acceptance, node-up and activation; the inbound OTP
   handshake permits exactly the authenticated native node name.

The Python introducer forwards only SDP/ICE and user invitations. Proofs and
cookies do not go through it. Reconnect as an existing member still requires a
fresh signed, channel-bound exchange and current membership validation. Restored
old cookies or OTP allow-list entries alone cannot enable a new connection.
OTP's cookie list is not a revocation mechanism; the explicit carrier gate is.

`parvi_cluster_authority` is a serialized OTP actor inside the cluster, not a
public Reception Desk or a permanently assigned machine. Any active node can
request invitations. The authority stores hashes of live capabilities and the
current membership snapshot. On removal of its own host, it transfers the policy
and retained capability records to a survivor, which completes publication.

The user selected **cluster-wide remove both**. The caller and target lose native
access to all honest surviving nodes, including access associated with other
logical swarms in this cluster. Their issued invitations and the invitations
through which either entered are removed from the authority's live capability
set, which all admissions consult. Other capabilities remain valid. Membership credentials
are removed, the epoch advances, native routes/controllers are fenced and peer
cookies are invalidated. Connections between surviving members stay usable.
There is no permanent banned-device register; a fresh invitation can authorize
a new membership for a removed device.

One VM has one native trust domain. Multiple logical swarms may use that domain;
they are not VM-security boundaries. A populated domain cannot silently join an
unrelated domain. A solitary domain can be replaced by explicit invitation
acceptance. Independently isolated domains require separate VMs or a separately
designed explicit merge operation. Existing app invitation URLs and UI behavior
are unchanged until native app integration.
The isolated authority does not rewrite the existing apps' swarm metadata or
their legacy relay sessions; that integration remains step 4.

The step-2 smoke test verifies four VMs, invitations by different nodes, remote
execution, wrong/expired tokens, altered expiry, forged signatures, wrong node
names, replay across DTLS sessions, nonce replay, malformed claims, unapproved
native frames, cluster-wide removal, stale cookies, retained survivor traffic,
fresh-invitation re-entry, authority handover and trust-manager shutdown. It also
verifies that authority outage denies new admissions without stopping existing
native traffic. Replay/cookie-restoration hooks live only in the local probe;
authentication-envelope observation is explicitly enabled by that probe and is
off by default in the channel worker.

## Acceptance checks

The test checks the OS process IDs differ and that ERTS reports each WebRTC
controller process as the native distribution controller for the other node.
It exercises both directions:

- `erpc` and real remote PIDs from native `spawn`;
- remote computation and exact echo of a random 256 KiB binary with SHA-256;
- 100 messages received in order, normal remote process monitoring and an
  abnormal linked remote process exit;
- an idle period exceeding two test tick-time periods, with native tick packets
  keeping the connection alive without application traffic;
- silent receive loss injected beneath distribution: OTP's own tick timeout
  tears down the connection and delivers `DOWN`, linked `EXIT` and `nodedown`;
- rejection of a mismatched cookie even though WebRTC has connected successfully.

The test uses a four-second native tick time to keep failure checks short. That
is a test setting, not the chosen timeout policy for mobile or live playback.

## Boundaries and next work

This proves native distribution over WebRTC between two desktop VMs. It does
not prove remote-network NAT traversal, relay transport of distribution,
simultaneous connection arbitration, reconnect, mobile support or audio latency.
The same-process controller serializes input/output for simplicity. Packets are
limited to 8 MiB, and local WebRTC mailbox overload fails the connection closed;
these are prototype bounds, not a completed end-to-end backpressure solution.
The library's asynchronous sends do not acknowledge delivery to the remote VM.

Admission/removal is verified under the isolated test's connected-cluster
conditions. This is not a consensus protocol, a security audit or a claim of
instant revocation across partitions. Unexpected authority/host recovery,
reconciliation of partial policy publication, cancelled joins, membership leases
and reliable revocation receipts remain step-3 work. A removal whose reply is
lost as the caller is fenced can report `pending`; survivors' current policy is
the completion evidence. Offline removed devices can retain a stale local view,
but a surviving node rejects their old credentials. New admissions fail closed
when the authority is unavailable; existing native connections do not depend on
it for each message. The authority actor currently has no automatic crash recovery.

Native distribution deliberately grants full VM trust. An already compromised
admitted VM can read or alter its peers' state, including keys; removing it cannot
undo prior compromise. These checks protect against outsiders and stale
credentials while honest nodes enforce current policy. They do not sandbox
malicious code already admitted into the cluster.

Prototype bounds include 64 members, 256 active invitations, 32 local sessions,
256 admitted native names and 4,096 pair-cookie installations per VM lifetime.
The last two bound non-garbage-collected OTP atom allocation. Fresh runtime
sessions are required after those budgets are exhausted. Trust-manager death,
including normal termination, closes its monitored native controllers.

Keep this out of normal app build paths and do not expose its local probe command
interface as a network service. Runtime packaging, internet transport recovery
and distributed DSP remain later steps in [the plan](../../../../../docs/PLAN.md).

API references: [OTP alternative carriers](https://www.erlang.org/docs/29/apps/erts/alt_dist.html),
[OTP 29.1.2 controller BIFs](https://www.erlang.org/docs/29/apps/erts/erlang.html#dist_ctrl_get_data/1),
and the installed OTP 29.1.2 `kernel/include/dist_util.hrl`.
