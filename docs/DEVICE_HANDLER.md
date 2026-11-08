# Local Device Handler and Workers — step 3

Implemented scope: a supervised local Handler, capability discovery and one
installed non-audio test Worker. The [Swarm plan](PLAN.md) and
[boundary contract](SWARM_CONTRACT.md) remain authoritative. Director job offers,
Contract evaluation/acceptance and leases are now implemented for that test
capability in [step 4](SWARM_JOBS.md). No hardware capture,
playback, DSP, app UI or arbitrary Worker module loading is implemented here.

## Supervision and ownership

The `swarm_control` runtime now starts this local hierarchy:

```text
parvi_sup                         one_for_one
  parvi_device_sup                rest_for_one
    parvi_device_handler          permanent
    parvi_device_worker_sup       one_for_one
      test Workers                temporary, created only on local acceptance
  parvi_swarm_control             permanent; existing linked Desk relay
```

The Handler owns local consent, capacity, Worker records and attempts. It builds
the fixed child specification; no request supplies a module or start function.
The worker supervisor supplies OTP start/stop mechanics. Existing audio supervisors
and sessions are not moved or duplicated: their Handler integration belongs to
the later audio increment once its permissions and stream lifecycles are ready.

A Worker crash reports failed, releases capacity after the monitored process is
down, and leaves the Handler/other Workers running. Temporary children never
restart blindly. A new local decision starts a fresh Worker ID and attempt.
Handler failure causes `rest_for_one` to stop its worker supervisor and children
before replacing the Handler; the new Handler has a fresh instance, no old
attempts and consent disabled. Worker-supervisor failure stops its children and
is recovered locally; the Handler observes their failures. Control sessions are
a separate sibling, and subsequent capability queries see the current Handler.

## Local API

After starting the configured headless Swarm runtime, these calls are available:

```erlang
parvi_device_handler:capabilities().
parvi_device_handler:status().
ok = parvi_device_handler:enable_test(true).
{ok, WorkerId} = parvi_device_handler:start(test, #{duration_ms => 1000}).
ok = parvi_device_handler:cancel(WorkerId).
ok = parvi_device_handler:enable_test(false).
```

Only `test` is installed/advertised. It waits 20–10000 ms, reports ready and
completed, then exits. It performs no audio/device/network operations. At most
two Workers run together; another request returns `capacity_exceeded`. Starting
without local opt-in returns `consent_required`. Invalid durations, other kinds
and extra argument fields are rejected without creating a process.

Revoking consent stops the active test Workers through their supervisor before
returning. Cancel is idempotent for retained terminal records. Status keeps at
most two active records and the latest 16 outcomes; no work/consent is persisted.
Worker reports bind their local PID, Worker ID and fresh attempt; obsolete or
unrecognized reports are ignored. Completion does not release a slot until the
process is actually down. A Worker also monitors its owner.

These are trusted **local** calls, not a sandbox against other loaded code.
The new runtime has no cross-device OTP connectivity. No remote operation directly
invokes `enable_test`, `start`, `cancel` or `supervisor:start_child`. A step-4 job
offer goes through authenticated control and local Handler Contract/consent checks;
only the Handler decides to instantiate or stop its fixed test Worker.

## Capability advertisement

The Handler's bounded snapshot describes only installed, usable support:

```erlang
#{<<"instance">> => HandlerInstance,
  <<"revision">> => Revision,
  <<"test">> => #{<<"supported">> => true, <<"available">> => false,
      <<"requires_consent">> => true, <<"consent">> => false,
      <<"capacity">> => 2, <<"active">> => 0,
      <<"max_duration_ms">> => 10000}}
```

`available` requires consent, free capacity and a live local worker supervisor.
It does not promise that a later request will still fit. Instance changes on
Handler restart; revisions identify changes within one instance. Audio inputs,
outputs and DSP are not advertised as supported by this test capability.

An authenticated peer may call
`parvi_swarm_control:read_capabilities(PeerId)` only when the receiving Device's
local policy grants that peer `capabilities_read`. Configure grants as sorted,
unique subsets of `[capabilities_read,job_offer,status_read]`. Status permission alone does
not grant capability access, and neither permission grants execution.

The [control protocol](SWARM_CONTROL_PROTOCOL.md) adds exact-shape
`capabilities.read`, `capabilities.reply` and `capabilities.error` operations.
Replies carry the snapshot above; errors are `forbidden` or `unavailable`.
The adapter queries the Handler only after verified/authorized dispatch, with a
100 ms local read timeout. Reply operation and request ID must match the pending
query. Status/capability reads share the existing one-pending-request-per-peer
bound, session expiry and replay checks. There is no capability polling service
or arbitrary remote Worker creation. The [job guide](SWARM_JOBS.md) describes the
separate execution permission/Contract, asynchronous evaluation and failure cleanup.

## Checks and limits

From `src/control`:

```sh
rebar3 eunit --module=parvi_device_handler_tests,parvi_swarm_control_protocol_tests,parvi_relay_tests,parvi_native_tests
rebar3 compile
```

From the core root: `python3 tests/control/swarm-control-smoke.py` explicitly
starts two disposable headless runtimes through the existing public Desk. It
checks capability reads/local consent changes and rejects forbidden commands,
forgery and replay without creating Workers remotely. It launches no product app
and uses no saved app identities, Swarms or subscriptions.

The focused lifecycle tests cover completion, capacity, cancellation, consent
withdrawal, Worker/Handler/worker-supervisor crashes, fresh attempts, stale events
and bounded history. These establish the test lifecycle only; they do not prove
native audio resource recovery, Director jobs, OS permissions or physical timing.
App/device integration remains step 9: macOS, Windows, then iOS.

OTP references: [supervision strategies](https://www.erlang.org/doc/system/sup_princ.html)
and [supervisor child termination](https://www.erlang.org/doc/apps/stdlib/supervisor.html#terminate_child/2).
The Handler makes resource decisions; OTP supplies process lifecycle mechanics.
