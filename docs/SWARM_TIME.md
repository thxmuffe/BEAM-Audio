# Authenticated Time and Swarm Offset — step 7

The `swarm_control` profile now starts a local `parvi_clock` under its existing
clock supervisor, after control and before on-demand audio. It uses the Swarm
authority as the initial pinned reference and Offset writer. Devices never elect
an arbitrary reachable clock or promote themselves when the authority disappears.
There is no cross-device `pg`, `erpc`, remote PID or Distributed Erlang clock path.
The earlier explicit-node sample APIs return an unsupported-operation error.

## Configuration and API

Use the [membership configuration](SWARM_MEMBERSHIP.md). Explicitly grant members
`time_read` to sample the reference/read Offset, and `offset_write` to propose an
Offset edit. Neither Passport membership, status access nor an audio grant implies
these permissions. On the authority, for example:

```erlang
ok = parvi_swarm_membership:grant(DeviceId,
    [<<"offset_write">>,<<"stream_read">>,<<"stream_subscribe">>,<<"time_read">>]).
```

Lists must be sorted and unique. A member with `time_read` automatically establishes
or refreshes its control session to the pinned authority. It does not connect the
Swarm into an OTP mesh or automatically connect unrelated peer devices.

The authority's local `clock_reference` configuration supports `system` or
`{ntp,Host}` / `{ntp,Host,Port}`. `auto` resolves the configured upstream; the retained
default is `{ntp,"ntp.metas.ch"}`. Only the authority can change its reference using
`set_reference/1`; followers cannot choose a conflicting local reference. `system`
explicitly uses the authority host's POSIX time, not a claim of externally verified
UTC accuracy. Configuration changes are retained in the running application's
configuration; mapping/anchor state is never checkpointed.

```erlang
parvi_clock:status().
parvi_clock:offset_status().
{ok,OffsetMs} = parvi_clock:offset().
ok = parvi_clock:set_offset(250).
%% A caller that observed revision 3 can explicitly compare-and-set:
ok = parvi_clock:set_offset(300,3).
{ok,UTC} = parvi_clock:now().
{ok,LocalDeadline} = parvi_clock:to_monotonic(UTC).
```

Offset remains 5–30000 ms, initially 1000 ms. A local authority edit and an authorized
remote edit go through the same serialized writer. A stale expected revision
returns `conflict`; simultaneous edits against one revision cannot both commit.
Unchanged values do not create another revision. The writer checkpoints the
committed value/revision before replying and broadcasting to authorized readers.
A lost response is `unconfirmed`, not proof that the edit did not commit; read the
current revision before retrying. There is no unsupervised local override.

The PCM capture path uses `presentation/1` to read one immutable ETS snapshot:
clock ID, mapped capture/current times, committed Offset and its revision. It
stamps each source packet with its independent target. Unready clock, stale Offset
or changed publication clock ID prevents stamping; it does not substitute arrival
time. Existing packets keep their targets when Offset changes. A decrease may
make packet intervals overlap; bounded receivers explicitly reject those packets
rather than silently retiming already assigned audio.

## Signed wire and timestamp measurement

The existing signed control envelope adds `time.message`. Its flat payload schemas
are defined in `parvi_swarm_time_protocol`; normal peer/session/Swarm/policy/sequence
checks still apply. Requests require their separate permission before dispatch.
Unknown operations, extra fields and malformed timestamps are rejected. Replies
must match the pinned authority, current control session, request ID, operation,
request deadline and echoed first timestamp.

| Kind | Data |
| --- | --- |
| `sample.request` | Local monotonic `t1`. |
| `sample.reply` | Echoed `t1`, reference UTC `t2/t3`, reference instance, revision, timeline and measurement uncertainty. |
| `offset.get` | Current authoritative policy query. |
| `offset.set` | Expected revision and requested milliseconds. |
| `offset.state` | Correlated committed revision/value. |
| `offset.changed` | Writer's current revision/value over a live session. |
| `error` | Correlated operation and fixed forbidden/unavailable/conflict reason. |

Timestamp strings are canonical signed 64-bit decimal integers. This preserves
full nanosecond precision without relying on JSON/JavaScript's exact integer
range. Revision/value fields remain bounded JSON integers. No executable terms,
arbitrary diagnostics or remote functions cross the boundary.

The follower records `t1` before its local send. Control records raw receive
monotonic time before signature verification on both endpoints; the authority
maps that ingress to UTC `t2` and maps its response construction time to UTC `t3`.
The follower uses its ingress as `t4`. The existing four-timestamp measurement
subtracts responder service time from RTT and estimates UTC-minus-local-monotonic.
Queueing before send/after response construction remains part of the measurement;
network asymmetry and Desk/TLS latency remain real uncertainty.

