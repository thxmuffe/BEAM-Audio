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
Manager or Inspector processes grants nothing. The privileges are one signed,
versioned **policy** (v2: `members` with permissions, `removed`, `revision`).
Revision 0 follows from the link alone: the creator holds every privilege. Each
change is the next revision, signed by the `grant` holder that made it, and is
sent to every present Device. Every Device keeps the latest policy it accepted.

A Device accepts a signed policy when its signer holds `grant` in the policy the
Device already has, or when **delegation certificates** lead from the creator to
the signer at a revision newer than the Device has seen. A `grant` holder signs
a certificate whenever it gives `grant`; the certificates travel with the
policy, so a newcomer can trust a delegated `grant` holder while the creator is
away. A higher revision wins; equal revisions with different content resolve to
the smaller statement hash, so Devices that saw concurrent changes converge.
A Session whose last `grant` holder gives it up continues unchanged.

On the wire each admitted Device has one sorted permission list. `grant` is
spelled `owner` and `on_air` is spelled `stream_publish` there; these are signed
constants. `end_session` was added on 2026-11-15, so every Device in a Session
must run a build that knows it. Scoped operation permissions (`status_read`,
`time_read` and so on) share that list, and local Contracts/consent remain
independent. Sources other than the microphone need `on_air`, checked both when
registering a local Source and when accepting a peer catalogue. Microphone
contribution needs local consent only. No privilege can remotely turn on a
microphone or system capture.

Snapshots expose the local `privileges`, `grant_holders`, the present
`participants`, each known Device's privileges, and (to `grant` holders) open
`requests` per Device. A present Device without a policy entry holds the
`buffee_default_permissions`. Limits: 16 present Devices, 16 policy entries,
31 removed Devices and four Receptions.

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

### The link

The creator writes the Session's link once; it never changes and every
participant shares the same one. Since 2026-11-17 it is
`beamaudio://s/<ticket>` (v6, about 100 characters): base64url of the raw bytes
version 6, creator key (32), nonce (16), secret (16, 128-bit), then the
Reception URLs separated by newlines, omitted when the only one is the default.
It has no signature and no name. Joiners check every policy change against the
creator key, so the link needs no signature; the creator signs the starting
policy (revision 1) at creation and joiners take the Session name from it,
showing "Session" until they meet a Device. The Session ID is the first 32 hex
characters of sha256(creator key ‖ nonce), so anyone can check which key created
a Session. The link is a bearer credential and is not encrypted. v5 links
(`beamaudio://session/v5?ticket=…`, signed JSON with name) still parse so saved
Sessions keep loading; v3/v4 links and their saved records are refused.

### Joining is pairwise

Holding the link is enough to participate. Every present Device advertises the
Session mailbox, sha256("beamaudio-session-mailbox/v1:" ‖ secret), on the link's
Receptions; Reception sees that value, never the secret. A Device looks up who
is present and runs a handshake with each of them independently: `hello`,
`challenge`, `proof`, `welcome`. Both sides prove the secret with an HMAC bound
to the direction, the challenge and both Device IDs, and exchange their policies.
No Device waits for a creator, a `grant` holder or a Manager, and none admits
others on everyone's behalf. A Device arriving at an empty Session is simply its
only participant: it keeps the Session ID, gains no privilege and is found by
later arrivals. A Device listed as removed in the receiver's policy is refused.
A participant that vanishes without an `offline` message (crash, power loss) is
dropped when two successive successful lookups no longer list it; it rejoins by
the same handshake when it returns.

### Leave and return

`ba_buffee:leave/0` disconnects only the local Device; Reception drops its
advertisement. Every Device keeps its accepted policy for each Session it has
joined (`buffee_sessions`, at most 32), so privileges survive Leave and
application shutdown. Joining the same link later restores them at once, even
when nobody else is present. A `grant` holder also keeps the intent to return on
next start; `restore_buffee_on_start` enables automatic restoration. Live
processes and clock mappings are recreated, not restored from disk.

Admitted Devices keep their privileges when no `grant` holder is present. The
last synchronized clock can continue on an available on-air Device; read
[timing and limits](BUFFEE_TIME.md). Having no `grant` holder and nobody on air
does not trigger automatic destruction or revocation.

## End and removal

A Device holding `end_session` can call `ba_buffee:end_buffee/0` (Destroy Session
in the current UI). A signed End tears down reached Devices and clears saved
return intent. Without the privilege the call returns `end_privilege_required`;
a `grant` holder can request the privilege for itself first. Ordinary Leave or
transport loss never substitutes for End. End is bound to each pair's handshake.
`revoke/1` lists the Device as removed in the next policy and tells every
present Device, including the removed one, which stays visible as `revoked`.
Forwarding the link does not clear a removal; explicitly inviting that contact
may.

No durable public end registry or offline ceremony is introduced. Because the
link never changes, End and removal reach only Devices that are present or that
later meet a Device holding the newer policy. A removed Device that returns to an
empty Session is alone there until such a Device arrives.

## Privilege requests

`request_privilege/1` sends a fresh signed request to the known `grant` holders
and returns `grant_holder_unavailable` if none is reachable. Only admitted
identities can request. `grant` holders see open requests per Device in
`requests`; granting the privilege clears the request. Requests do not change
consent. They are a `grant` holder's live runtime state, not signed Session
state or an offline queue. Automatic approval and time-limited grants are not
implemented. Reception remains unchanged: its existing capability-scoped lookup
already lists every Device advertising the same mailbox.

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
