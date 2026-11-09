# BEAM Audio control runtime

Step 9 adds [Ephemeral Swarms and local contacts/groups](../../docs/SWARM_MEMBERSHIP.md).
Start `ba_runtime:start(swarm_control)` idle, then call `ba_swarm:create/2` or
explicitly accept an invitation with `ba_swarm:join/1`. `ba_contacts` is the
durable address book; Swarm policy, Passports, routes and Subscription intent
are memory-only for that gathering. Captain end/departure tears down its runtime;
Captain loss ends members when fresh authorization expires. No election or restore.
The local JSON bridge exposes lifecycle/address-book commands. UI integration
is step 10, macOS → iOS → Windows; no product app was launched for this work.

Follow-ups 8a–8d are implemented: independently supervised Desk connections and
route fallback, unchanged Contract no-ops, bounded failure diagnostics and fresh
nonce-based authorization renewal retaining eligible media. The root supervisor
isolates Desk ownership from `ba_swarm_runtime_sup`'s dependency-ordered runtime;
ordinary route loss is not revocation. Exact current policy and expiry remain
enforced. See [control/renewal](../../docs/SWARM_CONTROL_PROTOCOL.md),
[Desk ownership](../../docs/SWARM_MEMBERSHIP.md) and [checks](../../tests/control/README.md).
The 8d maximum-Offset continuity qualification remains open.

Core entry point: `ba_runtime`; OTP application: `ba_core`; configuration: `BA_*`.
Use the [canonical terminology](../../docs/TERMINOLOGY.md) and
[migration guide](../../docs/NAMING.md). Subscriptions are saved intent;
`ba_media_session` owns temporary connections. `ba_swarm_clock` owns shared time
and Playback Offset. Historical trusted-cluster instructions below are not the
current Swarm API or permission boundary.

## Verified Swarm backend — step 8

The headless `swarm_control` profile now provides the verified membership/job,
PCM/Opus collection and authenticated clock/Offset path, with no old cross-device
OTP control dependency. Step 8 fixes ordinary session renewal resetting the clock
window, adds bounded buffering over the Offset range and capture rebind after
reference restart, and integrates native decoded audio into the shared mixer.
Existing clock math and per-packet targets are preserved. See
[repeatable checks and platform limits](../../tests/control/README.md).
Product apps remain unmigrated; step 10 starts with macOS, then iOS, then Windows.

## Shared Time and Offset — step 7

[Authenticated Time and revisioned Swarm Offset](../../docs/SWARM_TIME.md) replaces
cross-device clock RPC/discovery. The authority is the initial clock reference and
single Offset writer. Explicit time_read/offset_write grants, fresh four-timestamp
samples and existing median/slew policy gate scheduling. Capture stamps from one
current clock/Offset snapshot; cached policy is not a local override. The real
WebRTC PCM proof now also runs with this shared clock and a headless output sink.
Step 8 verifies native decoded-audio mixing and sustained buffering; platform
capture/output and physical timing remain step-10 gates.
The revised shared app UI is specified in step 10; abandoned-Swarm return is superseded.


## Current Swarm audio path — step 6

[Independent Streams and Subscriptions](../../docs/SWARM_STREAMS.md) replaces the
single receiver with a gathering-scoped collection, scoped signed signaling, independent
WebRTC PCM endpoints and one Erlang scheduled mixer. Local publication/receive
Contracts and separate stream grants are required. Sources may pause or restart
without removing intent or disturbing another stream. Old singular APIs and
cross-device PID discovery are retired on this path.

The headless proof uses real WebRTC media with either the explicit test clock or
step 7's authenticated shared clock, and a scheduled output sink. Mixed output supports PCM
mono/stereo at one shared output rate/reference; Opus now decodes to that same
mixer in step 8. Platform output remains step 10. No product apps were launched.
The historical checkpoints below do not provide the active receiver API.

> **Reading status — 2026-11-08:** This guide describes the existing runtime and
> earlier checkpoints. Its cross-device OTP/erpc/pg operations belong to the
> trusted baseline, not the new untrusted Device boundary. Follow the
> [active Swarm plan](../../docs/PLAN.md) for migration and work order.

## Secure Swarm migration