Production defaults retain 5-second sampling, a 20-observation median window,
30-second correction checks, strict 2 ms correction deadband and at most 500 ppm
slew. At most one observation per sampling period enters the filter. The initial
follower mapping is available only once the real window fills; corrections reuse
the existing monotonic mapping/inverse and never step an established mapping
backward. Headless checks explicitly accelerate cadence/window, not production
quality requirements. Upstream acquisition happens once at startup or explicit
resync, not on every follower request. SNTP retains request spacing, bounded
failure backoff and kiss-of-death blocking until explicit operator resync/change.

## Freshness, changes and recovery

The timeline ID includes Swarm and a fresh authority clock incarnation. Every
reply carries its reference revision; changing either resets the follower filter.
A lower revision for the same incarnation is rejected. Authority clock restart
creates a new timeline; followers cannot use samples or mappings from the old one.
A same-timeline reference refresh resets the filter while preserving bounded
mapping continuity. Old publication descriptors remain fenced until republished
with the new clock ID; automatic native capture rebind is an integration gate.

Mapping reads check membership authorization, sample-session authorization, filter
readiness and a last-sample age of at most two sampling periods synchronously.
Offset reads also require a fresh writer observation and live authorization.
Absent deadlines use explicit unavailable state, never numeric zero (Erlang
monotonic values can be negative). Stale mappings remain diagnostic holdover;
they do not authorize new scheduling. Public status keeps measurement uncertainty,
RTT, age, reference identity/revision and filter counts, while current absolute
uncertainty and unmeasured oscillator drift remain unknown.

On control-owner restart, a new authenticated hello can prepare one bounded fresh
challenge beside the old session. Only a valid new proof replaces the old session
and fences its jobs/media; replaying a hello alone cannot tear down active work.
Candidates expire after 10 seconds. The clock reconnects to its pinned authority,
fetches current Offset and warms a new filter. Simultaneous-open resolution for
general peers is still outside this prototype.

Explicit clock resync invalidates readiness until fresh evidence returns. Audio
resume/handover asks for resync and requires a sample after its resume barrier.
Master status alone, cached UTC values or holdover do not bypass this gate.
Clock process restart destroys its ETS mapping; it restores only declarative
Offset state/version floor, then reauthorizes/reacquires.

`swarm_time_policy.term` stores the writer's Swarm/authority/Offset revision/value.
`swarm_time_cache.term` stores a member's version/value floor so stale or
same-revision conflicting content is rejected after restart. The cache does not
restore freshness. Storage failure terminates the owner rather than reporting an
uncheckpointed edit as committed. Epoch/permission changes still fence control
sessions independently of Offset revision. No clock mapping, timestamp exchange,
nonce, process identity or monotonic deadline is persisted.

## Evidence and remaining limits

From `src/control`:

```sh
rebar3 compile
rebar3 eunit --module=parvi_clock_tests,parvi_clock_mapping_tests,parvi_clock_filter_tests,parvi_swarm_time_protocol_tests,parvi_swarm_control_protocol_tests
```

From the core root:

```sh
python3 tests/control/swarm-time-smoke.py
PARVI_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time
```

The first proof uses two independent temporary Desk services and three unnamed
BEAM runtimes: signed sampling, explicit grants, forbidden/stale edits, competing
compare-and-set, broadcasts, durable Offset, control-owner recovery and fresh
filtering after reference restart. No app identity/state is loaded. The second
uses real WebRTC PCM and the production capture-stamping API with authenticated
clock/Offset, replacing only the output device with a scheduled headless sink.
It exercises two-source mixing, pauses, restoration, unsubscribe and Contracts.
The test launcher library-path requirement is documented in [the stream guide](SWARM_STREAMS.md).

These same-host, loopback-Desk checks do not establish Internet clock asymmetry,
external UTC accuracy, DAC timing or physical speaker alignment. The PCM prototype
still has a one-second target-lead/32-block queue bound: larger committed Offsets
fail explicitly there, and sustained operation across the supported Offset range
needs backend qualification in step 8. Native Opus decoded-audio mixing/handoff,
automatic capture rebind after clock-incarnation change, remaining old native
logging/app dependencies and platform execution are also still integration gates.
No product app, native audio device, deployment or physical listening was used.

Swarm identity and retained credentials already survive process shutdown, but an
ordinary member cannot replace an absent authority from cached policy. Returning
to a completely abandoned Swarm, including member-first recovery, is separately
planned as step 10; this clock increment does not invent authority succession.

Underlying mechanisms reuse [OTP monotonic-time facilities](https://www.erlang.org/doc/apps/erts/time_correction.html)
and [atomic ETS objects](https://www.erlang.org/doc/apps/stdlib/ets.html), with the
existing project median/filter, four-timestamp measurement and slew implementation.
