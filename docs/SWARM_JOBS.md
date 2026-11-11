# Contracts and Jobs — step 4

Implemented for ordinary granted coordinators (updated 2026-11-11) and the predefined
non-audio test Worker. This extends the [control protocol](SWARM_CONTROL_PROTOCOL.md)
and [local Handler](DEVICE_HANDLER.md) under the [active roadmap](PLAN.md).
It is not a generic remote execution API, audio assignment system or scheduler.

## Roles and permission

A Director is ordinary programmed coordination on an admitted Device. It gains
no ambient permissions from that role. Any admitted Device may offer/cancel jobs
where `job_offer` is granted, and the receiving Device still requires its local
matching Contract, consent and capacity. The wire policy retains its legacy
`director` field for message-scope compatibility; it is not a job privilege gate.
No arbitrary remote process, module or function invocation is introduced.

The receiver separately installs a narrow local Contract and opts in:

```erlang
ok = ba_device_handler:set_test_contract(DirectorId, ContractId, 1).
ok = ba_device_handler:enable_test(true).
```

Contract IDs are 128-bit/32-uppercase-hex values; revisions are positive bounded
integers. The Contract permits only the installed `test` capability, at most
two active Workers with durations/leases of 20–10000 ms. IDs/revisions are explicitly
provisioned to the two proof runtimes; automatic Contract discovery/negotiation
is not implemented. [Step-5 membership](SWARM_MEMBERSHIP.md) now supplies current authority policy and
revocation checks; a Passport still never supplies local Contract/consent.

The Handler checks the verified sender against the local Contract's coordinator,
Contract ID/revision, local
consent, capacity and session lifetime before acceptance. Evaluation and acceptance
are one serialized local operation for this simple task, not a second reservation
framework. The Handler alone builds the known test-Worker child specification.
No remote module, function, PID, native handle, microphone or speaker command is
accepted. Other loaded local Erlang code remains trusted, not sandboxed.

Replacing/revoking the Contract stops affected network jobs; a stale revision
for the same Contract is rejected. `clear_test_contract()` revokes network test
work without stopping unrelated locally started Workers. Disabling test consent
stops both local and network test work. Grants are not persisted or restored after
Handler restart. Contract revisions are distinct from the outer Swarm policy revision.

## Offer, acknowledgement and result

On the Director:

```erlang
Offer = #{<<"contract">> => ContractId, <<"contract_revision">> => 1,
          <<"capability">> => <<"test">>, <<"duration_ms">> => 1000,
          <<"lease_ms">> => 5000},
{ok, JobId} = ba_swarm_control:offer_job(ReceiverId, Offer).
ba_swarm_control:job_status(JobId).
ok = ba_swarm_control:retry_job(JobId).
ok = ba_swarm_control:cancel_job(JobId).
```

Offers are directed advertisements to one Device in the first proof. No broker,
broadcast tree or new Director process is needed: the existing control actor owns
the Director's offer/result records; the Device Handler owns accepted obligations.

`offer_job` confirms local submission and returns a fresh Job ID, not acceptance
or execution. The signed header's `request` field is that Job ID. The exact
`job.offer` payload is the five fields above; `job.cancel` has an empty object.
Authenticated operations retain session, policy, recipient and replay checks.

The control adapter hands verified offers/cancels to the Handler using OTP
`gen_server:send_request` and a bounded request collection. It does not block the
control mailbox waiting for resource decisions or grant a peer supervisor access.
The Handler accepts only calls from that local control process.

The Handler starts a local Worker on acceptance and returns `job.report`:

```erlang
#{<<"attempt">> => AttemptId, <<"state">> => <<"accepted">>,
  <<"reason">> => <<"none">>}
```

The same attempt later reports completed, failed, cancelled or expired. A rejected
offer reports rejected with a null attempt and a fixed reason such as
contract_mismatch, consent_required or capacity_exceeded. Reports are observations
from the assignee; they do not prove physical work or speaker output. The Director
checks assignee/session/Job ID/attempt and fences conflicting or stale results.
Acknowledgement and completion are separate protocol steps.

