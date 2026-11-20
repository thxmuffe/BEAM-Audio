# Shared BEAM control runtime

The runtime uses local OTP supervision and authenticated scoped messages.
Ordinary Devices never obtain Distributed Erlang connectivity. Devices hold
`grant`, `on_air` and `end_session` privileges, independent of process placement.

Sources are grouped by area under `src/` (rebar3 compiles them recursively;
module names do not depend on folders):

| Folder | Holds |
| --- | --- |
| `src/` | the application, top supervisor, runtime facade, settings, app bridges (Mac stdio, iOS loopback) |
| `device/` | the Device: API, configuration and consent, handler, requests, identity store, contacts |
| `session/` | Sessions: lifecycle, control links and protocol, membership and privileges, passport, chat, gossip |
| `reception/` | Reception (desk) connections and routing |
| `clock/` | the Session clock, its filter and mapping, time protocol, SNTP |
| `helpers/` | small shared helpers (hex, diagnostics counters) |
| `cli/` | the command-line tool |

Audio control (the Erlang side of audio) lives in `../Audio/control`.

Compile with `rebar3 compile` here. Run repository EUnit checks with `rebar3 eunit`
from this directory; see [builds](../../docs/BUILDING.md). Use private persistent `BA_STATE_DIR` and
`BA_IDENTITY_SEED` for a stable Device. Never print or share identity seeds.

`ba_runtime:start()` starts an idle runtime. `ba_session:create/2`,
`join/1`, `leave/0` and `end_session/0` control participation. Membership provides
`request_privilege/1`, `grant_privilege/2`, `take_privilege/2` and invitations. Applications use `ba_device_api`;
frontends submit commands and display snapshots, without owning policy.

Contracts and local consent gate Workers independently of admission. Shared
clock targets remain in Erlang; native hosts process and transport audio. Reception provides
connection authentication, live mailbox lookup and bounded opaque routing.

Read [architecture](../../docs/ARCHITECTURE.md),
[membership](../../docs/SESSION_MEMBERSHIP.md),
[protocol](../../docs/SESSION_CONTROL_PROTOCOL.md),
[streams](../../docs/SESSION_STREAMS.md),
[timing](../../docs/SESSION_TIME.md) and [current limits](../../docs/PROGRESS.md).

## Parallel web Sessions

`ba_sessions:request/1` accepts `list_sessions`, `new_session`, `close_session`,
and the existing Device API commands with an optional `session` field. Replies
include `session_id` and `sessions`. Omitting the field targets the first open
Session. Native hosts continue to use the default single-Session API.

Additional Session trees share identity, contacts and Reception sockets, with
separate membership, clock, chat and media state. Closed Owner Sessions can be
reopened with their invitation. The open-tab manifest restores after shutdown.

`forget_saved_session` removes this Device's saved Session entry, return link and
cached privilege policy. An ID-only marker prevents observations or old return
records from restoring it. Explicitly using its invitation remembers it again.
Leave keeps privileges; Forget discards the local copy. Other Devices retain
their own policies and may supply privileges on a later Join; the creator's
inherent privileges follow from the invitation and its unchanged Device key.

After compiling the core at repository root, run the focused disposable test:
`python3 tests/control/parallel-sessions-smoke.py`. It starts a local Reception
service using the existing compiled Phoenix artifacts; it never loads app keys.

Device permissions are shared across Sessions in the current profile. They start
OFF after Device/permission-owner restart and cannot be enabled by history replay.
System-audio broadcast intent remains per Session. Default Mac/iOS PCM playback and microphone capture use generation fencing and
acknowledged native stops. A failed stop keeps consent OFF and blocks regrant.
Matching native helpers must be rebuilt before testing. System-audio role-loss,
optional backends and crash recovery remain incomplete; see
`../../docs/CONSENT_ENFORCEMENT.md`.
