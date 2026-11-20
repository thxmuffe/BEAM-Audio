# BEAM Audio Reception

A **Reception** provides authentication, introduction and message routing for Devices.
The current Phoenix/WebSocket service uses `ba_reception_sessions`; core Reception
configuration is `BA_DESK_BIND` / `BA_DESK_PORT` (or conventional `PORT`). Existing
hosted service addresses remain unchanged. The explicit namespace migration
changed the authentication domain and mailbox scope field; deploy matching
Reception/client versions once for that migration.
See [naming/migration](../../../docs/NAMING.md) and
[canonical terminology](../../../docs/TERMINOLOGY.md).

## Stable transport boundary

Keep Reception as small and stable as possible. It authenticates a Device's
Ed25519 connection, maintains live capability-addressed mailboxes, introduces
live endpoints and forwards bounded opaque envelopes. A mailbox's `buffee` field
is an opaque scope ID. Reception does not interpret Buffee membership, Owner,
Chef/Guest roles, invitation credentials, clock policy, audio formats or the
signed contents of client messages. These remain in the clients' BEAM runtimes.

The `/relay/v1` authentication domain `beamaudio-desk/v1:` and its wire field
names are fixed transport contracts, independent of product vocabulary. Ordinary
client feature, role or audio changes must work without deploying Reception.
Only an actual transport-contract or service-operational change needs a service
update; do not add aliases, a membership database or application logic here.

The separate [Device Web service](../DeviceWeb/README.md) uses the same Cowboy,
Ranch and patched Cowlib versions for an owner-local HTTP command API. It serves
frontend assets supplied by an app; the Reception remains public authentication and
routing infrastructure. Neither service needs a Python bridge. There is no
change to the public service URL. The v3 reusable-invitation extension adds
capability-scoped live mailbox lookup; it does not elect Owners, claim names,
restore authority, store Buffees or prevent simultaneous starters. See
[membership semantics](../../../docs/BUFFEE_MEMBERSHIP.md).

The remaining profile notes describe historical app integrations; step 9 has not
updated those apps. A Phoenix/Cowboy host has supervised Erlang relay Workers. Each Device opens
an outbound WebSocket connection and keeps it open. In the native profile the
Reception carries peer introductions/signaling; authenticated OTP membership and chat
use the direct encrypted WebRTC DataChannel. It is not a TURN/data relay for
that profile. The legacy profile carries membership and chat through the Reception.
It does not join buffees or own their memberships or histories. The full browser
frontend lives in the sibling OpenSound checkout; `/` here is only a small Reception landing page.

## Run locally on Windows

From Git Bash:

```sh
src/Services/ReceptionDesk/run.sh
```

On Windows it delegates to `run-windows.py`, which prepares a private Elixir 1.19.5
build tool with the core's pinned OTP/rebar3 and resolves locked dependencies. Nothing is installed system-wide.
Override `BA_OTP_ROOT` if needed. Subsequent runs reuse ignored build caches.
The default Reception is `ws://127.0.0.1:8765/relay/v1` and its landing page is
`http://127.0.0.1:8765/`. `BA_DESK_PORT` changes the development port.

On macOS/Linux with Elixir 1.19 and a compatible OTP installed:

```sh
bash src/Services/ReceptionDesk/build.sh
bash src/Services/ReceptionDesk/run.sh
```

New Sessions use the public BEAM Audio Reception configured in
`src/control/src/ba_core.app.src` (`default_reception_desk_url`); an invitation
carries its Session's Reception, so joining needs no URL entry. Never use a
localhost URL on a different device: localhost always refers to that device.

The default belongs to BEAM Audio; app hosts can supply the OTP setting before
starting the shared runtime without editing that default. Invitations record
the effective URL, and native joins reject a link for a different Reception. The
current handler requires the `/relay/v1` protocol/path; an arbitrary custom Reception
protocol handler is not a pluggable interface yet. iOS's `relay_resolver` callback
customizes DNS resolution only.

## Internet deployment

`render.yaml` defines a **single** Docker web service, a generated
`SECRET_KEY_BASE` and `/health` check. The Dockerfile builds a Phoenix release.
The Render service `beamaudio` builds `thxmuffe/BEAM-Audio` on `main` with
root directory `src/Services/ReceptionDesk`; this directory is the Docker
context and holds the Dockerfile. Automatic deploys are disabled: deploy with
`render deploys create <service-id> --wait`. Apps use
`wss://YOUR-SERVICE.onrender.com/reception` (`/relay/v1` still works). Render terminates
TLS at its ingress; the container listens on `0.0.0.0:$PORT`. Other hosting can
use an equivalent HTTPS reverse proxy with WebSocket upgrades enabled.

