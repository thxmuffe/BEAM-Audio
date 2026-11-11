# Ephemeral Buffees, Passports and multiple Receptions — step 9

## Compact self-contained invitation links — v4, 2026-11-11

New/shared invitations use `beamaudio://session/v4?ticket=...`. The ticket is
unpadded URL-safe Base64 of a 64-byte Ed25519 signature followed by the exact
original signed JSON body. The existing signature domain, signed fields, random
secret, identity/admission checks and strict bounds remain unchanged. Parsing
reconstructs the existing credential envelope and invokes the same verification
and invitation validation. No compression, alias registry, shortening service or
Reception storage is involved. The link remains a private bearer credential.

Existing v3 links with parvi/beamaudio and swarm/session spellings remain readable;
Invite re-encodes saved v3 credentials as v4 without renewing or changing rights.
Older installed applications need updating to read v4; old v3 links still work
on updated applications. The sample fixture shrinks from 1036 to 713 characters
(31%); actual length varies with names and Reception URLs. Further compaction of
the signed body would require another explicitly versioned credential migration.

All six passport tests pass, including v3/v4 equivalence, signature/body tampering,
truncation, oversized links and existing binding/expiry metadata checks. Affected
Erlang modules compile with warnings as errors. No app installation, public
Reception deployment or hardware/network integration test is claimed.

## Current lifetime model — 2026-11-11

A Captain manages admission and permission changes. Its disappearance does not end
an already admitted gathering: live members keep the last signed policy and show
`authority frozen`. They can authenticate/renew peer sessions and perform already
granted operations. No automatic two-minute dissolution is applied. New admission
still requires the Captain; a device with no live accepted policy gains no rights
from a saved invitation or address-book entry alone.

Only the Captain may explicitly **Destroy a Session** (the signed End operation).
A member may Leave; app closure or
transport loss is not End, including on the Captain. An explicit Captain Leave
also disconnects locally without ending everybody else. A signed End received by
members tears down their gathering. A disconnected peer that misses End cannot
learn that fact automatically; there is no durable Reception tombstone or consensus.

A restarted Captain may recover the same gathering only after a fresh signed
challenge response from a surviving admitted Device. Its private saved recovery
record preserves the latest policy, invitations/revocation blocks and routes, but
is inert without that response. Recovery checks the responder's Device identity,
current saved admission, request nonce and deadline, rotates the Captain route,
then makes members obtain the current policy through the ordinary grant path.
Old history alone never starts authority. Explicit End clears recovery intent.

A reusable invitation retains its Buffee reference/name. After End, the first Device
reusing the link while no Captain is advertised starts a **fresh** gathering with
new membership and permissions. No election or simultaneous-Captain protection is
added. A partitioned frozen gathering may coexist with another gathering started
from the same link; no convergence mechanism is claimed.

This supersedes older descriptions below/in historical roadmap sections where
Captain shutdown or authority-proof expiry ended the whole gathering. Clock
freshness is separate: the time service is currently still pinned to the Captain
as clock provider. Permission continuity does not yet prove uninterrupted audio
when that provider disappears; decoupling clock ownership is follow-through work.

## Local APIs

Supply a stable `BA_IDENTITY_SEED` from secure platform storage and a private
`BA_STATE_DIR`. Start an unnamed BEAM; `swarm_control` rejects Distributed Erlang.
The bare runtime starts **idle**. Apple app startup enables
`restore_swarm_on_start`, immediately rejoining the last participant connection
when one was saved; see the reopening section below.

```erlang
{ok,_} = ba_runtime:start(swarm_control).
ok = ba_contacts:put(DeviceId, <<"MacBook Air">>).
ok = ba_contacts:group(<<"Session">>, [DeviceId]).
ok = ba_swarm:create(<<"Evening session">>, [DeskA,DeskB]).
{ok,[#{device := DeviceId,invitation := Link}]} =
    ba_swarm:invite({group,<<"Session">>},3600).
```

Saved Devices are keyed by Device ID, not people. Authenticated Buffee participation
collects other Devices automatically; capability replies fill in Handler names.
Repeated observations update the same record and preserve a manually chosen
label. Each Swarm is also collected as one local Device group, keyed internally
by Swarm ID. Reusing a link adds known participants to that existing group without
duplicates. No approval, reciprocal friendship or synchronization is involved.
`ba_contacts:list/0`, `delete/1`, `delete_group/1` and `resolve/1` provide management.
`ba_swarm:invite([DeviceId],TTL)` selects individual contacts. It returns signed,
forwardable invitation URIs for private transfer or QR rendering. Automatic
unsolicited Reception invitation delivery is not implemented; URI transfer is the
accepted step-9 path. The recipient explicitly chooses to join:

```erlang
{ok,_} = ba_runtime:start(swarm_control).
ok = ba_swarm:join(Link).
ba_swarm:status().  % Join is asynchronous; wait for state => authorized.
ok = ba_swarm:leave().
```

The Captain uses `ba_swarm:end_swarm/0` to end the entire gathering.
A member cannot end it for everybody. Leaving removes that admission; the same
invitation can be used to return. Invitations currently have no time expiry:
legacy expiry timestamps are ignored; newly issued tickets use `expires: null`.
A new creation without a link gets a new ID; joining through an old link retains
its ID. There is
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
Time/Offset requires `time_read` / `offset_write`. Any admitted coordinator can
offer jobs with `job_offer`, recipient consent and an explicitly matching local
Contract. Director is a programmed coordinator, not a source of extra rights. Captain status never
permits arbitrary remote process execution or access to microphones.

