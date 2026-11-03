# 0007 — Cluster clock pulls and monotonic mapping

Date: 2026-11-02. Status: first implementation; compiled and focused checks pass.

## Scope and OTP mechanisms

Prioritize a working clock boundary before adding the native audio engine.
Reuse `parvi_clock_sup` / `parvi_clock`, `pg` membership, OTP node monitoring,
`erpc` asynchronous requests, protected ETS reads and bounded `counters` metrics.
No new consensus service, cluster application, native clock library or dependency.

Each existing supervised clock worker participates in a group scoped to the
native cluster ID and permission epoch. Stable node-name ordering selects a
master among directly visible clocks. Membership/restart recreates the role
automatically. The master is a role on an existing clock worker, not a separate
VM and not a stored PID. Admission authority and clock ownership remain separate.

The small supporting refactors are a read-only trust-policy ETS snapshot and
immutable `parvi_clock_mapping` calculations. Clock discovery need not block on
an admission worker, and audio need not block on the clock worker.

## Coordination limit

This is deterministic connected-peer selection, **not globally unique election
under partitions or arbitrary sparse graphs**. OTP `pg` views may diverge and
are not transitive. A selected peer must agree that it is the requested current
master in the same scope; otherwise the sample fails visibly. Requests bind the
actual process incarnation; obsolete replies are abandoned when selection changes.

Coverage against saved native membership is reported, and incomplete coverage is
holdover. Master replacement follows observed group/process/node loss, not the
assumption that one slow request proves a master absent. Independently started
partitions can have their own provisional references; reconnecting direct peers
converges and followers slew toward the selected reference. A future strict sync
group must require an agreed master/timeline and measured quality. Do not claim
one authoritative global singleton from this implementation or enable `global`
as if its full-connectivity requirements were already satisfied.

This deliberately serves the current small directly connected cluster. It does
not solve millions of devices, full-mesh establishment or clock-distribution
hierarchy. Those need their own measured/topology decisions when required.

## Acquisition and schedule

Use one upstream acquisition when the selected master lacks usable time; prefer
an existing peer's valid mapping first. A promoted follower keeps its mapping.
A restarted master can inherit peer time without another upstream query. An
all-offline restart reacquires if no usable live mapping survives. Disconnected
cold-start components may acquire independently; there is no claim of one
query across unreachable components.

When saved native members are missing at cold startup, allow a bounded
`clock_peer_discovery_ms` interval (default 5000 ms) before acquiring upstream.
A newly visible peer triggers acquisition immediately. This gives the existing
reconnect flow time to restore a surviving reference without waiting forever.
A valid mapping does not incur this wait. The timer phase remains unchanged.

After acquisition, advance from monotonic elapsed time and stop routine external
polling. Followers pull every 30 seconds from their own worker's startup phase,
with immediate startup/reference-change acquisition and bounded failure retry.
One request is outstanding per worker. Delayed workers skip missed periods;
there is no global sweep, broadcast correction or catch-up burst. An unrelated
member joining does not reset all existing phases.

SNTP remains the existing binding and default METAS source. Missing/unusable
mapping or explicit refresh is a reason to acquire; ordinary expiry of the
30-second timer is not a reason to poll upstream again. Failed upstream requests
back off; refusals stop requests until an explicit operator action. Normal
`resync/0` retains upstream spacing. Clock settings remain application
configuration, not restored live execution state.

## Sample execution and mapping

RPC sample functions read ETS directly, so master mailbox work does not serialize
all samples. Requester send/receive and master receive/send timestamps establish
the four-timestamp estimate. Two counters summarize served requests and service
time, without per-device history. Async operations do not eliminate client
scheduling delay or network asymmetry; RTT and uncertainty remain visible.

Initial acquisition establishes a mapping. Later changes set a target and slew
at a bounded configured rate (default 500 ppm). Applied time never steps
backwards. Deadline inversion accounts for the active slew and chooses the
earliest local nanosecond reaching the requested time. Capture maps its capture
timestamp and expiry check using one immutable mapping. Native device clock
translation remains at the platform boundary.

This makes the application timeline continuous; it does not resample a DAC,
revisit buffers already queued to the OS or prove multi-speaker alignment.
The last measurement, age and residual correction are reported. Absolute current
UTC accuracy and oscillator drift are unknown without a measured bound; an old
point estimate is not advertised as permanent accuracy. Valid mappings remain
usable during holdover for the legacy prototype; strict future plans must apply
their synchronization requirements explicitly.

## Validation and next action

Focused tests use a local SNTP fixture and two standard OTP peer nodes, with the
real supervision tree and accelerated internal periods. They cover acquisition
counts, default cadence, time agreement, asynchronous serving with a suspended
master worker, one queued tick after missed periods, membership retirement,
takeover/inheritance and recreated master identity, and mapping/deadline math.
Existing native-worker supervision regressions also pass.

Updated Mac and signed iPhone builds were installed and run. Both agree on
master incarnation/timeline; master loss yields holdover/takeover, and restarts
with a surviving peer inherit the same timeline without successful upstream
acquisition. The first device run exposed the cold-start discovery race above;
the fix passes 12 focused checks and the repeated device run. No sample-rate
correction, large-scale benchmark or acoustic alignment measurement is included.
Next is the isolated GStreamer desktop proof. Keep further refactoring tied to an observed
clock/media boundary requirement.

## Primary references

- [OTP pg](https://www.erlang.org/doc/apps/kernel/pg.html): process lifecycle,
  eventual membership consistency and non-transitive views.
- [OTP erpc](https://www.erlang.org/doc/apps/kernel/erpc.html): asynchronous
  requests, response checking and abandonment on timeout.
- [OTP time correction](https://www.erlang.org/doc/apps/erts/time_correction.html):
  monotonic elapsed time and the distinction from system/POSIX time.
- [OTP global](https://www.erlang.org/doc/apps/kernel/global.html) and
  [distributed applications](https://www.erlang.org/doc/system/distributed_applications.html):
  documented connectivity/configuration requirements, not assumed here.
