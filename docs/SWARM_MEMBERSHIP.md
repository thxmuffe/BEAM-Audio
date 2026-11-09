# Ephemeral Swarms, Passports and multiple Desks — step 9

Step 9 supersedes step 5's durable Swarm/rejoin model. Each gathering has a fresh
random ID. Its creator is Captain, membership authority and Director for its
lifetime. There is no election, dormant Swarm registry or snapshot restoration.
Device Identity, the local address book and participant reconnect intent survive.
Membership still requires fresh authorization from the same live Captain; a dead
Captain’s gathering cannot be restored.

## Local APIs

Supply a stable `BA_IDENTITY_SEED` from secure platform storage and a private
`BA_STATE_DIR`. Start an unnamed BEAM; `swarm_control` rejects Distributed Erlang.
The bare runtime starts **idle**. Apple app startup enables
`restore_swarm_on_start`, immediately rejoining the last participant connection
when one was saved; see the reopening section below.

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
forwardable invitation URIs for private transfer or QR rendering. Automatic
unsolicited Desk invitation delivery is not implemented; URI transfer is the
accepted step-9 path. The recipient explicitly chooses to join:

```erlang
{ok,_} = ba_runtime:start(swarm_control).
ok = ba_swarm:join(Link).
ba_swarm:status().  % Join is asynchronous; wait for state => authorized.
ok = ba_swarm:leave().
```

The Captain uses `ba_swarm:end_swarm/0`, or leaves to end the entire gathering.
A member cannot end it for everybody. Leaving removes that admission; the same
unexpired invitation can be used to return while the gathering is still alive. A new creation always
gets a new ID, even with the same Captain, name and storage directory. There is
one active Swarm per local runtime. `ba_bridge:request/1` exposes local JSON
contact/group and lifecycle commands used by the Apple apps and CLI.

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
mailbox route. Each ticket expires within 24 hours and can be forwarded to admit several
independently authenticated Devices. Contacts/groups select delivery recipients,
not who is allowed to reuse the link. Revocation blocks the removed Device from
all invitations that existed at removal without consuming those links for others;
the Captain can explicitly re-invite it with a newly generated link.
Challenge/proof verifies fresh nonces, identity, request and credential hash.
Passports and policy floors apply only to this live gathering. A participant
saves them for fresh authorization after transport loss or app restart; they
cannot revive the gathering after its Captain ends.
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

## App reopening and reconnect intent

macOS and iOS opt into the same OTP startup restoration. `ba_swarm` privately
saves the last participant connection and, after admission, its signed Passport,
Captain route and policy floor in `swarm_connection.term`. This is reconnect
intent, not a saved running Swarm: it contains no live process, clock lease,
workers, buffers or media sessions. Startup immediately attempts fresh Captain
authorization. Once admitted, rejoining uses the Passport rather than depending
on the original invitation's expiry. Revocation remains authoritative.

Closing a participant app disconnects transport without issuing voluntary Leave.
Explicit Leave clears reconnect intent. A Captain stopping still ends its
gathering: reopening explains that result and does not recreate it or elect a
replacement. Failure to reach the Captain during the existing 30-second initial
window produces an unavailable status; a stopped/ended gathering is not revived.

The shared snapshot's `connection` object exposes `state`, `name`, optional
`swarm`, and a human-readable `message`; credentials are never exposed there.
Both Apple apps show startup/rejoining progress and the result in the header.
This requires rebuilt apps and one join with the new version to record intent;
older versions that discarded connections cannot supply missing history.
