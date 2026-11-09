# Passports, current policy and multiple Desks — step 5

Implemented 2026-11-09. One device-local OTP authority owns a Swarm's membership,
revocation epoch, operation permissions and route directory. Desks only authenticate
identities and relay bounded envelopes; independent Desks do not create separate
membership replicas. This is one designated authority, with no consensus, election,
automatic Director failover or federation.

## Starting the headless runtime

Supply a stable `BA_IDENTITY_SEED` from secure platform storage and a private
`BA_STATE_DIR`. Both are required by this profile. No key is saved in checkpoint
files. Start an unnamed BEAM; this profile rejects Distributed Erlang.

```erlang
application:load(ba_core).
application:set_env(ba_core,swarm_membership,
    #{mode => create,desks => [DeskA,DeskB]}).
{ok,_} = ba_runtime:start(swarm_control).
{ok,Invitation} = ba_swarm_membership:invite(3600).
```

On a second device, configure before starting:

```erlang
application:set_env(ba_core,swarm_membership,
    #{mode => join,invitation => Invitation,desk => DeskB}).
{ok,_} = ba_runtime:start(swarm_control).
```

New members receive **no operation permissions**. On the authority explicitly set:

```erlang
ok = ba_swarm_membership:grant(DeviceId,
    [<<"capabilities_read">>,<<"status_read">>]).
ok = ba_swarm_membership:revoke(DeviceId).
```

Permission lists are sorted and unique. Step 6 adds separate `stream_read` and
`stream_subscribe` grants, with local per-source Contracts; existing members do
not receive them automatically. Step 7 adds `time_read`/`offset_write` for the
[authenticated reference and shared Offset](SWARM_TIME.md). `job_offer` additionally requires the
pinned Director role and the recipient's local Contract and consent. Initially
the authority is also Director and explicitly has the original three operation permissions.
The authority and Director cannot be revoked by this initial API.

For a returning member use `#{mode => resume,desk => DeskA}` and the same seed
and state directory. It retains identity and Passport but obtains a fresh authority
challenge and current policy before operating. The authority restarts with `create`
and its original seed/state directory; existing authority state takes precedence
over creating a new Swarm. Never share one directory between runtime instances.
Use `ba_swarm_membership:status/0` for public state; invitations are secrets and
must be transferred privately, not logged. Ordinary session APIs remain in the
[control protocol guide](SWARM_CONTROL_PROTOCOL.md).

## Authorization and persistence

Version-3 invitations pin the authority public key, Swarm and permitted Desk URLs.
A signed one-device invitation expires after at most 24 hours; claim state is
stored by the authority. Challenge/proof binds both fresh nonces, request ID,
credential hash, sender identity and a 10-second local deadline. A claimed ticket
can retry for its same device until expiry; it cannot admit another device.
Old invitation formats and old version-1 checkpoint data are not promoted.

A Passport binds authority, Swarm, device, membership ID and issue epoch. It proves
membership identity, not current non-revocation, operations, consent or liveness.
The authority checks its current registry on every admission/return/refresh;
removal rejects a retained Passport. Revocation advances both epoch and revision,
removes grants/routes, invalidates claimed invitations and notifies known members.
Old-epoch Passports of remaining members can refresh; removed memberships cannot.

A fresh nonce-bound grant carries signed current policy and an authority-signed
route directory. Members authorize operations for at most 60 local monotonic
seconds from the fresh request, refreshing with 30 seconds remaining. Delaying
a response does not extend that deadline. Observed newer policy immediately clears
sessions, fences outstanding jobs and requests current policy again. Control checks
its authorization deadline synchronously; session/job deadlines are clipped to it.
When an update cannot arrive, an existing authorization may survive until its
60-second bound. An offline authority cannot issue fresh authorizations; cached
Passports or wall-clock expiry alone never establish fresh non-revocation.

Checkpoints contain only declarative authority registry/invitation claims, member
Passport/policy version floor, and stable mailbox identity. Existing storage uses
0600 files, synced temporary writes and rename. No live session, nonce, request,
monotonic lease, Worker, local test consent/Contract or uncertain job is restored.
Authority storage failure terminates its actor so dependent runtime branches
restart instead of silently continuing with an uncheckpointed membership change.
Backups/rollback-resistant storage and distributed durable storage are not supplied.

## Desk ownership and limits

`ba_sup` uses `one_for_one` to separate the Desk connection supervisor, Desk
route owner and dependency-ordered runtime branch. `ba_swarm_runtime_sup` retains
`rest_for_one` for membership → Device supervisor → control → Swarm Clock →
on-demand audio. Thus membership/control failures still reset dependent state,
while one Desk connection failure cannot restart those owners or their Workers.

Relay Workers are temporary supervised children. The Desk owner reconciles desired
connections once per second and reinstalls their mailbox/watch state; repeated
Worker crashes do not consume a shared automatic-restart budget or tear down a
healthy Desk. Ordinary socket failures retain the relay's bounded reconnect backoff.
The route owner checkpoints declarative configuration, not live PIDs. Status calls
tolerate a missing/stalled connection. Loss of a member's primary Desk preserves
its unexpired membership and pending proof; another configured Desk can carry the
refresh. Failure to obtain fresh proof still expires permission normally.

Each device registers its stable identity/mailbox at all explicitly configured
Desks. The authority-signed directory names each recipient's primary Desk and
mailbox; senders try that route first, then another configured Desk if sending
fails, without broadcasting duplicates. This uses the same mailbox registered at
each permitted Desk, with the same signed peer/Swarm binding.
A returning member may choose another permitted primary. Route changes increment
policy revision. The authority must maintain connections at the participating
Desks; Desks require no shared database or membership logic. Unknown Desk URLs
advertised by peers are rejected. This is explicit routing, not automatic discovery
or load balancing. Remote Desks require verified WSS; WS is loopback-only.

Bounds: 4 Desks, 16 members, 16 pending authority challenges, 32 invitation records,
32 KiB signed packets, bounded JSON shape/depth and recipient queue. Invitation
records have no automatic compaction; reaching the bound returns unsupported.
Envelope signing uses Ed25519 and a membership-specific domain, distinct from
control/Desk signatures. Payloads are signed, not end-to-end encrypted; the Desk
can observe them. No arbitrary remote Erlang terms or calls are accepted.

## Evidence and limits

From `src/control`, compile and run the focused checks:

```sh
rebar3 compile
rebar3 eunit --module=ba_swarm_passport_tests,ba_swarm_job_tests,ba_device_handler_tests,ba_swarm_control_protocol_tests,ba_relay_tests,ba_native_tests
```

From the core root:

```sh
python3 tests/control/swarm-membership-smoke.py
python3 tests/control/swarm-control-smoke.py
```

The membership proof starts two temporary instances of the existing Phoenix Desk
service on loopback, with three independent unnamed device runtimes. It checks
zero-grant admission, explicit grants, cross-Desk status, alternate-Desk retained
rejoin, epoch change, authority restart and revoked Passport rejection after both
restarts, and active test-job cleanup on revocation. Test seeds/state are isolated from installed apps. It requires the
existing compiled ReceptionDeskMix and Elixir libraries under `builds/intermediates`.
This is not two independently hosted Internet Desks, app integration, audio output
or physical timing evidence. The separate public WSS proof checks existing
status/capability and bounded job behavior through Passport admission.
