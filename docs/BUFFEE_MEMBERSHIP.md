# Session membership and privileges

A Device's identity, its privileges, observed presence and live transport are
separate. The model is defined in the [terminology](TERMINOLOGY.md): Devices
hold privileges; there are no roles. Module and wire names still say `buffee`.

## Privileges and administration

Creating a Session gives the creating Device `grant`, `on_air` and `end_session`.
A newly admitted Device holds none of them. Privileges are requested, and a
`grant` holder answers through the local Device API:

```erlang
On=ba_session_privileges:wire(on_air).
ok = ba_buffee_membership:request_privilege(On).      %% ask; a grant holder's own request applies at once
ok = ba_buffee_membership:grant_privilege(Device,On). %% grant holder gives
ok = ba_buffee_membership:take_privilege(Device,On).  %% grant holder takes back; any Device may give up its own
ok = ba_buffee_membership:revoke(Device).             %% remove the Device
```

Each privilege is independent. Only `grant` holders change privileges; running
Manager or Inspector processes grants nothing. Changes are signed by the
administering `grant` holder and shared with the other Devices over the existing
bounded authenticated Reception transport, without Distributed Erlang. A Session
whose last `grant` holder gives it up continues unchanged.

On the wire each admitted Device has one sorted permission list. `grant` is
spelled `owner` and `on_air` is spelled `stream_publish` there; these are signed
constants. `end_session` was added on 2026-11-15, so every Device in a Session
must run a build that knows it. Scoped operation permissions (`status_read`,
`time_read` and so on) share that list, and local Contracts/consent remain
independent. Sources other than the microphone need `on_air`, checked both when
registering a local Source and when accepting a peer catalogue. Microphone
contribution needs local consent only. No privilege can remotely turn on a
microphone or system capture.

Snapshots expose the local `privileges`, `grant_holders`, each Device's
privileges, and (to `grant` holders) open `requests` per Device. Internal
membership worker states `authority` and `member` are implementation states.
Current limits remain 16 admitted Devices and four Receptions.

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
the Session, issuer and permitted Receptions. Another `grant` holder can
advertise the same invitation and admit Devices after the first one leaves. An
empty discovery result gives nobody a privilege and creates no replacement.

`ba_buffee:leave/0` disconnects only the local Device. `grant` holders retain a
saved policy/invitation record. With the same Device identity, startup can
restore that Session even if every Device previously shut down. Joining its saved
invitation after Leave also restores the remembered privileges directly. `restore_buffee_on_start`
enables automatic restoration. Live processes and clock mappings are recreated,
not restored from disk. Ordinary presence/state exchange refreshes routes and
known policy when a Device reconnects; return is not gated on a special surviving
peer challenge.

Admitted Devices keep their privileges when no `grant` holder is present. The
last synchronized clock can continue on an available on-air Device; read
[timing and limits](BUFFEE_TIME.md). Having no `grant` holder and nobody on air
does not trigger automatic destruction or revocation.

## End and removal

A Device holding `end_session` can call `ba_buffee:end_buffee/0` (Destroy Session
in the current UI). A signed End tears down reached Devices and clears saved
return intent. Without the privilege the call returns `end_privilege_required`;
a `grant` holder can request the privilege for itself first. Ordinary Leave or
transport loss never substitutes for End. `revoke/1` removes a Device's access;
forwarding the existing invitation does not clear that removal. Explicitly
inviting that contact may.

No durable public end registry or offline ceremony is introduced. A Device that
was disconnected cannot receive an End while absent; removal of a returning
troublesome Device remains an explicit `grant`-holder action.

## Privilege requests

`request_privilege/1` sends a fresh signed request to the known `grant` holders
and returns `grant_holder_unavailable` if none is reachable. Only admitted
identities can request. `grant` holders see open requests per Device in
`requests`; granting the privilege clears the request. Requests do not change
consent. They are a `grant` holder's live runtime state, not signed Session
state or an offline queue. Automatic approval and time-limited grants are not
implemented. Reception remains unchanged.

## Device API

The shared local JSON API accepts `create_buffee`, `join_buffee`, `leave_buffee`,
`end_buffee`, `request_privilege` (`privilege`), `grant_privilege` and
`take_privilege` (`device`, `privilege`), and `remove_device` (`device`).
Privilege names are `grant`, `on_air` and `end_session`; the retired wire
spellings are rejected as names. Frontends call this API and do not own
authorization or stored privileges. The web UI still uses the earlier role
commands and fields until its own update.

Rebuild clients for this change and for the [namespace migration](NAMING.md).
Native Windows compatibility mode still uses its older runtime; nothing here
claims a completed native-app migration or working physical audio. See
[validation](PROGRESS.md) and [next work](PLAN.md).
