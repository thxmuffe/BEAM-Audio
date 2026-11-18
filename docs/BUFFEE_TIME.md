# Buffee Clock and Playback Offset

## Agreed next clock coordination — 2026-11-17

The Manager maintains one logical master on an ON AIR Device. Several Devices
may broadcast; keep the current broadcasting master until it stops. The ON AIR
privilege already permits Response time edits. Reuse existing synchronization
and OTP supervision, processes, timers and messaging to distribute updates about
every 30 seconds; receivers need no provider discovery. No new time-transfer
mechanism is requested. Manager coordination, this hosting rule and periodic
push remain unimplemented; current behavior below still uses follower sampling.

At 50,000 Devices and one update per 30 seconds there are about 1,667 deliveries/s
before other traffic. This is arithmetic, not a capacity measurement. Keep one
time source and distribute delivery work if measurements require it. The current
16-member/route bounds and all-pairs peer connections are not a 50,000-Device
architecture; increasing their limits is outside this increment.

## Current implementation

The clock provider is independent of ownership. The original reference is
preferred while present; otherwise an online ON AIR privilege holder is selected
by sorted Device ID. This checks the privilege, not whether audio is currently
broadcasting. Each Device derives the choice from its own observed online view;
there is no coordinated master announcement yet, so agreement during differing
presence views is not guaranteed by local OTP supervision.
A Device with a fresh acquired mapping continues that same timeline and committed
Response time. Followers obtain fresh authenticated samples from the new provider;
packet Presentation Targets are not changed. Without a usable mapping the provider
starts a new timeline seeded immediately from its own host clock. No saved clock
observations or guessed playback targets bypass acquisition.

The `buffee_control` profile runs `ba_buffee_clock` under its local OTP supervisor.
No cross-device `pg`, `erpc`, remote PID or Distributed Erlang clock path exists.
Clock service placement and permission to edit Response time do not grant ownership.
The implementation state `authority` below denotes the current time-service writer,
not the Device's Owner role. Device clock drift and physical output alignment remain
unqualified; software handover is not proof of acoustic synchronization.



## Configuration and API

Use the [membership configuration](BUFFEE_MEMBERSHIP.md). `time_read` permits
sampling the reference and reading Response time. Only Devices holding `grant`
or `on_air` can change Session-wide Response time; an old `offset_write` flag
alone grants no such permission. Hosting the clock process also grants nothing.
For example, a `grant` holder can put a Device on air:

```erlang
ok = ba_buffee_membership:grant_privilege(DeviceId,ba_session_privileges:wire(on_air)).
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

Offset remains 5–30000 ms, initially 150 ms. A local authority edit and an authorized
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
| `offset.required` | An ordinary time reader's measured absolute minimum; acted on only in Automatic mode. |
| `offset.state` | Correlated committed revision/value. |
| `offset.changed` | Writer's current revision/value over a live session. |
| `error` | Correlated operation and fixed forbidden/unavailable/conflict reason. |

Automatic mode is an optional boolean `automatic` in the revisioned policy and
`offset.set`, `offset.state` and `offset.changed` messages. Absence means false;
manual-mode payloads retain their existing shape. The public Device API uses
`{"method":"offset","automatic":true}` to enable it at the current delay;
selecting a numeric `offset_ms` disables it. Both actions retain the existing
settings-edit privilege check. An `offset.required` request needs only
`time_read`, carries `revision` and `offset_ms`, and cannot enable Automatic.
The authority treats the request as an absolute minimum, applies the shared
`ba_audio_response_time` diminishing-gain curve and commits any increase itself.
It never decreases the value or raises beyond 2999 ms. Old requirements cannot
add the same relative delta repeatedly; manual mode ignores them. Audio warnings
show the complete measured estimate even when automatic growth is limited.
Update participating clients before enabling Automatic: older clients cannot
interpret the added policy field. Reception remains unchanged.

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

Sampling starts as soon as authorized Session membership and the master's
authenticated control connection are available, independently of playback.
Initial acquisition requests up to five samples at 250 ms spacing (one request
in flight); it finishes after five replies or two seconds after the first valid
reply. The lowest-RTT observation sets the initial mapping directly. Until that
commit, raw time remains visible through `now/0`, but `presentation/1`,
`to_monotonic/1` and automatic subscription restoration wait. Thus a provisional
anchor can change before audio targets are assigned or executed. The selected
observation seeds the median window; the burst does not fill it with clustered
samples. `initial_sync_complete`, `initial_sync_samples` and
`initial_sync_round_trip_ns` expose this acquisition separately from filter quality.
The two-second bound begins with a valid reply, not with joining a disconnected
or unauthorized Session, and remains subject to process scheduling delays.

After initial acquisition, production defaults retain 5-second sampling,
a 20-observation median window,
30-second correction checks, strict 2 ms correction deadband and at most 500 ppm
slew. At most one observation per sampling period enters the filter. The initial
follower's raw mapping is available from its first authenticated sample; after
initial calibration, partial median estimates refine it while the window fills.
Corrections reuse
the existing monotonic mapping/inverse and never step an established mapping
backward. Headless checks explicitly accelerate cadence/window, not production
quality requirements. `estimate_quality` distinguishes provisional and filtered
estimates; `filter_ready` reports window fullness rather than gating time.
The master seeds its host clock immediately, so external SNTP availability does
not prevent Session time. Upstream acquisition happens at startup or explicit
resync, not on every follower request. SNTP retains request spacing, bounded
failure backoff and kiss-of-death blocking until explicit operator resync/change.



## Freshness, changes and recovery

Mapping reads check membership authorization, sample-session authorization and
a last-sample age of at most two sampling periods synchronously. Filter quality
is reported separately; it does not prevent using fresh authenticated raw time.
Offset reads also require a fresh writer observation and live authorization.
Absent deadlines use explicit unavailable state, never numeric zero (Erlang
monotonic values can be negative). Stale mappings remain diagnostic holdover;
they do not authorize new scheduling. Public status keeps measurement uncertainty,
RTT, age, reference identity/revision and filter counts, while current absolute
uncertainty and unmeasured oscillator drift remain unknown.

`state: synchronized` currently means usable authorized mapping with fresh
evidence, not demonstrated alignment within a specified error. It does not test
the remaining correction, measurement uncertainty or filter fullness. The 2 ms
deadband is a correction trigger, not an accuracy guarantee. A full 20-sample
median is not an independent alignment check. At 500 ppm, removing a 100 ms
error takes 200 seconds after correction starts; checks run every 30 s.
This can permit long settling while reporting synchronized. Initial acquisition
now avoids slewing the first provisional anchor, but errors discovered afterward
still have this limit. The slow-settling mechanism was not measured during the
owner's earlier silent start.
The filter uses median offset without RTT weighting; samples up to 4 s RTT can
be accepted. Unequal outward/return delays can bias the estimate.

Sample gaps up to 60 s preserve the filter, but scheduling readiness still
expires after 10 s under the default cadence. Filter retention does not extend
the readiness or Response-time freshness deadlines. Native host-clock mapping
and actual audio-device latency add further error; software clock status does
not establish acoustic synchronization.

Follower resync invalidates readiness until fresh evidence returns. A master
refreshes its host-clock observation immediately and can refine it externally.
Audio resume/handover requires an observation after its resume barrier.
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
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --buffee-time
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

Underlying mechanisms reuse [OTP monotonic-time facilities](https://www.erlang.org/doc/apps/erts/time_correction.html)
and [atomic ETS objects](https://www.erlang.org/doc/apps/stdlib/ets.html), with the
existing project median/filter, four-timestamp measurement and slew implementation.