Step 1's [boundary contract and code migration map](../../docs/SWARM_CONTRACT.md)
defines Device identity, message/session permissions, local Handler/Worker
responsibilities and the replacement of remote OTP dependencies. These are target
interfaces; step 3 now implements a [local Handler/test Worker lifecycle](../../docs/DEVICE_HANDLER.md).
Step 4 now adds the [Director/Contract/job proof](../../docs/SWARM_JOBS.md), with
local acceptance, leases, idempotent retry and correlated outcomes. Step 2's
[restricted status protocol](../../docs/SWARM_CONTROL_PROTOCOL.md) is implemented
and verified between independent runtimes through the real Desk without OTP
connectivity. Step 5 introduced [Passports, current permissions and multi-Desk routing](../../docs/SWARM_MEMBERSHIP.md).
Step 9 now starts that runtime idle; use `ba_swarm` for explicit create/join. The guides give limits and headless check commands.
New builds ignore old version-1 membership/route/subscription records while
retaining device keys. Step 3 adds scoped `capabilities.read` queries with their
own `capabilities_read` grant; they do not grant Worker execution. A separate
`job_offer` grant, designated Director and explicit local test Contract/consent
are required for the bounded test job. App integration
is step 10: macOS, iOS, then Windows.
Temporary broken app/control paths during migration are accepted; preserving the
old runtime alongside the replacement is not required.

## Automatic chat notices

Info-level system messages appear automatically for peer connect/reconnect/
disconnect, subscription readiness and playback starts. The chat worker records
its observed OTP link changes locally, with compact names and full peer IDs in
details. Audio notices broadcast from the receiving node. A disconnect preserves
membership and is not reported as revocation. Reconnect wording uses the current
worker's remembered observations. Native WebRTC playback starts are announced
on the player's acknowledgement, once per transition; periodic statistics do not
repeat it. Normal playback/subscription stops are quiet; failures remain Error.
The UI's existing minimum-level filter applies, and clock notices remain Trace.

## Headless inspection and control

`ba_node_api:request/1` exposes named commands over admitted OTP connections.
The [macOS inspector](../Tools/Inspector/README.md) joins as a separate persistent
node and accepts JSON lines, allowing scripts to read clocks/audio statistics and
control subscriptions, playback, buffering and Mac Opus broadcasts without UI.


## Native cluster restart/rejoin — device-checked, 2026-11-01

The Apple native hosts supply `BA_IDENTITY_SEED` from Keychain and
`BA_STATE_DIR` under Application Support. The seed remains local; never copy
it into logs or command examples. `ba_device_store` checkpoints policy,
authority invitation hashes and connector/mailbox routes outside the app bundle.
Without these variables the existing probe/command-line profiles stay ephemeral.

After both updated apps create/join once, they retain the same node/cluster
identity and known peer routes across restart. The connector watches desk
presence, creates fresh authenticated WebRTC channels and then calls OTP
connection APIs. `dist_auto_connect=never` remains deliberate. Offline permission
is not a live transport; failed sessions are released without deleting peers.
Ordinary close retains membership; `ba_legacy_cluster_desk:forget/0` clears local
membership/routes. New invitations still need the original authority online.

Known-member reconnect requires matching remembered membership tokens and epoch;
different epochs fail visibly. This is not globally current revocation consensus,
authority failover, a full mesh, message replay or audio-session restoration.
See [decision 0005](../../docs/decisions/0005-persistent-identity-and-cluster-rejoin.md)
for persistence boundaries and the first-admission checkpoint window. Signed
builds and physical Mac/iPhone checks pass for either app restarting, both apps
stopped and restarted in either order, unchanged cluster/device identities and
automatic native reconnection. An absent member stays Offline. No fresh
invitation was used after the one initial enrollment. Cross-epoch revocation,
desk-outage, simultaneous-start stress and background/interface recovery remain
unverified.

## Original prototype guide

A small Erlang/OTP application; no audio or iPhone runtime is implemented yet.
Tested on Apple Silicon macOS with OTP 29.1.2 and rebar3 3.27.3. No third-party
Erlang dependencies. Use those tool versions to reproduce this baseline; other
OTP versions have not been validated.

## Build and test

Compiler output is under `builds/intermediates/control/` at the repository root.
The local `rebar.config` selects this location automatically. Root-level
`rebar3 eunit` checks both this application and `src/Services/ReceptionDesk/`, with its own shared
workspace cache under `builds/intermediates/erlang/`.