Signed v3 invitations identify a Swarm name/ID, issuing identity, permitted Receptions
and capability-addressed mailbox. The signature remains verified, including on
old links, but expiry is disabled for now. Repeated Invite and contact/group
delivery use the same shared link. Anyone possessing it can join the current
gathering or start a fresh one when it is empty. Revocation blocks that Device
within the current gathering; explicitly inviting a selected contact can clear
its block without changing the shared link. Forwarding alone cannot clear it.
Challenge/proof verifies fresh nonces, identity, request and credential hash.
Passports and policy floors apply only to this live gathering. A participant
saves them for fresh authorization after transport loss or app restart; they
cannot restore authority after its Captain ends.
A departure also identifies the current membership, so replaying an old signed
leave cannot evict a later admission. End messages must be signed by this Swarm's
Captain. Credentials must be transferred privately and never logged.

## Reusing a link

The Device asks the invitation's Reception for live owners advertising its mailbox
capability and Swarm ID. If an owner is found, the Device authenticates admission
against that current Captain using the signed bearer ticket. If the Reception confirms
an empty result, the Device creates fresh policy/membership under its own identity
and advertises the old mailbox alongside its new local mailbox. The old signature
identifies the invitation issuer; it does not restore that issuer's authority.
Repeated Invite returns the exact reused link. Reception failure/unsupported lookup
does not count as an empty result. Monitor observers wait for a Device to start
the gathering; they do not become Captains.

There is deliberately no atomic claim or simultaneous-Captain protection. Two
arrivals can both observe an empty address and start; lookup can return both, and
later arrivals currently use the first returned identity. There is no convergence
or Captain handover mechanism. A fresh gathering resets permissions, Passports,
revocations, jobs, clock, subscriptions and buffers, retaining only the address,
name and each Device's own persistent settings/contacts.

Build the updated runtime and Reception, then run:

```sh
python3 tests/control/reusable-invitation-smoke.py
```

This uses isolated local Devices and a real temporary Reception to check old signed
timestamps, later joiners, fresh Captain/membership, exact link reuse, revocation,
same-identity recreation and observer-only waiting. Physical audio is separate.

## Lifecycle and storage

`ba_sup` keeps contacts, Reception ownership and the local lifecycle owner independent.
`ba_swarm` dynamically starts one temporary `ba_swarm_runtime_sup`. Its
`rest_for_one` order is membership → Device supervisor → control → Swarm Clock →
on-demand audio. Membership is a significant temporary child: its death shuts
down the branch instead of recreating authority. Control/clock/receiver recovery
within a live gathering retains its existing scoped semantics.

The branch owns `ba_swarm_state` ETS. Policy, invitation claims, Passport,
mailboxes/routes, Offset and Subscription intent use that volatile storage.
Ending the branch deletes it and terminates Workers, Sources, Media Sessions,
Mixers and clock processes. Reception connections close and their mailbox rotates.
Old on-disk Swarm records are ignored; they cannot restore membership. `contacts.term` and `swarm_connection.term` use private atomic file writes.
The latter holds reconnect intent and a Captain's conditional recovery snapshot;
no saved authority activates without a fresh response from a surviving member. Device keys remain in platform secure storage. Subscription intent
can survive a receiver restart within a gathering, but not its end or VM restart.

Captain End is sent to known members before local teardown. Captain loss alone
freezes authority indefinitely for already admitted live runtimes. Initial joiners
and restarted participants still need current authorization. Verified policy
changes/revocations invalidate the old control view; frozen mode does not ignore
known newer policy. Missing delivery cannot make a partition learn a new policy.
Already submitted
native output cannot be selectively retracted.

## Receptions, bounds and verification

Each Device opens the same scoped mailbox on up to four configured Receptions. Sends
try the advertised route, then a configured alternate, without duplicate fanout.
Temporary relay Workers reconcile once per second; repeated failures of one Reception
do not restart runtime owners or healthy connections. Receptions introduce and route;
they do not own membership or carry audio. Remote URLs require verified WSS;
WS is loopback-only. Signed messages are not end-to-end encrypted against the Reception.

Bounds remain 16 members, 16 pending challenges, 32 live invitation records,
32 KiB signed packets and bounded queues/JSON. Expired invitations are pruned
when new invitations are created. The greedy address book has no fixed contact/group count cap. Contact labels
accept up to 256 UTF-8 bytes; group labels remain 128 bytes. Existing invitation
selection is still limited to 15 Devices. Automatically accumulated groups may
outgrow that selection limit; batched invitations are not implemented here.

See [repeatable headless checks](../tests/control/README.md). The Ephemeral Swarm
proof covers saved-group invitations, real two-source WebRTC PCM, local consent,
leave/rejoin, Captain end, full process/ETS/connection cleanup, cold restart,
retained Devices/groups, explicit End, frozen permissions after Captain loss,
and conditional Captain recovery with revocation blocks retained.
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

Closing an app disconnects transport without issuing End. A participant's
explicit Leave clears its reconnect intent. Captain app restart tries conditional
recovery using the saved record and a fresh response from a surviving member.
No survivor means no recovered authority; the reusable invitation may still start
a fresh gathering after leaving that waiting recovery attempt.

The shared snapshot exposes `authority_state` and `captain_present` separately
from `state: authorized`, with human-readable host/Handler labels in `connection`.
Frozen permission grants do not imply a fresh clock or successful audio output.
Both Apple apps and the web frontend display this shared state.
