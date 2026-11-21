# Session rights and joining (dark Sessions)

A Device's identity, its privileges and live transport are separate. There is no
membership list and no presence list: in a dark Session a Device sees only the
Devices it bumps into, plus the Manager, and knows nothing about the rest. The model is defined in the [terminology](TERMINOLOGY.md): Devices
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
`stream_read` and so on; `time_read` and `offset_write` were removed 2026-11-20) share that list, and local Contracts/consent remain
independent. Sources other than the microphone need `on_air`, checked both when
registering a local Source and when accepting a peer catalogue. Microphone
contribution needs local consent only. No privilege can remotely turn on a
microphone or system capture.

Snapshots expose the local `privileges`, `grant_holders`, the present
`participants`, each known Device's privileges, and (to `grant` holders) open
`requests` per Device. A present Device without a policy entry holds the
default rights (`ba_buffee_membership:defaults/0`). Limits: 16 present Devices, 16 policy entries,
31 removed Devices and four Receptions.

## Create, join, leave and return

Supply a stable `BA_IDENTITY_SEED` and a private `BA_STATE_DIR`, then start an
unnamed VM:

```erlang
{ok,_} = ba_runtime:start().
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

### Joining: a join certificate

Holding the link is enough to participate. The invitation key is derived from
the link's secret, sha256("beamaudio-session-invitation-key/v1:" ‖ secret) as an
Ed25519 seed, so links already shared keep working. A joining Device signs
"beamaudio-session-join/v1:" ‖ Session ID ‖ its Device ID with it; nobody needs
to be online. Every control request carries that join certificate, and the
receiver checks it against the public invitation key on every request, with no
handshake, pairing or cache (see BUFFEE_CONTROL_PROTOCOL.md). A Device listed as
removed in the receiver's statement is refused.

Every Device advertises the Session mailbox, sha256("beamaudio-session-mailbox/v1:"
‖ secret), on the link's Receptions, so any Device ID is addressable there.
Reception's lookup is a source of neighbours (at most 32 kept), not membership.
There is no Manager. A Device without a signed statement yet (just joined)
introduces itself to a random reachable neighbour; the encounter makes the newer
side share its statement and syncs the request board. Reception's list of
present Devices is used as a sticky random sample of at most 32 neighbours.
The Device list shows this Device and the Devices it has encountered (at most 64).

The signed rights statement travels to the Devices it concerns when a `grant`
holder changes it (rights holders before and after, the removed, the Manager and
the Devices that holder has encountered) and spreads on contact: on every new
relationship the side with the newer revision sends it. A Device that never
meets anyone holding a newer statement keeps its older one.

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
return intent (the return link and that Session's saved privilege policy).
End does not retire the link: by owner decision (2026-11-18) anyone holding it
can still open the Session again, arriving as an unprivileged participant of an
empty Session with the same ID. End reaches the Devices the ending Device can reach or has encountered. Without the privilege the call returns `end_privilege_required`;
a `grant` holder can request the privilege for itself first. Ordinary Leave or
transport loss never substitutes for End. End is an ordinary signed request (`session.request`, kind `ended`) that needs `end_session`.
`revoke/1` is Kick, not Ban: it drops the Device from `members` (so its
privileges end) in the next statement and sends it `ended`, so it leaves. It may
return through the invitation link as an unprivileged participant. The policy's
`removed` list is reserved for Ban (refusing the link); it lives only in the
gossiped Session statement. Nothing writes it yet.

No durable public end registry or offline ceremony is introduced. Because the
link never changes, End and removal reach only Devices that are present or that
later meet a Device holding the newer policy. A Device that returns to an empty
Session is alone there until such a Device arrives.

## Privilege requests

`request_privilege/1` posts a signed request on the Session's request board
(`ba_session_board`). Every Device keeps a copy, syncs it on contact and passes
new entries to its neighbours; it returns `grant_holder_unavailable` only when
this Device has no neighbour at all. A `grant` holder decides each new request
through `ba_device_request` (its On-air / Moderator answer): Always grants, No
posts a signed decline, Ask leaves it open. Granting and declining both post
signed answers, so the request closes on every copy. Open requests appear per
Device in `requests`. Requests do not change consent. The board lives in memory
and expires entries after a day; a returning Device gets it again on contact.
Time-limited grants are not implemented. Reception remains unchanged.

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
