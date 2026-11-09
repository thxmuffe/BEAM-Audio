# Ephemeral Swarms, Passports and multiple Desks — step 9

Step 9 supersedes step 5's durable Swarm/rejoin model. Each gathering has a fresh
random ID. Its creator is Captain, membership authority and Director for its
lifetime. There is no election, dormant Swarm registry or snapshot restoration.
Device Identity and the local address book survive; Swarm membership does not.

## Local APIs

Supply a stable `BA_IDENTITY_SEED` from secure platform storage and a private
`BA_STATE_DIR`. Start an unnamed BEAM; `swarm_control` rejects Distributed Erlang.
The runtime starts **idle**, without restoring or joining a gathering.

```erlang
{ok,_} = ba_runtime:start(swarm_control).
ok = ba_contacts:put(DeviceId, <<"Alice">>).
ok = ba_contacts:group(<<"Session">>, [DeviceId]).
ok = ba_swarm:create(<<"Evening session">>, [DeskA,DeskB]).
{ok,[#{device := DeviceId,invitation := Link}]} =
    ba_swarm:invite({group,<<"Session">>},3600).
```

Contacts are Device IDs with local labels. Groups are local selections of saved
contacts; no approval, reciprocal friendship or synchronization is involved.
`ba_contacts:list/0`, `delete/1`, `delete_group/1` and `resolve/1` provide management.
`ba_swarm:invite([DeviceId],TTL)` selects individual contacts. It returns signed,
recipient-bound invitation URIs for private transfer or QR rendering. Automatic
unsolicited Desk invitation delivery is not implemented; URI transfer is the
accepted step-9 path. The recipient explicitly chooses to join:

```erlang
{ok,_} = ba_runtime:start(swarm_control).
ok = ba_swarm:join(Link).
ba_swarm:status().  % Join is asynchronous; wait for state => authorized.
ok = ba_swarm:leave().
```

The Captain uses `ba_swarm:end_swarm/0`, or leaves to end the entire gathering.
A member cannot end it for everybody. Leaving removes that admission and its
claimed invitations; returning requires a new invitation. A new creation always
gets a new ID, even with the same Captain, name and storage directory. There is
one active Swarm per local runtime. `ba_bridge:request/1` exposes local JSON
contact/group and lifecycle commands; app integration remains step 10.

## Permission boundary

Saving a contact, generating an invitation or joining grants **no operations**.
Existing local Device Handler consent, Contracts and operation grants still apply:

```erlang
ok = ba_swarm_membership:grant(DeviceId,
    [<<"capabilities_read">>,<<"status_read">>]).
ok = ba_swarm_membership:revoke(DeviceId).
```

Lists of permissions are sorted and unique. Audio needs `stream_read` /
`stream_subscribe`, local per-source Contracts and explicit playback intent.
Time/Offset requires `time_read` / `offset_write`. Jobs require the designated
Director, `job_offer`, recipient consent and Contract. Captain status never
permits arbitrary remote process execution or access to microphones.

Signed v3 invitations pin the Captain, gathering name/ID, permitted Desks and
mailbox route. Each ticket expires within 24 hours and is bound to one claimant;
contact/group tickets are pre-bound to their selected Device in Captain memory.
Challenge/proof verifies fresh nonces, identity, request and credential hash.
Passports and policy floors exist only within this live gathering. They support
fresh authorization after transport loss, not restoration after a runtime ends.
A departure also identifies the current membership, so replaying an old signed
leave cannot evict a later admission. End messages must be signed by this Swarm's
Captain. Credentials must be transferred privately and never logged.

## Lifecycle and storage

`ba_sup` keeps contacts, Desk ownership and the local lifecycle owner independent.
`ba_swarm` dynamically starts one temporary `ba_swarm_runtime_sup`. Its
`rest_for_one` order is membership → Device supervisor → control → Swarm Clock →
on-demand audio. Membership is a significant temporary child: its death shuts
down the branch instead of recreating authority. Control/clock/receiver recovery
within a live gathering retains its existing scoped semantics.

The branch owns `ba_swarm_state` ETS. Policy, invitation claims, Passport,
mailboxes/routes, Offset and Subscription intent use that volatile storage.
Ending the branch deletes it and terminates Workers, Sources, Media Sessions,
Mixers and clock processes. Desk connections close and their mailbox rotates.
Old on-disk Swarm records are ignored; they cannot restore membership. Only
`contacts.term` is written by this new model; it uses the existing private atomic
file writes. Device keys remain in platform secure storage. Subscription intent
can survive a receiver restart within a gathering, but not its end or VM restart.

Captain end is sent to known members before local teardown. If that message is
lost, members end when existing fresh authority proof expires (at most 60 seconds
from its request); an initial unanswered join expires after 30 seconds. A brief
Desk disconnection does not itself end the gathering or elect a Captain.
Revocation still fences active work immediately on verified policy evidence;
without delivery, the existing authorization bound applies. Already submitted
native output cannot be selectively retracted.

## Desks, bounds and verification

Each Device opens the same scoped mailbox on up to four configured Desks. Sends
try the advertised route, then a configured alternate, without duplicate fanout.
Temporary relay Workers reconcile once per second; repeated failures of one Desk
do not restart runtime owners or healthy connections. Desks introduce and route;
they do not own membership or carry audio. Remote URLs require verified WSS;
WS is loopback-only. Signed messages are not end-to-end encrypted against the Desk.

Bounds remain 16 members, 16 pending challenges, 32 live invitation records,
32 KiB signed packets and bounded queues/JSON. Expired invitations are pruned
when new invitations are created. The address book allows 256 contacts and 64
groups, with at most 15 invitees per selection and 128-byte labels.

See [repeatable headless checks](../tests/control/README.md). The Ephemeral Swarm
proof covers saved-group invitations, real two-source WebRTC PCM, local consent,
leave/rejoin, Captain end, full process/ETS/connection cleanup, cold restart,
retained contacts and Captain crash followed by actual authorization expiry.
No product apps, audio hardware, physical speaker timing or Internet resilience
are qualified by that proof. Earlier 8d maximum-Offset deadline misses remain a
separate documented limitation; this lifecycle change does not claim to fix them.
