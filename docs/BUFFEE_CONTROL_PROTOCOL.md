# Buffee control protocol v1 — steps 2–8d

Implemented 2026-11-08 under the [Buffee plan](PLAN.md) and
[boundary contract](BUFFEE_CONTRACT.md). This implements authenticated status
and capability reads plus the [bounded test-job flow](BUFFEE_JOBS.md).
[Admission/Passports](BUFFEE_MEMBERSHIP.md) and [scoped stream signaling](BUFFEE_STREAMS.md)
are implemented separately; media does not travel through this Reception protocol.

## Runtime and local configuration

`ba_runtime:start(buffee_control)` now uses the [step-5 membership configuration](BUFFEE_MEMBERSHIP.md).
The earlier locally provisioned peer-policy fixture has been replaced by
nonce-bound authority admission and signed current policy. `ba_buffee_desks`
owns desired Reception routes; independently supervised relay Workers own connections.
The membership owner installs policy/routes
into control. The local Device branch owns the Handler and its initially empty
Worker supervisor. This profile starts the Buffee Clock, not old chat or the
trust/distribution carrier; audio starts on local demand. Both stable identity seed and private state directory
are required. Product app integration remains step 9.

Current runtime policy pins Buffee, authority, Manager, epoch/revision and per-sender
operation grants. Membership alone grants no operations. `job_offer` additionally
requires the job_offer grant and recipient's matching local Contract/consent.
The [Handler guide](DEVICE_HANDLER.md) describes that local lifecycle.

Call `ba_buffee_control:connect(PeerId)` on one endpoint, then wait until both
`snapshot/0` results show `stage => authorized` for the peer. Both endpoints can
call `read_status(PeerId)`. Successful replies contain only
`#{<<"protocol">> => 1, <<"session">> => <<"authorized">>}`.
`read_capabilities(PeerId)` returns the Handler's bounded test capability snapshot
when the peer has the separate capability grant; reading never enables Workers.
`ba_runtime:connect/1` is the old OTP API and is not used by this profile.

## Wire, authentication and dispatch

The existing Reception v1 transport routes exactly this payload shape:

```json
{"type":"buffee_control","buffee":"BUFFEE_ID","packet":"ENCODED_ENVELOPE_JSON"}
```

`packet` contains UTF-8 JSON bytes, at most 32768 bytes excluding the Reception wrapper.
Its fields are exactly `body` (base64 JSON bytes) and `signature` (128 uppercase
hex Ed25519 signature characters). Sign the exact decoded body bytes prefixed
with `beamaudio-buffee-control/v1:`. The body has these exact fields:

| Fields | Meaning |
| --- | --- |
| `v` | Integer 1. |
| `from`, `to`, `buffee` | Sender, intended recipient, Buffee. Reception `from` must match the signer; recipient must be local. |
| `authority`, `manager`, `epoch`, `revision` | Pinned authority/Manager Device IDs and exact locally installed policy version. |
| `session` | Fresh 128-bit/32-hex session ID. |
| `seq` | Nonnegative integer up to 9007199254740991; strictly increasing per application-message direction. |
| `op`, `request`, `payload` | Fixed operation, 128-bit/32-hex correlation ID, exact operation-specific object. |

