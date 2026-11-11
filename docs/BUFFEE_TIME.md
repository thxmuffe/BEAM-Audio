# Buffee Clock and Playback Offset — step 7

The clock provider is independent of ownership. The original reference is
preferred while present; otherwise an online Chef is selected deterministically.
A Chef with a fresh acquired mapping continues that same timeline and committed
Response time. Followers obtain fresh authenticated samples from the new provider;
packet Presentation Targets are not changed. Without a usable mapping the provider
must acquire a new timeline and report unavailability until ready. No saved clock
observations or guessed playback targets bypass acquisition.

The `buffee_control` profile runs `ba_buffee_clock` under its local OTP supervisor.
No cross-device `pg`, `erpc`, remote PID or Distributed Erlang clock path exists.
Clock service placement and permission to edit Response time do not grant ownership.
The implementation state `authority` below denotes the current time-service writer,
not the Device's Owner role. Device clock drift and physical output alignment remain
unqualified; software handover is not proof of acoustic synchronization.

## Configuration and API

Use the [membership configuration](BUFFEE_MEMBERSHIP.md). Explicitly grant members
`time_read` to sample the reference/read Offset, and `offset_write` to propose an
Offset edit. Neither Passport membership, status access nor an audio grant implies
these permissions. On the authority, for example:

```erlang
ok = ba_buffee_membership:grant(DeviceId,
    [<<"offset_write">>,<<"stream_read">>,<<"stream_subscribe">>,<<"time_read">>]).
```

Lists must be sorted and unique. A member with `time_read` automatically establishes
or refreshes its control session to the pinned authority. It does not connect the
Buffee into an OTP mesh or automatically connect unrelated peer devices.

The authority's local `clock_reference` configuration supports `system` or
`{ntp,Host}` / `{ntp,Host,Port}`. `auto` resolves the configured upstream; the retained
default is `{ntp,"ntp.metas.ch"}`. Only the authority can change its reference using
`set_reference/1`; followers cannot choose a conflicting local reference. `system`
explicitly uses the authority host's POSIX time, not a claim of externally verified
UTC accuracy. Configuration changes are retained in the running application's
configuration; mapping/anchor state is never checkpointed.

```erlang
ba_buffee_clock:status().
ba_buffee_clock:offset_status().
{ok,OffsetMs} = ba_buffee_clock:offset().
ok = ba_buffee_clock:set_offset(250).
%% A caller that observed revision 3 can explicitly compare-and-set:
ok = ba_buffee_clock:set_offset(300,3).
{ok,UTC} = ba_buffee_clock:now().
{ok,LocalDeadline} = ba_buffee_clock:to_monotonic(UTC).
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
are defined in `ba_buffee_time_protocol`; normal peer/session/Buffee/policy/sequence
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
network asymmetry and Reception/TLS latency remain real uncertainty.

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

The timeline ID includes Buffee and a fresh authority clock incarnation. Every
reply carries its reference revision; changing either resets the follower filter.
A lower revision for the same incarnation is rejected. Authority clock restart
creates a new timeline; followers cannot use samples or mappings from the old one.
A same-timeline reference refresh resets the filter while preserving bounded
mapping continuity. Old publication descriptors remain fenced until rebound to a
new incarnation with the new clock ID; step 8's PCM recovery proof verifies that
automatic path. Native capture/output qualification remains step 9.

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
fetches current Offset and requires a fresh sample. Step 8d now renews ordinary
authorization in place using fresh two-way nonce proof: the session ID, live clock
mapping and observations remain, and subsequent signed samples carry the new
bounded deadline. If a session is actually lost, readiness is invalidated until
fresh evidence returns; same-reference fresh observations may be retained.
Resetting the entire window on every 60-second renewal would prevent the default
20 × 5-second acquisition.
Changed scope/reference, stale observations and explicit resync still clear the
window; clock restart restores no observations. Simultaneous-open resolution for
general peers is still outside this prototype.

Explicit clock resync invalidates readiness until fresh evidence returns. Audio
resume/handover asks for resync and requires a sample after its resume barrier.
Master status alone, cached UTC values or holdover do not bypass this gate.
Clock process restart destroys its ETS mapping; it restores only declarative
Offset state/version floor, then reauthorizes/reacquires.

`buffee_time_policy.term` stores the writer's Buffee/authority/Offset revision/value.
`buffee_time_cache.term` stores a member's version/value floor so stale or
same-revision conflicting content is rejected after restart. The cache does not
restore freshness. Storage failure terminates the owner rather than reporting an
uncheckpointed edit as committed. Epoch/permission changes still fence control
sessions independently of Offset revision. No clock mapping, timestamp exchange,
nonce, process identity or monotonic deadline is persisted.

## Evidence and remaining limits

From `src/control`:

```sh
rebar3 compile
rebar3 eunit --module=ba_buffee_clock_tests,ba_buffee_clock_mapping_tests,ba_buffee_clock_filter_tests,ba_buffee_time_protocol_tests,ba_buffee_control_protocol_tests
```

From the core root:

```sh
python3 tests/control/buffee-time-smoke.py
python3 tests/control/buffee-time-smoke.py --production-cadence
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --buffee-time
```

The first proof uses two independent temporary Reception services and three unnamed
BEAM runtimes: signed sampling, explicit grants, forbidden/stale edits, competing
compare-and-set, broadcasts, durable Offset, control-owner recovery and fresh
filtering after reference restart. No app identity/state is loaded. The second
uses real WebRTC PCM and the production capture-stamping API with authenticated
clock/Offset, replacing only the output device with a scheduled headless sink.
It exercises two-source mixing, pauses, restoration, unsubscribe and Contracts.
The production-cadence variant runs the real 20 × 5-second window across
60-second control-session renewal. The test launcher library-path requirement is
documented in [the stream guide](BUFFEE_STREAMS.md).

These same-host, loopback-Reception checks do not establish Internet clock asymmetry,
external UTC accuracy, DAC timing or physical speaker alignment. Step 8 adds
bounded binary queues covering 30-second Offset in virtual time, continuous
1000 ms PCM scheduling and reference-restart capture rebind, plus real Opus
decoded-audio mixing/handoff. Existing timestamp, median, slew and independent
packet-target calculations remain unchanged. Actual platform capture/output,
native decoder packaging and physical listening/timing remain step-9 gates;
small configured Offsets may still be below a particular device/network's needs.
No product app, native audio device, deployment or physical listening was used.

Buffee identity and retained credentials already survive process shutdown, but an
ordinary member cannot replace an absent authority from cached policy. Returning
to a completely abandoned Buffee, including member-first recovery, is separately
planned as step 10; this clock increment does not invent authority succession.

Underlying mechanisms reuse [OTP monotonic-time facilities](https://www.erlang.org/doc/apps/erts/time_correction.html)
and [atomic ETS objects](https://www.erlang.org/doc/apps/stdlib/ets.html), with the
existing project median/filter, four-timestamp measurement and slew implementation.
