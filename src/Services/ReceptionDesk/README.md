# BEAM Audio Reception

A **Reception** provides authentication, introduction and message routing for Devices.
The current Phoenix/WebSocket service uses `ba_reception_sessions`; core Reception
configuration is `BA_DESK_BIND` / `BA_DESK_PORT` (or conventional `PORT`). Existing
signed protocol domains and the hosted service address remain unchanged.
See [naming/migration](../../../docs/NAMING.md) and
[canonical terminology](../../../docs/TERMINOLOGY.md).

The separate [Device Web service](../DeviceWeb/README.md) uses the same Cowboy,
Ranch and patched Cowlib versions for an owner-local HTTP command API. It serves
frontend assets supplied by an app; the Reception remains public authentication and
routing infrastructure. Neither service needs a Python bridge. There is no
change to the public service URL. The v3 reusable-invitation extension adds
capability-scoped live mailbox lookup; it does not elect Captains, claim names,
restore authority, store Swarms or prevent simultaneous starters. See
[membership semantics](../../../docs/SWARM_MEMBERSHIP.md).

The remaining profile notes describe historical app integrations; step 9 has not
updated those apps. A Phoenix/Cowboy host has supervised Erlang relay Workers. Each Device opens
an outbound WebSocket connection and keeps it open. In the native profile the
Reception carries peer introductions/signaling; authenticated OTP membership and chat
use the direct encrypted WebRTC DataChannel. It is not a TURN/data relay for
that profile. The legacy profile carries membership and chat through the Reception.
It does not join swarms or own their memberships or histories. The full browser
frontend lives in the sibling OpenSound checkout; `/` here is only a small Reception landing page.

## Run locally on Windows

With the Windows app already built:

```powershell
.\src\Services\ReceptionDesk\run.ps1
```

The launcher prepares a private Elixir 1.19.5 build tool, uses the existing OTP
runtime and resolves locked dependencies. Nothing is installed system-wide.
Override `BA_OTP_ROOT` if needed. Subsequent runs reuse ignored build caches.
The default Reception is `ws://127.0.0.1:8765/relay/v1` and its landing page is
`http://127.0.0.1:8765/`. `BA_DESK_PORT` changes the development port.

On macOS/Linux with Elixir 1.19 and a compatible OTP installed:

```sh
bash src/Services/ReceptionDesk/build.sh
bash src/Services/ReceptionDesk/run.sh
```

Rebuilt native apps automatically connect to the public BEAM Audio Reception configured in
`src/control/src/ba_core.app.src` (`default_reception_desk_url`). No URL entry is needed.
In the legacy UI, enter another **Reception URL** and select **Use Reception (new
session)** to switch Receptions, which replaces transient memberships. Native UI
switching is currently disabled; supply a startup override instead. Select a swarm in one app, copy its
invitation and paste it into **Add a swarm** in another. Only one admission is
needed. New and existing memberships stay independent. Changing UI selection
never joins or leaves a swarm.

Set `BA_RECEPTION_DESK_URL` to override the bundled default before startup.
Set it to an empty string for local-only development; an unset variable uses the
public default. An explicit OTP `reception_desk_url` setting (including the UI
choice) takes priority over both. Restart to apply startup configuration. Never use the
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
The existing Render service now builds `thxmuffe/BEAM-Audio` on `main`, using
`src/Services/ReceptionDesk/Dockerfile` and repository-root Docker context. Its
service ID and public URL are retained; automatic deploys remain disabled.
Deploy that Blueprint from this repository, then use
`wss://YOUR-SERVICE.onrender.com/relay/v1` in every native app. Render terminates
TLS at its ingress; the container listens on `0.0.0.0:$PORT`. Other hosting can
use an equivalent HTTPS reverse proxy with WebSocket upgrades enabled.

The test Reception was deployed on 2026-10-28 in Frankfurt on Render's free plan:
https://parvi-reception-desk.onrender.com. Enter
`wss://parvi-reception-desk.onrender.com/relay/v1` in each native app.
The service ID is `srv-dbgvjfui0phs73ablggg`; automatic deploys are disabled.
Deploy a committed/pushed revision with the authorized Render CLI:

```powershell
render deploys create srv-dbgvjfui0phs73ablggg --wait
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
`BA_RELAY_CA_FILE` may select a private CA file without changing OS trust.
iOS preparation bundles public build-host trust anchors because BEAM cannot
invoke macOS certificate-store commands inside the phone sandbox.

## Protocol and behavior

See [RELAY_PROTOCOL.md](../../../docs/RELAY_PROTOCOL.md) for the wire contract,
credentials, bounds and restart behavior. There is no public node directory on
this endpoint. Erlang cookies, external Erlang terms and arbitrary RPC never
cross the relay. WSS encrypts each client-to-Reception connection; messages are not
end-to-end encrypted from other Reception operators.

Connections authenticate ephemeral Ed25519 identities with fresh challenges.
A recipient owns per-swarm capability-addressed mailboxes. The Reception stamps the
sender identity and checks the destination mailbox scope. Native swarm workers
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

```powershell
# Build the native client and shared protocol tests.
.\src\Apps\Windows\build.ps1 -Test
# In the environment prepared by setup.ps1:
cd src/Services/ReceptionDesk
mix test
cd ../..
python tests/ReceptionDesk/relay-smoke.py --idle
python tests/ReceptionDesk/tls-smoke.py
python tests/ReceptionDesk/public-smoke.py wss://parvi-reception-desk.onrender.com/relay/v1
python tests/Windows/relay-ui-smoke.py
```

The relay integration test runs a temporary Phoenix Reception with three separate
BEAM VMs **without node names or Distributed Erlang**. It checks overlapping
swarms, isolated chat, peer invitations, mutual removal/revocation and a Reception
restart. `--idle` verifies ping/pong beyond the inactivity timeout. The TLS test
uses a private temporary certificate; it checks WSS chat and rejects wrong
hostnames and untrusted certificates. It never installs a trust anchor.
The helper currently locates Windows build products and the portable Elixir
cache; override `BA_TEST_ERL` / `BA_ELIXIR_ROOT` for another local runtime.
The production release also boots locally with runtime configuration and
distribution disabled (`tests/ReceptionDesk/release-smoke.py`). Docker image execution was not
verified here because the Docker engine is not running; the image still needs
its Linux/Render deployment check.

The original `inets` node-name directory is retained separately for legacy
regression tests: `run-legacy.ps1` / `run-legacy.sh`. It is unauthenticated local
discovery, not this relay and not suitable for public hosting. The old directory
smoke test now launches that explicit legacy service.

## Dependency provenance

`mix.lock` and `src/control/rebar.lock` pin the server/client dependencies. Gun 2.7.0
and Cowboy 2.20.0 retain their upstream header-validation protections. Cowlib is
pinned to upstream commit `4401b858f2229abb3ea115c60924f6c77e5f8aa3`, the fix
identified for CVE-2026-43966, rather than the affected Hex release. See the
[Erlang Ecosystem Foundation advisory](https://cna.erlef.org/cves/CVE-2026-43966.html).
Keep dependency licenses with deployment and app bundles.