## Lease, cancellation and retry

The receiver's finite lease starts at first local acceptance and is clipped to
its authorizing session deadline. It uses local monotonic time, with explicit
expiry handling and completion-deadline checks. The test Worker is stopped through
its supervisor before releasing the slot. A Worker failure is reported; no
automatic Worker/job restart is attempted.

This is an acceptance-relative lease, not a synchronized absolute execution
deadline or a promise about network delivery time. The Director waits at most
five seconds for acceptance; after the first accepted report it waits up to the
requested lease for a result, capped by its session. Repeated accepted reports
never extend that observation deadline. Delayed/lost acknowledgements can leave
the result unconfirmed; messaging timeout does not prove that nothing ran.

Identical retries in the same session return the original attempt/outcome without
starting another Worker or extending the receiver lease. A changed offer under
the same ID is rejected. Rejected/terminal IDs do not become new work when local
consent changes. Cancellation is idempotent; a cancellation received before an
offer leaves a tombstone that prevents later acceptance under that ID.

The Director fences acceptance/completion reports after local cancellation or
timeout. It may resolve that state with a matching cancellation/expiry/failure
report, otherwise status remains cancel_pending/unconfirmed. A completion racing
with cancellation is not silently advertised as a newly completed attempt.
Cancellation delivery is best effort; the receiver's own lease still bounds work.

There are at most 32 Director records per control-process lifetime, 32 incoming
deduplication records at the Handler, and 32 pending Handler request handles.
Incoming records are retained until their session closes; no live retry history
is evicted to make space. Reaching a limit rejects new work. There is no durable
exactly-once guarantee across session/process/VM restart. The first task is
idempotent and no uncertain job is replayed automatically after return.

## Failure boundaries

- Observed peer absence, Desk loss or session expiry closes the relevant session
  and stops its jobs. Membership is not revoked by that observation.
- A peer/Director crash may be reported late by the relay. Until loss is observed,
  the independently enforced receiver lease bounds work. The real-Desk loss test
  observed this lease-based cleanup; it does not establish immediate failure detection.
- The Handler monitors its local control owner. Control death stops network jobs
  and clears their volatile records while unrelated local Workers continue.
- Handler death stops its Worker branch before replacement. The control adapter
  fences old sessions because the Handler's deduplication/Contract state was lost;
  fresh consent/Contract and fresh session/job decisions are needed. It does not
  fabricate a remote completion or automatically elect another Director.

All expiry/stop decisions are Erlang-owned prototype lifecycle behavior. They
are not real-time native/audio deadline qualification or a new correction policy.

## Checks and next increment

From `src/control`:

```sh
rebar3 eunit --module=ba_swarm_job_tests,ba_device_handler_tests,ba_swarm_control_protocol_tests,ba_relay_tests,ba_native_tests
rebar3 compile
```

From the core root: `python3 tests/control/swarm-control-smoke.py` runs two
disposable unnamed BEAM runtimes through the existing public Desk. It checks
offers, local Contract rejection, accepted/completed attempt identity, retry,
cancellation, expiry, Worker crash and bounded cleanup after Director loss, plus
the earlier status/capability/authentication checks. No product app, saved app
state, private app identity, separate Desk, audio or GUI is used.

[Passports, current policy/revocation on return and multi-Desk introductions](SWARM_MEMBERSHIP.md)
are implemented in step 5. Audio subscriptions are step 6; applications remain step 9 in the
macOS → Windows → iOS order. No app build/deployment is part of this increment.

Primary references: [OTP asynchronous requests](https://www.erlang.org/doc/apps/stdlib/gen_server.html#send_request/2)
and [OTP local supervision](https://www.erlang.org/doc/system/sup_princ.html).
Their process/request mechanisms are reused; Contract and Job semantics are
explicit project behavior.