```sh
brew install erlang rebar3
cd src/control
rebar3 compile
rebar3 eunit
escript ../../tests/control/smoke.escript
```

Run from the repository root before `cd src/control`. The smoke test launches real
BEAM processes on loopback, uses an ephemeral cookie, and stops its peer processes
on completion. It does not need a phone or an EPMD daemon. It checks two-way
delivery, worker restart, node departure, rejoin, and delivery after rejoin.
Socket access must be allowed by the environment. The test harness uses an
internal OTP EPMD registration query; this detail may need updating with OTP.

## Try it in two terminals

From `src/control/`, start terminal A:

```sh
ERL_EPMD_ADDRESS=127.0.0.1 rebar3 shell --name ba_a@127.0.0.1 --setcookie local_ba_demo
```

From `src/control/`, start terminal B:

```sh
ERL_EPMD_ADDRESS=127.0.0.1 rebar3 shell --name ba_b@127.0.0.1 --setcookie local_ba_demo
```

In terminal A:

```erlang
ba_runtime:connect('ba_b@127.0.0.1').
ba_runtime:status().
ba_runtime:send(<<"Hello from A!">>).
```

Group membership converges asynchronously. Wait until `ba_runtime:status()` lists
both nodes in `chat_nodes` before sending. In terminal B:

```erlang
ba_runtime:history().
ba_runtime:send(<<"Hello back from B!">>).
```

Back in A, `ba_runtime:history().` shows the reply. To observe UI events, use
`ba_runtime:subscribe().`, send from B, then `flush().` in A; events have the form
`{ba_message, MessageMap}`. Stop each shell with `q().`.

The shell is the initial interface; automatic chat rendering is deferred.
`rebar3 shell` without name/cookie also works for a single local session.

## Process structure and semantics

```text
ba_app -> ba_sup (rest_for_one)
                +-- ba_pg (OTP pg scope)
                +-- ba_chat (gen_server)
                +-- ba_discovery (local HTTP directory client)
                +-- ba_swarm_clock_sup (one_for_one)
                      +-- ba_swarm_clock (gen_server + read-only ETS snapshot)
```

`ba_core` is the UI boundary: send, history, status, subscribe/unsubscribe and manual
connect/disconnect. The worker publishes directly to members of one versioned
`pg` chat group. Messages do not pass through the optional discovery directory.
Starting more named nodes with the same
application and cookie allows additional participants; three-device operation
has not been tested. `connected_nodes` reports Erlang connections, while
`chat_nodes` reports devices whose chat workers have joined the group. These
are runtime node identities, not persistent device identities.

Messages are maps containing `version`, `id`, `sender`, `text`, `sent_at_ms`.
Text must be a valid UTF-8 binary, 1–4096 bytes. Each worker retains its latest
200 messages in arrival order. The timestamp is diagnostic wall-clock time,
not a synchronized timeline. This Erlang term format is an internal experiment,
not the future public audio/control protocol.

Delivery is best effort to currently visible members. A successful send confirms
local acceptance, not remote receipt. There are no acknowledgements, offline
delivery, replay, deduplication, durable history, or cross-sender ordering.
The history limit does not bound the process mailbox under overload.

OTP restarts a failed worker; its history is lost. Local UI subscriptions live
in `pg`, so they survive a chat-worker restart and disappear when the observer
process exits. If `pg` fails, the supervisor restarts chat too so it rejoins;
observers must resubscribe after that scope restart. Disconnected nodes disappear after
Erlang/`pg` detects them. Reconnection is manual; prior history is not merged.

## Independent application clock

The clock uses the existing `ba_swarm_clock_sup` / `ba_swarm_clock` supervision branch.
The default reference mode is now `auto`: `pg` discovers clock workers in the
current native cluster/permission epoch, and a deterministic ordering of stable
node names selects the master among directly visible clock peers. Each worker
already exists under OTP supervision; becoming master adds no VM, application or
registry process. Startup/rejoin redoes discovery using the restored identities.