| Operation | Payload and required state |
| --- | --- |
| `hello` | Fresh 256-bit/64-hex initiator nonce `a`; `b`: null. Configured peer with no existing session. |
| `challenge` | Echoes `a`, supplies fresh 256-bit/64-hex responder nonce `b`. Matching pending hello. |
| `proof` | Echoes both nonces. Matching pending challenge. |
| `ready` | Echoes both nonces. Matching pending proof. Completes mutual authentication. |
| `lease.request` | Fresh correlation ID and nonce `a`, `b`: null, within an already authorized session. Starts bounded proactive renewal. |
| `lease.challenge` | Echoes `a`, supplies fresh `b`; must match the pending renewal request. |
| `lease.proof` | Echoes both renewal nonces; a valid matching fresh proof permits the responder's lease extension. |
| `lease.ready` | Confirms both renewal nonces; a valid matching confirmation permits the initiator's extension. |
| `status.read` | Empty object. Authorized unexpired session, new sequence and peer's local `status_read` grant. |
| `status.reply` | `protocol`: 1, `session`: `authorized`. Matching outstanding unexpired read to that peer. |
| `status.error` | `reason`: `forbidden`. Correlated response when peer lacks read permission. |
| `capabilities.read` | Empty object. Authorized session/new sequence and a `capabilities_read` grant. |
| `capabilities.reply` | Exact Handler instance/revision and test capability described in [DEVICE_HANDLER.md](DEVICE_HANDLER.md#capability-advertisement). Must match a pending capability query. |
| `capabilities.error` | `reason`: `forbidden` or `unavailable`. Matching pending capability query. |
| `time.message` | Exact timestamp/Offset schemas in the [Time guide](BUFFEE_TIME.md); separate time_read/offset_write grants and correlated authority replies. |
| `stream.message` | Exact flat catalogue/subscription/SDP/ICE schemas in the [stream guide](BUFFEE_STREAMS.md); requests require separate stream grants, responses must match a local attempt. |
| `job.offer` | Exact test capability/Contract/duration/lease fields; job_offer grant and matching local coordinator Contract. Header request is the Job ID. Handler independently accepts/rejects. |
| `job.cancel` | Empty object; verified coordinator, same grant and owned Job/session scope. |
| `job.report` | Exact attempt/state/reason object. Adapter checks the Manager record's assignee, session, Job ID, attempt and result fence. |

Initial handshake messages use sequence 0 and `request == session`; application
messages, including lease renewal, use the existing strictly increasing sequence.
All messages bind both identities, Buffee, session and policy version;
handshake continuations bind both nonces. Replayed hello can obtain a bounded
fresh challenge after an old session is gone, but captured proof cannot answer it.

Reject unknown fields/versions/operations, duplicate keys, arrays, extra JSON
values, excess nesting, malformed IDs/types and wrong policy/recipient. Size is
checked before envelope decoding; signature verification precedes body dispatch.
No network string becomes an atom. Invalid input changes no replay/pending state;
the adapter also rolls back a job report's sequence if its local correlation check fails.
No executable terms, arbitrary diagnostics, module/function calls, credentials
or audio are accepted. The separate bounded test job is fixed data, not a module/
function invocation; its Worker is selected by the local Handler. OTP-admission
signatures use a different domain.

Transport is currently ordered Reception WSS with verified public TLS. The Reception can
observe payloads; signing does not supply end-to-end encryption. WebRTC control
and its DTLS fingerprint binding are not implemented or claimed by this step.

## Limits and failure behavior

Initial handshake expiry is 10 seconds; authorization lasts at most 60 seconds
from the latest completed fresh proof, capped by current local membership.
The lower Device ID initiates renewal after one third of that interval (normally
20 s). An exchange has a 5 s timeout and one pending record per peer; premature
or repeated exchanges are rejected. Failed exchanges retry while the old lease
remains valid; failure never extends it. Exact current policy, fresh nonce proof
and the replay sequence remain mandatory. The session ID/sequence continue, so
eligible media retains its transport and buffers on ordinary renewal.

One status or capability request per peer may be outstanding,
with a 5-second response deadline. Local monotonic deadlines are checked on
receive/request and on a 250 ms cleanup tick. Expiry or policy invalidation drops
affected sessions and completes waiting callers with an error. Reception loss alone
does not reset authorization or healthy sessions. Routes can use another configured
Reception; lack of timely fresh authorization still enforces expiry. Presence cleanup
checks other live Receptions before declaring a peer unavailable. Duplicate/lower
sequences and replies without a live correlation are rejected. The clock reconnects
to its authority if a session is actually lost. A bounded parallel challenge permits
a fresh proof to replace a surviving remote session after owner restart; a hello
alone never tears it down. General simultaneous-open resolution is not implemented.

Relay deliveries are dropped when the control owner's mailbox already has 64
messages; outgoing traffic retains existing relay queue/frame bounds. The Reception
retains its own limits. Local send acceptance is not remote receipt; overload/drop
may produce a request timeout. Bounded diagnostics identify owner overload and
transport failures; local media renewal/fencing notifications are not silently
dropped behind PCM traffic. This is bounded prototype behavior, not a public
capacity claim. The pure protocol module owns validation/transitions; the control
process owns timers, waiting local callers, Manager job records and Reception I/O.
Verified job offers/cancels use bounded OTP asynchronous Handler requests, not a
blocking remote/local execution wait. An authorized capability
request triggers a bounded 100 ms local Handler read; failure produces unavailable.
Capability responses include a signed instance/revision, fixed support/consent/
availability flags and bounded capacity/duration counts, without process IDs.
Public snapshots expose
identity, session stages/deadlines/renewal counts, relay status, bounded diagnostic
counters and rejection summaries, without keys or nonce state. OTP status
and termination formatting redact private keys and internal message/log content.

## Previous membership and subscription state

At the user's request, new builds ignore version-1 `ba_device_store` records:
policy, authority, remembered Reception routes and subscription intent. New saves use
version 2; other unsupported formats fail visibly. Secure device identity keys
are separate and unchanged. This is an intentional clean start, not a migration
of old permissions or revocation of other Devices. Old files remain until
replaced; they are not imported. Installed old bundles were not launched or
altered and still contain their old code. App integration/launch is step 9.

## Validation

From `src/control`:

```sh
rebar3 compile
rebar3 eunit --module=ba_buffee_job_tests,ba_device_handler_tests,ba_buffee_control_protocol_tests,ba_relay_tests,ba_native_tests
```

From the core root, explicitly run the real-Reception check:

```sh
python3 tests/control/buffee-control-smoke.py
```

This starts two disposable `erl -noshell` runtimes without names/cookies, with
fresh test seeds and isolated temporary state directories. It uses the existing public Reception,
not another service or a GUI. It checks status/capability reads, local Contract
acceptance/rejection, test-job completion/retry/cancel/expiry, Worker failure and
lease-bounded Manager-loss cleanup. Forbidden raw start, forged signer and replay
checks remain; no arbitrary spawn, old/audio processes or OTP connections are
allowed. EUnit additionally covers local lifecycle, Contract/grant/role boundaries,
unchanged retry deadlines, bounded caches and malformed/oversize input. The earlier
state-reset check remains in `ba_device_store_tests`; that storage path is
unchanged by steps 3–4. See [the job guide](BUFFEE_JOBS.md) for failure limits.
No app build, installation, listening or physical timing claim follows.

Uses OTP's [JSON decoder callbacks](https://www.erlang.org/doc/apps/stdlib/json.html)
and [Ed25519 signing/verification](https://www.erlang.org/doc/apps/crypto/crypto.html),
with no added dependency or bespoke encryption.
