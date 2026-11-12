# Shared BEAM control runtime

`buffee_control` uses local OTP supervision and authenticated scoped messages.
Ordinary Devices never obtain Distributed Erlang connectivity. Owner is trusted
administration independent of Chef/Guest participation and process placement.

Compile with `rebar3 compile` here. Run repository EUnit checks with `rebar3 eunit`
from the core root. Native transport dependencies are prepared separately; see
[builds](../../docs/BUILDING.md). Use private persistent `BA_STATE_DIR` and
`BA_IDENTITY_SEED` for a stable Device. Never print or share identity seeds.

`ba_runtime:start(buffee_control)` starts an idle runtime. `ba_buffee:create/2`,
`join/1`, `leave/0` and `end_buffee/0` control participation. Membership provides
`set_role/2`, `request_chef/0` and invitations. Applications use `ba_device_api`;
frontends submit commands and display snapshots, without owning policy.

Contracts and local consent gate Workers independently of admission. Shared
clock targets and audio interpretation remain in Erlang. Reception provides
connection authentication, live mailbox lookup and bounded opaque routing.

Read [architecture](../../docs/ARCHITECTURE.md),
[membership](../../docs/BUFFEE_MEMBERSHIP.md),
[protocol](../../docs/BUFFEE_CONTROL_PROTOCOL.md),
[jobs](../../docs/BUFFEE_JOBS.md), [streams](../../docs/BUFFEE_STREAMS.md),
[timing](../../docs/BUFFEE_TIME.md) and [current limits](../../docs/PROGRESS.md).
The explicitly trusted native-cluster profile remains for the older Windows
native UI; it is not an alternative permission source for Buffee Devices.

## Parallel web Sessions

`ba_sessions:request/1` accepts `list_sessions`, `new_session`, `close_session`,
and the existing Device API commands with an optional `session` field. Replies
include `session_id` and `sessions`. Omitting the field targets the first open
Session. Native hosts continue to use the default single-Session API.

Additional Session trees share identity, contacts and Reception sockets, with
separate membership, clock, chat and audio state. Closed Owner Sessions can be
reopened with their invitation. The open-tab manifest restores after shutdown.

After compiling the core at repository root, run the focused disposable test:
`python3 tests/control/parallel-sessions-smoke.py`. It starts a local Reception
service using the existing compiled Phoenix artifacts; it never loads app keys.