This is **connected-peer coordination**, not a consensus-backed singleton.
`pg` membership is not transitive, so sparse or disconnected views can disagree.
A peer only serves a normal sync sample if it currently agrees that it is the
requested master process in the requested scope. Disagreement is reported, not
silently followed through a reference loop. `coverage` is `partial` if saved
native members are absent; this is visible holdover. A confirmed process/node
loss lets the next visible clock take over. A timeout alone does not elect a
replacement and cannot prove the old master is gone. See
[decision 0007](../../docs/decisions/0007-cluster-clock-pulls-and-monotonic-mapping.md).

### Acquisition and independent pulls

A master without usable time first tries an existing peer's mapping, then
acquires one upstream anchor if necessary. The default upstream remains METAS
(`clock_upstream = {ntp, "ntp.metas.ch"}`). Successful acquisition stops routine
upstream polling. A promoted follower keeps its valid local mapping; a restarted
master can inherit a surviving peer's time. If all VMs lost their mappings, a
new cold acquisition is needed. No live PID or VM monotonic offset is loaded
from disk. Isolated startup components may acquire independently before rejoin;
this does not claim one external request across all disconnected devices.


Cold startup with missing remembered members allows `clock_peer_discovery_ms`
(default 5000 ms) for native reconnection before using upstream time. An arriving
clock peer triggers an immediate attempt to inherit its surviving mapping.
This wait is bounded and does not apply to an already usable mapping.

Each follower measures through `erpc:send_request` on its own **5-second cadence
from worker startup**. A separate **30-second timer** checks whether correction
is needed. Clock/service discovery changes trigger an initial pull;
unrelated group-size changes do not reset everyone's phase. One request is
outstanding at a time. A busy worker skips missed periods rather than issuing
catch-up requests. Initial failed peer requests retry without querying an
external provider while valid local time remains.

The master does not sweep or push to followers. Sample handlers execute in OTP
RPC processes, read a protected ETS snapshot and update two bounded counters;
they do not wait behind the master clock worker's mailbox. Four actual exchange
timestamps estimate offset and round-trip delay. The requester accounts for
elapsed time; deferred processing and asymmetric paths are measurement
uncertainty, not magically removed by asynchronous messaging. No unbounded
per-follower history is kept. This has not been benchmarked at large scale.

Failed upstream acquisition backs off, and a Kiss-o'-Death refusal blocks further
queries until explicit reconfiguration/resync. Ordinary `resync/0` respects the
next permitted upstream attempt (at least 15 seconds after the preceding query).
There is no automatic precision/age threshold that silently re-enables periodic
Internet polling. A deliberately forced reconfiguration is an explicit operator
choice. The existing iOS in-process resolver remains in use.

### Monotonic mapping and audio

Time advances from `erlang:monotonic_time/1`, never from the count of timer
messages. `ba_swarm_clock_mapping` contains the immutable mapping and deadline
inverse. Initial acquisition establishes a provisional offset. Once 20 measured
offsets are available, the 30-second check compares their rolling median with
the currently applied offset. Differences strictly greater than **2 ms** adjust
its target and **slew** from the current value at 500 ppm by default;
there is no backwards step. `remaining_correction_ns` reports convergence still
in progress. This is application-clock correction, not DAC/sample-rate resampling.
No OS clock is modified.

`ba_swarm_clock:filtered_utc_time/0` returns `{ok, UTCNanoseconds}` using the
current monotonic mapping; `now/0` is its compatibility alias. `status/0` exposes
`filtered_utc_time`, `filter_sample_count`, `filter_required_samples`,
`filter_ready`, `filtered_offset_ns`, `sample_interval_ms` and `threshold_ns`.
The inspector's `clock` command exposes these fields too. The property advances
from monotonic time between observations; it is not a cached timestamp or the
average of old UTC readings. During follower warm-up, the value is provisional
and state is `acquiring`. Existing audio timestamp APIs share this same mapping.

`ba_swarm_clock_filter` is a pure bounded median filter. `ba_swarm_clock_sync` contains
pure four-timestamp measurement and threshold/correction functions.
`ba_swarm_clock_mapping` converts time and applies monotonic slewing. The supervised
`ba_swarm_clock` worker owns discovery, sampling, timers and state. Audio processes
use these modules/service through composition; no class inheritance, new
behaviour implementation, native code or Kalman library is needed.

