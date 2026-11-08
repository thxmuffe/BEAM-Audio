# Swarm control protocol v1 — steps 2–3

Implemented 2026-11-08 under the [Swarm plan](PLAN.md) and
[boundary contract](SWARM_CONTRACT.md). This implements authenticated status
and capability reads, not admission, Passports, jobs, WebRTC control or audio.

## Runtime and local configuration

`parvi:start(swarm_control)` starts `parvi_swarm_control` and the local
`parvi_device_sup` branch under `parvi_sup`. Control owns a linked `parvi_relay`
using the same local Ed25519 key. The Device branch owns the Handler and its
initially empty temporary-worker supervisor. This profile rejects a named/
distributed runtime and starts no old chat, clock, trust/distribution carrier or
audio supervisor. [The Handler guide](DEVICE_HANDLER.md) describes local consent
and the predefined test Worker. Do not launch product apps for this increment.

A local host installs `application:set_env(parvi,swarm_control,Config)` before
startup; variables below are locally provisioned public values:

```erlang
#{policy => #{swarm => SwarmId, authority => AuthorityDeviceId,
              epoch => 1, revision => 1,
              peers => #{PeerDeviceId => [capabilities_read,status_read]}},
  mailbox => LocalMailbox,
  routes => #{PeerDeviceId => PeerMailbox}}
```

Both ends use the same Swarm/authority/epoch/revision. Device IDs are Ed25519
public keys as 64 uppercase hex characters; Swarm/mailbox IDs are 32 uppercase
hex characters. The authority must be local or a configured peer. Up to 32 peers
are accepted; routes must exactly match them. Each peer's grant is a sorted,
unique subset of `[capabilities_read,status_read]`, meaning permission to read
**this** Device's capabilities/status, respectively. Neither grants execution.
The local host
supplies `PARVI_IDENTITY_SEED` securely for stable identity; without it the runtime
generates a disposable identity. No private key is printed by the snapshot API.

This explicit local fixture is the only admission mechanism in step 2. It does
not implement authority-signed Passports or fresh global revocation. There is no
remote policy-update API; restart with deliberately installed current local
policy for this proof. Full policy/rejoin behavior belongs to step 5.

Call `parvi_swarm_control:connect(PeerId)` on one endpoint, then wait until both
`snapshot/0` results show `stage => authorized` for the peer. Both endpoints can
call `read_status(PeerId)`. Successful replies contain only
`#{<<"protocol">> => 1, <<"session">> => <<"authorized">>}`.
`read_capabilities(PeerId)` returns the Handler's bounded test capability snapshot
when the peer has the separate capability grant; reading never enables Workers.
`parvi:connect/1` is the old OTP API and is not used by this profile.

## Wire, authentication and dispatch

The existing Desk v1 transport routes exactly this payload shape:

```json
{"type":"swarm_control","swarm":"SWARM_ID","packet":"ENCODED_ENVELOPE_JSON"}
```

`packet` contains UTF-8 JSON bytes, at most 32768 bytes excluding the Desk wrapper.
Its fields are exactly `body` (base64 JSON bytes) and `signature` (128 uppercase
hex Ed25519 signature characters). Sign the exact decoded body bytes prefixed
with `parvi-swarm-control/v1:`. The body has these exact fields:

| Fields | Meaning |
| --- | --- |
| `v` | Integer 1. |
| `from`, `to`, `swarm` | Sender, intended recipient, Swarm. Desk `from` must match the signer; recipient must be local. |
| `authority`, `epoch`, `revision` | Pinned authority Device ID and exact locally installed policy version. |
| `session` | Fresh 128-bit/32-hex session ID. |
| `seq` | Nonnegative integer up to 9007199254740991; strictly increasing per application-message direction. |
| `op`, `request`, `payload` | Fixed operation, 128-bit/32-hex correlation ID, exact operation-specific object. |