The shared Reception runs in Frankfurt on Render's free plan:
https://beamaudio.onrender.com. Enter
`wss://beamaudio.onrender.com/reception` in each native app.
The service ID is `srv-dbq59cmgekts73anho5g`; automatic deploys are disabled.
Deploy a committed/pushed revision with the authorized Render CLI:

```sh
render deploys create srv-dbq59cmgekts73anho5g --wait
```

Free instances can sleep after 15 minutes without inbound HTTP/WebSocket traffic;
the next connection wakes them, which can take about a minute. See
[Render's free-plan documentation](https://render.com/docs/free).
Test Windows and a rebuilt iPhone on separate internet connections.
An already installed older phone build cannot use the new transport. The Apple
targets have now been rebuilt on the Mac: the packaged Mac runtime passes public
WSS admission/chat/departure checks, and the signed physical iPhone authenticates
to the default Render Reception. A physical Mac–iPhone invitation and bidirectional
chat exchange also passes, with both nodes shown Running in the Mac graph.
Separate-access-network testing remains a further check.

Only `wss://` is accepted for public Reception addresses. Plain `ws://` is restricted
to localhost development. Clients verify certificate chains and hostnames.
The `relay_cacertfile` setting may select a private CA file without changing OS trust.
iOS preparation bundles public build-host trust anchors because BEAM cannot
invoke macOS certificate-store commands inside the phone sandbox.

## Protocol and behavior

See [RELAY_PROTOCOL.md](../../../docs/RELAY_PROTOCOL.md) for the wire contract,
credentials, bounds and restart behavior. There is no public node directory on
this endpoint. Erlang cookies, external Erlang terms and arbitrary RPC never
cross the relay. WSS encrypts each client-to-Reception connection; messages are not
end-to-end encrypted from other Reception operators.

Connections authenticate ephemeral Ed25519 identities with fresh challenges.
A recipient owns per-buffee capability-addressed mailboxes. The Reception stamps the
sender identity and checks the destination mailbox scope. Native buffee workers
validate invitations and incoming member messages. No chat is stored server-side.

On socket loss clients reconnect with bounded exponential backoff, reopen their
mailboxes and resend membership observations. A Reception restart loses its routing
state; running nodes reauthenticate with the same in-memory keys and rebuild it.
There is no durable offline queue or exactly-once delivery. Sending while locally
disconnected fails; a disconnect after submission can still lose a message.
An initial admission timeout is a failed operation, not proof of peer death.

This first implementation uses one service instance. Multiple independent Reception
replicas would need shared routing; adding replicas blindly will split clients.
Audio, direct peer/NAT traversal, durable storage, accounts and the full browser
app are outside this milestone.

## Verification

```sh
# Build the native client and shared protocol tests (OpenSound checkout).
python build.py --test
# With the private Elixir from run-windows.py --setup-only on PATH:
cd src/Services/ReceptionDesk
mix test
cd ../..
python tests/ReceptionDesk/release-smoke.py
```

`tests/ReceptionDesk/local_reception.py` is the local Reception fixture the Session
integration tests use (`start_desk`). The TLS and public-Reception client checks
were removed with the legacy client on 2026-11-20; rebuild them on the CLI later.
The fixture locates Windows build products and the portable Elixir
cache; override `BA_TEST_ERL` / `BA_ELIXIR_ROOT` for another local runtime.
The production release also boots locally with runtime configuration and
distribution disabled (`tests/ReceptionDesk/release-smoke.py`). Docker image execution was not
verified here because the Docker engine is not running; the image still needs
its Linux/Render deployment check.

## Dependency provenance

`mix.lock` and `src/control/rebar.lock` pin the server/client dependencies. Gun 2.7.0
and Cowboy 2.20.0 retain their upstream header-validation protections. Cowlib is
pinned to upstream commit `4401b858f2229abb3ea115c60924f6c77e5f8aa3`, the fix
identified for CVE-2026-43966, rather than the affected Hex release. See the
[Erlang Ecosystem Foundation advisory](https://cna.erlef.org/cves/CVE-2026-43966.html).
Keep dependency licenses with deployment and app bundles.