Only genuine reference measurements enter the filter. Extra calls in the same
sampling period do not fill the window faster. A changed reference or a gap of
more than two sampling intervals clears the window; a stale window cannot drive
correction. A full window spans about 95 seconds without missed samples, and
the next 30-second check can delay the first correction further. A median
suppresses isolated offset anomalies but lags sustained drift; it does not
estimate frequency, remove fixed network asymmetry or guarantee 2 ms accuracy.

The master retains its initial UTC anchor and extrapolates with monotonic time,
or inherits a surviving peer mapping. It has no independent UTC observation
every five seconds under the startup-only upstream policy. Its own generated
ticks are therefore not added as fake reference samples: a freshly anchored
master normally reports one sample and `filter_ready = false`, while its clock
can still serve as the reference. The 20-sample gate applies to follower
corrections. More validation of the master's UTC would require new independent
reference measurements, outside this increment. No OS clock is changed.

`map_times/1` evaluates several timestamps against one immutable mapping. Capture
uses it for both the captured-frame timestamp and its expiry comparison. Output
uses the inverse mapping to obtain a local render deadline. This replaces the
assumption that a fixed `offset_ns` can describe an actively slewing interval.
Previously submitted OS buffers are not rescheduled by this change.

```erlang
ba_swarm_clock:status().
{ok, UTC} = ba_swarm_clock:now().
{ok, LocalDeadline} = ba_swarm_clock:to_monotonic(UTC + 100000000).
{ok, [CaptureUTC, NowUTC]} = ba_swarm_clock:map_times([CaptureMono, NowMono]).
ok = ba_swarm_clock:resync().             % explicit internal pull/upstream refresh
ok = ba_swarm_clock:set_reference(auto).  % resume connected-peer discovery
```

`status/0` is a mailbox-free ETS read. It reports role/master, local instance,
master instance/revision, timeline, scope/coverage, mapping revision, sample age,
round-trip measurement, residual correction and request/service counters.
`upstream_acquisitions` counts this worker's own successful upstream acquisitions.
The native JSON diagnostic also exposes bounded clock status and master identity.

States are `waiting_for_cluster` before native membership, `unsynchronized`
before acquisition, `synchronized` when the chosen local reference is current,
`holdover` for a missing/stale/unconfirmed peer or incomplete native membership,
and `stopped` when absent. A valid mapping remains available during holdover;
the legacy audio prototype can continue on it. A missing mapping or retired
native membership rejects conversions. `synchronized` is not a promise that
all saved members are online or that speakers are aligned. Current absolute UTC
uncertainty/drift is explicitly `unknown`; the last point measurement and RTT
are diagnostic evidence, not a permanent accuracy bound.

The generic wire clock ID remains `parvi-utc-posix-ns/v1`. That ID alone does not
prove shared master/timeline or sufficient accuracy. Native media plans must
check reference identity, mapping quality and the required output alignment;
DAC drift correction and acoustic/electrical measurements remain separate work.

### Explicit references and focused checks

Existing diagnostic overrides remain: `set_reference(system)` takes one local
OS-time anchor, `{ntp, Host}` / `{ntp, Host, Port}` take one upstream anchor, and
`{node, Master}` pulls an explicitly connected node every local period. `auto`
uses cluster discovery. Overrides are VM-session application configuration; set
`clock_reference` before startup for a startup override. `clock_upstream` chooses
the automatic mode's cold source. `clock_interval_ms` defaults to 30000 (correction checks),
`clock_sample_interval_ms` to 5000, `clock_filter_samples` to 20, and
`clock_slew_ppm` to 500. Tests shorten the timers without changing these defaults. Explicit modes intentionally bypass automatic discovery.

Run the approved focused checks from `src/control`:

```sh
rebar3 eunit --module=ba_swarm_clock_filter_tests,ba_swarm_clock_mapping_tests,ba_swarm_clock_tests,ba_native_tests
```

These use a loopback SNTP fixture and two supervised local OTP nodes. They cover
single acquisition/no periodic external polling, default cadence, blocked-master
mailbox independence, skipped periods, membership/retirement, time agreement,
master loss/recreation and peer inheritance, rejected obsolete instances, slew
continuity and exact deadline inversion. This is not a new real-device/WebRTC
clock or acoustic-alignment result. App rebuild/deployment remains separate.