| Operation | Payload and required state |
| --- | --- |
| `hello` | Fresh 256-bit/64-hex initiator nonce `a`; `b`: null. Configured peer with no existing session. |
| `challenge` | Echoes `a`, supplies fresh 256-bit/64-hex responder nonce `b`. Matching pending hello. |
| `proof` | Echoes both nonces. Matching pending challenge. |
| `ready` | Echoes both nonces. Matching pending proof. Completes mutual authentication. |
| `status.read` | Empty object. Authorized unexpired session, new sequence and peer's local `status_read` grant. |
| `status.reply` | `protocol`: 1, `session`: `authorized`. Matching outstanding unexpired read to that peer. |
| `status.error` | `reason`: `forbidden`. Correlated response when peer lacks read permission. |
| `capabilities.read` | Empty object. Authorized session/new sequence and a `capabilities_read` grant. |
| `capabilities.reply` | Exact Handler instance/revision and test capability described in [DEVICE_HANDLER.md](DEVICE_HANDLER.md#capability-advertisement). Must match a pending capability query. |
| `capabilities.error` | `reason`: `forbidden` or `unavailable`. Matching pending capability query. |

Handshake messages use sequence 0 and `request == session`; application messages
start at 1. All messages bind both identities, Swarm, session and policy version;
handshake continuations bind both nonces. Replayed hello can obtain a bounded
fresh challenge after an old session is gone, but captured proof cannot answer it.

Reject unknown fields/versions/operations, duplicate keys, arrays, extra JSON
values, excess nesting, malformed IDs/types and wrong policy/recipient. Size is
checked before envelope decoding; signature verification precedes body dispatch.
No network string becomes an atom. Invalid input changes no replay/pending state.
No executable terms, arbitrary diagnostics, module/function calls, credentials
or audio are accepted. OTP-admission signatures use a different domain.

Transport is currently ordered Desk WSS with verified public TLS. The Desk can
observe payloads; signing does not supply end-to-end encryption. WebRTC control
and its DTLS fingerprint binding are not implemented or claimed by this step.

## Limits and failure behavior

Handshake expiry is 10 seconds; each authorized local session lasts at most
60 seconds from completion. One status or capability request per peer may be outstanding,
with a 5-second response deadline. Local monotonic deadlines are checked on
receive/request and on a 250 ms cleanup tick. Expiry/Desk loss drops sessions and
completes waiting callers with an error. Duplicate/lower sequences and replies
without a live correlation are rejected. No automatic renewal or simultaneous-open
resolution is implemented; explicitly establish a new session after expiry/reset.

Relay deliveries are dropped when the control owner's mailbox already has 64
messages; outgoing traffic retains existing relay queue/frame bounds. The Desk
retains its own limits. Local send acceptance is not remote receipt; overload/drop
may produce a request timeout. This is bounded prototype behavior, not a public
capacity claim. The pure protocol module owns validation/transitions; the control
process owns timers, waiting local callers and Desk I/O. An authorized capability
request triggers a bounded 100 ms local Handler read; failure produces unavailable.
Capability responses include a signed instance/revision, fixed support/consent/
availability flags and bounded capacity/duration counts, without process IDs.
Public snapshots expose
identity, session stages, relay status and rejection summaries only. OTP status
and termination formatting redact private keys and internal message/log content.

## Previous membership and subscription state

At the user's request, new builds ignore version-1 `parvi_cluster_store` records:
policy, authority, remembered Desk routes and subscription intent. New saves use
version 2; other unsupported formats fail visibly. Secure device identity keys
are separate and unchanged. This is an intentional clean start, not a migration
of old permissions or revocation of other Devices. Old files remain until
replaced; they are not imported. Installed old bundles were not launched or
altered and still contain their old code. App integration/launch is step 9.

## Validation

From `src/control`:

```sh
rebar3 compile
rebar3 eunit --module=parvi_device_handler_tests,parvi_swarm_control_protocol_tests,parvi_relay_tests,parvi_native_tests
```

From the core root, explicitly run the real-Desk check:

```sh
python3 tests/control/swarm-control-smoke.py
```

This starts two disposable `erl -noshell` runtimes without names/cookies, with
fresh test seeds and no app state directory. It uses the existing public Desk,
not another service or a GUI. It checks both status/capability directions, local
consent changes, forbidden command, forged signer, replay and absence of remote
Worker creation, old/audio processes and OTP connections. EUnit additionally
covers local Worker lifecycle/crashes, expiry/correlation, permission/policy/
recipient mismatch and malformed/oversize input. The earlier state-reset check
remains in `parvi_cluster_store_tests`; that storage path is unchanged by step 3.
No app build, installation, listening or physical timing claim follows.

Uses OTP's [JSON decoder callbacks](https://www.erlang.org/doc/apps/stdlib/json.html)
and [Ed25519 signing/verification](https://www.erlang.org/doc/apps/crypto/crypto.html),
with no added dependency or bespoke encryption.
