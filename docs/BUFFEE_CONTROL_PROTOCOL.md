# Session control protocol v2 — authenticated per request



## Runtime and local configuration

Current runtime policy pins Buffee, authority, Manager, epoch/revision and per-sender
operation grants. Membership alone grants no operations. `job_offer` additionally
requires the job_offer grant and recipient's matching local Contract/consent.
The [Handler guide](DEVICE_HANDLER.md) describes that local lifecycle.

No connection is needed before a request: every packet authenticates itself and
the receiving Device decides it through `ba_device_request` (authenticate,
authorize, approve, execute). A relationship with a peer starts when its first
valid packet arrives and lapses when packets stop. `ba_buffee_control:connect(PeerId)`
sends one `hello` (answered by `ready`) for consumers that need a relationship
before they have anything to ask, such as audio discovery and the clock. Both
endpoints can call `read_status(PeerId)`. Successful replies contain only
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
| `v` | Integer 2. Version 1 (handshake and lease renewal) is no longer accepted. |
| `from`, `to`, `buffee` | Sender, intended recipient, Buffee. Reception `from` must match the signer; recipient must be local. |
| `authority`, `manager`, `epoch`, `revision` | Pinned authority/Manager Device IDs and exact locally installed policy version. |
| `session` | The sender's instance: fresh 128-bit/32-hex ID per control state (start, policy change, restart). |
| `seq` | Nonnegative integer up to 9007199254740991; strictly increasing per sender instance. |
| `sent` | Sender's wall-clock time, Unix milliseconds. |
| `op`, `request`, `payload` | Fixed operation, 128-bit/32-hex correlation ID, exact operation-specific object. |

| Operation | Payload and required state |
| --- | --- |
| `hello` | Empty object. Introduces the sender; answered with `ready`. |
| `ready` | Empty object. No reply. |
| `status.read` | Empty object. Peer's local `status_read` grant. |
| `status.reply` | `protocol`: 1, `session`: `authorized`. Matching outstanding unexpired read to that peer. |
| `status.error` | `reason`: `forbidden`. Correlated response when peer lacks read permission. |
| `capabilities.read` | Empty object. A `capabilities_read` grant. |
| `capabilities.reply` | Exact Handler instance/revision and test capability described in [DEVICE_HANDLER.md](DEVICE_HANDLER.md#capability-advertisement). Must match a pending capability query. |
| `capabilities.error` | `reason`: `forbidden` or `unavailable`. Matching pending capability query. |
| `time.message` | Exact timestamp/Offset schemas in the [Time guide](BUFFEE_TIME.md); separate time_read/offset_write grants and correlated authority replies. |
| `stream.message` | Exact flat catalogue/subscription/SDP/ICE schemas in the [stream guide](BUFFEE_STREAMS.md); requests require separate stream grants, responses must match a local attempt. |
| `job.offer` | Exact test capability/Contract/duration/lease fields; job_offer grant and matching local coordinator Contract. Header request is the Job ID. Handler independently accepts/rejects. |
| `job.cancel` | Empty object; verified coordinator, same grant and owned Job/session scope. |
| `job.report` | Exact attempt/state/reason object. Adapter checks the Manager record's assignee, session, Job ID, attempt and result fence. |

Every message binds both identities, Session, sender instance, sequence, send
time and policy version. A receiver accepts a packet only if all of these hold:

- its `sent` is within 5 minutes of the receiver's wall clock;
- for a known sender instance, `seq` is higher than the last one accepted;
- the instance is not one this peer has since replaced (the last four are
  remembered for 10 minutes);
- for an unknown instance, `sent` is no earlier than 2 s before the receiver's
  control state started, so a restarted receiver cannot be fed recorded traffic.

The rights each operation needs are one table in `ba_device_request:authorize/3`;
refusals keep the operation's error reply listed above. Verification results are
never cached: each packet's signature and policy are checked on arrival.

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

A relationship lasts 60 seconds from the latest accepted packet, capped by
current local membership. Nothing is exchanged in the background to keep it:
traffic extends it, and the owner is told (`session_renewed`) at most once per
third of that interval so dependent media leases follow. An idle relationship
lapses (`session_expired`); its replay state is kept until its packets could no
longer be fresh, and the same instance's next packet resumes it. A new sender
instance replaces it (`session_replaced`). Devices no longer connect to every
admitted peer; the 250 ms full-mesh connect loop is gone. Audio discovery still
introduces itself to every peer while audio automation runs (its catalogue
polling is the separate topology limitation in PLAN.md). The Session membership
handshake is separate and unchanged.

Wall clocks must agree within 5 minutes; a Device outside that window cannot
exchange control messages.

One status or capability request per peer may be outstanding,
with a 5-second response deadline. Local monotonic deadlines are checked on
receive/request and on a 250 ms cleanup tick. Expiry or policy invalidation drops
affected sessions and completes waiting callers with an error. Reception loss alone
does not reset authorization or healthy sessions. Routes can use another configured
Reception; lack of timely fresh authorization still enforces expiry. Presence cleanup
checks other live Receptions before declaring a peer unavailable. Duplicate/lower
sequences and replies without a live correlation are rejected. The clock
introduces itself to its authority (at most every 2 s) when it has no relationship.
Simultaneous hellos need no resolution: each is simply answered.

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
identity, relationship stages (`authorized`/`lapsed`), deadlines and renewal counts, relay status, bounded diagnostic
counters and rejection summaries, without keys or replay state. OTP status
and termination formatting redact private keys and internal message/log content.



## Previous membership and subscription state