## Native cluster foundation (opt-in)

`ba_runtime:start(native_cluster)` starts the shared `ba_pg`, `ba_chat` and
independent `ba_swarm_clock_sup` branch under the standard supervisor. It must be called before
the application starts. The default `ba_runtime:start()` keeps the current apps'
compatibility workers. The selected profile is application configuration and
persists across application stops; unset `runtime_profile` to return to the
default before restarting.

The native profile uses OTP process groups and remote `gen_server` casts for
chat. It does not start swarm gossip, application relay/direct routing,
discovery or topology polling. OTP connection/process liveness is separate from
the invitation policy's permission to reconnect. Group membership converges
asynchronously; there is no additional application membership registry.

The isolated [WebRTC distribution experiment](transport/experiments/otp_dist/README.md)
now runs this same core and verifies chat, observers, supervision and revocation
across independent VMs. The profile does not itself introduce peers, establish
WebRTC channels or build a connection mesh. Those remain carrier/admission and
step-3 recovery work. The Mac source now enables `native_desk=true` alongside
this profile: `ba_sup` then also supervises `ba_legacy_cluster_desk`, which owns
the trust worker, relay client and WebRTC channels. The native JSON bridge
adapts this single cluster to the existing chat UI. iPhone sources now also
select the native path by default, with an explicit relay build option; current
Windows sources retain the earlier profile. Previously installed apps are
unchanged. See [Mac usage](../../docs/apps/macOS/README.md) and
[iPhone preparation](../../docs/apps/iOS/README.md) for implementation/validation limits.
UI/source naming cleanup remains deferred.

## Network scope

The supplied shell config binds distribution to loopback. The demo cookie is
only for this local demonstration. `ERL_EPMD_ADDRESS` affects a newly started
EPMD daemon; it cannot change an already running daemon's interfaces. EPMD may
remain running after the shells exit.

Before a future LAN test, explicitly configure a private LAN interface, matching
reachable node names and a fresh shared secret. Use only trusted devices on an
isolated private network. Standard Erlang distribution grants cluster-wide trust
and this prototype does not add TLS, enrollment, authorization or abuse limits.
Do not expose its ports to the internet. The public device interface remains a
separate future design.

See [the iOS investigation](../../docs/decisions/0001-chat-first-and-ios-feasibility.md)
and [progress log](../../docs/PROGRESS.md) for the next hardware gate.


## Reception Desk transport

`ba_relay` now provides an outbound Gun WebSocket adapter with authenticated
binary node identities, scoped mailboxes, verified WSS and reconnect. The shared
OTP settings in `src/ba_core.app.src` provide `default_reception_desk_url`, bundled
with every native app. Override with `BA_RECEPTION_DESK_URL` at startup (an
empty value selects local-only transport), or issue bridge `configure_desk` with `url`
to explicitly start a fresh session. Swarm v2 invitations route through that desk;
local v1 invitations remain the separate developer transport.

`ba_swarm_wire` defines the validated JSON schema. `ba_swarms` owns admission,
membership, bounded histories and revocation for either transport. Its relay
admission path is asynchronous. `ba_network` reports relay connection presence
without inventing direct distribution edges. The desk never receives Erlang
cookies or executable terms. See [protocol](../../docs/RELAY_PROTOCOL.md) and
[launch/deployment guide](../Services/ReceptionDesk/README.md).

## On-demand audio diagnostics

`ba_node_diagnostics:read(NodeNameBinary)` checks current native cluster
membership and already-connected OTP node names, then uses
[`erpc:call/5`](https://www.erlang.org/doc/apps/kernel/erpc.html#call/5) with a
one-second requested timeout to read that node's `snapshot/0`. No new atom or
connection is created from the requested name. The local JSON command is
`node_diagnostics` with `node`. It returns `result.node_diagnostics` containing
node, sample time, and receiver/playback/handler/native-statistics fields.

This is a read-only snapshot for graph node details, fetched on selection or
manual Refresh. There is no metrics broadcast, chat message, persisted telemetry
or separate polling worker. Admission remains separate from connection liveness;
a permitted offline node cannot currently be read. Old app builds lacking the
endpoint report diagnostics unavailable. Captured audio, invitations and keys
are excluded from the diagnostic payload.
