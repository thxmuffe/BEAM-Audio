# Session control protocol v3 — authenticated per request (dark Sessions)



## Runtime and local configuration

The receiver checks each request against its current signed rights statement:
members' rights, default rights for every other joined Device, and removed
Devices. There is no peer list: any Device whose join certificate checks out
against the invitation key may ask (see BUFFEE_MEMBERSHIP.md).

No connection is needed before a request: every packet authenticates itself and
the receiving Device decides it through `ba_device_request` (authenticate,
authorize, approve, execute). A relationship with a peer starts when its first
valid packet arrives and lapses when packets stop. `ba_buffee_control:connect(PeerId)`
sends one `hello` (answered by `ready`) for consumers that need a relationship
before they have anything to ask, such as audio discovery and the clock. Both
endpoints can call `read_status(PeerId)`. Successful replies contain only
`#{<<"protocol">> => 1, <<"session">> => <<"authorized">>}`.
`read_capabilities(PeerId)` returns the Handler's bounded capability snapshot
when the peer has the separate capability grant; reading never enables Workers.



## Wire, authentication and dispatch

Every packet is sealed end to end before Reception sees it: ChaCha20-Poly1305
with a key derived from the link secret and the Session ID as associated data,
sent as base64 of nonce, tag and ciphertext. Reception routes opaque bytes; the
signature inside still proves the author. The Reception v1 transport routes
exactly this payload shape:

```json
{"type":"buffee_control","buffee":"BUFFEE_ID","packet":"ENCODED_ENVELOPE_JSON"}
```

`packet` contains UTF-8 JSON bytes, at most 32768 bytes excluding the Reception wrapper.
Its fields are exactly `body` (base64 JSON bytes) and `signature` (128 uppercase
hex Ed25519 signature characters). Sign the exact decoded body bytes prefixed
with `beamaudio-buffee-control/v1:`. The body has these exact fields:

| Fields | Meaning |
| --- | --- |
| `v` | Integer 3. Earlier versions are not accepted. |
| `from`, `to`, `buffee` | Sender, intended recipient, Buffee. Reception `from` must match the signer; recipient must be local. |
| `join` | Sender's join certificate (128 hex): its Device ID and the Session signed by the invitation key. |
| `revision` | Sender's rights-statement revision. Informational: the newer side shares its statement. |
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
| `capabilities.reply` | Exact Handler instance/revision, plus optional name, audio states and consented diagnostics ([DEVICE_HANDLER.md](DEVICE_HANDLER.md)). Must match a pending capability query. |
| `capabilities.error` | `reason`: `forbidden` or `unavailable`. Matching pending capability query. |
| ~~`time.message`~~ | Removed 2026-11-20: every Device reads UTC itself and the Response time is in the signed statement ([Session time](SESSION_TIME.md)) |
| `stream.message` | Exact flat catalogue/subscription/SDP/ICE schemas in the [stream guide](BUFFEE_STREAMS.md); requests require separate stream grants, responses must match a local attempt. |
| `session.request` | `kind` plus exact fields: `privilege_release` (`privilege`), `rename_request` (`name`, needs on_air), `remove_request` (`device`, needs end_session), `ended` (needs end_session), `policy` (`signer`, signed `state`), `board` (`entries`: up to 6 signed board entries by ID), `note` (`id`, signed gossip `packet`). |

Every message binds both identities, Session, join certificate, sender
instance, sequence and send time. A receiver accepts a packet only if all of these hold:

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
No network string becomes an atom. Invalid input changes no replay/pending state.
No executable terms, arbitrary diagnostics, module/function calls, credentials
or audio are accepted. OTP-admission signatures use a different domain.

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
