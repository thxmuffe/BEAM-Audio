# Buffee membership and ownership

A Device's identity, its Chef/Guest participation, ownership, observed presence
and live transport are separate. The trusted Owner model is defined in the
[terminology](TERMINOLOGY.md). No additional owner trust or quorum system exists.

## Roles and administration

Creating a Buffee explicitly assigns Owner and Chef to the creator. Newly admitted
Devices are Guests. Any current Owner may use the local Device API or web Device
menu to change these roles:

```erlang
ok = ba_buffee_membership:set_role(Device,chef).
ok = ba_buffee_membership:set_role(Device,guest).
ok = ba_buffee_membership:set_role(Device,owner).
ok = ba_buffee_membership:set_role(Device,remove_owner).
ok = ba_buffee_membership:revoke(Device).
```

Chef/Guest changes leave ownership alone. Ownership changes leave participation
alone. Only Owners authorize these changes; running Manager or Inspector processes
does not grant ownership. Role changes are signed by the administering Owner and
shared with the other Devices. Ordinary role/state messages use the existing
bounded authenticated Reception transport, without Distributed Erlang.

The underlying sorted permission list represents ownership as `owner` and music
publication as `stream_publish`; ordinary scoped operation permissions and local
Contracts/consent remain independent. The shared runtime checks declared publication roles both when registering a
local Source and accepting a peer catalogue. Sources other than the microphone
require Chef permission. The app audio Worker also requires Chef permission
for system/music publication. Guest microphone contribution remains available with
local consent. Ownership cannot remotely turn on a microphone or system capture.

Snapshots expose `roles`, `owners` and each Device's roles. `role` is the primary
display role (Owner if owned, otherwise Chef or Guest). Internal membership worker
states `authority` and `member` are implementation states, not additional Device
roles. Current limits remain 16 admitted Devices and four Receptions.

## Create, join, leave and return

Supply a stable `BA_IDENTITY_SEED` and a private `BA_STATE_DIR`, then start an
unnamed VM:

```erlang
{ok,_} = ba_runtime:start(buffee_control).
ok = ba_buffee:create(<<"Evening session">>,[ReceptionURL]).
{ok,Link} = ba_buffee_membership:invite(null).
%% On a different Device:
ok = ba_buffee:join(Link).
%% Admission is asynchronous: wait for state => authorized.
```

Invitations are private, reusable bearer links. Their signed payload identifies
the Buffee, issuer and permitted Receptions. A shared Owner can advertise the
same invitation and admit Guests after the first Owner leaves. An empty discovery
result does not turn an arbitrary Guest into an Owner or create a replacement.

`ba_buffee:leave/0` disconnects only the local Device. Owners retain a saved
ownership/policy/invitation record. With the same Device identity, startup can
restore that Buffee even if every Device previously shut down. `restore_buffee_on_start`
enables automatic restoration. Live processes and clock mappings are recreated,
not restored from disk. Ordinary presence/state exchange refreshes routes and
known policy when a Device reconnects; return is not gated on a special surviving
peer challenge.

Guests and Chefs already admitted retain their permissions when Owners are absent.
The last synchronized clock can continue on an available Chef independently of
ownership; read [timing and limits](BUFFEE_TIME.md). No Owner and no Chef does not
trigger automatic destruction or revocation.

## Destroy and removal

Any Owner can call `ba_buffee:end_buffee/0` (Destroy Session in UI). A signed End
tears down reached participants and clears saved return intent. Ordinary Leave
or transport loss never substitutes for Destroy. Removing ownership leaves the
Device participating. `revoke/1` removes its access; forwarding the existing
invitation does not clear that removal. Explicitly inviting that contact may.

No durable public end registry or offline-owner ceremony is introduced. A Device
that was disconnected cannot receive an End while absent; removal of a returning
troublesome Device remains an explicit Owner action.

## Device API

The shared local JSON API accepts `create_buffee`, `join_buffee`, `leave_buffee`,
`end_buffee`, `set_role` (`device`, `role`), and `remove_device` (`device`). Role
values are `chef`, `guest`, `owner`, and `remove_owner`. Web controls call this API;
frontends do not own authorization or stored ownership.

Rebuild clients and Reception for the [namespace migration](NAMING.md). Native
Windows compatibility mode still uses its older runtime; these shared-runtime
role semantics do not claim a completed native-app migration or working physical
audio. See [validation](PROGRESS.md) and [next work](PLAN.md).
