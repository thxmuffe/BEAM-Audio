# Parvi Reception Desk

A Phoenix/Cowboy host with supervised Erlang relay workers. Each Parvi node opens
an outbound WebSocket connection and keeps it open. The desk forwards admission,
membership and chat messages for as long as a direct peer path is unavailable.
It does not join swarms or own their memberships or histories. The full browser
client under `src/Apps/WebApp` remains deferred; `/` is only a small desk landing page.

## Run locally on Windows

With the Windows app already built:

```powershell
.\src\Services\ReceptionDesk\run.ps1
```

The launcher prepares a private Elixir 1.19.5 build tool, uses the existing OTP
runtime and resolves locked dependencies. Nothing is installed system-wide.
Override `PARVI_OTP_ROOT` if needed. Subsequent runs reuse ignored build caches.
The default desk is `ws://127.0.0.1:8765/relay/v1` and its landing page is
`http://127.0.0.1:8765/`. `PARVI_BROKER_PORT` changes the development port.

On macOS/Linux with Elixir 1.19 and a compatible OTP installed:

```sh
bash src/Services/ReceptionDesk/build.sh
bash src/Services/ReceptionDesk/run.sh
```

Rebuilt native apps automatically connect to the public Parvi desk configured in
`src/control/src/parvi.app.src` (`default_reception_desk_url`). No URL entry is needed.
To switch desks, enter another **Reception desk URL** and select **Use desk (new
session)**, which replaces transient memberships. Select a swarm in one app, copy its
invitation and paste it into **Add a swarm** in another. Only one admission is
needed. New and existing memberships stay independent. Changing UI selection
never joins or leaves a swarm.

Set `PARVI_RECEPTION_DESK_URL` to override the bundled default before startup.
Set it to an empty string for local-only development; an unset variable uses the
public default. An explicit OTP `reception_desk_url` setting (including the UI
choice) takes priority over both. Restart to apply startup configuration. Never use the
localhost URL on a different device: localhost always refers to that device.

## Internet deployment

`render.yaml` defines a **single** Docker web service, a generated
`SECRET_KEY_BASE` and `/health` check. The Dockerfile builds a Phoenix release.
Deploy that Blueprint from this repository, then use
`wss://YOUR-SERVICE.onrender.com/relay/v1` in every native app. Render terminates
TLS at its ingress; the container listens on `0.0.0.0:$PORT`. Other hosting can
use an equivalent HTTPS reverse proxy with WebSocket upgrades enabled.

The test desk was deployed on 2026-10-28 in Frankfurt on Render's free plan:
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
to the default Render desk. A physical Mac–iPhone invitation and bidirectional
chat exchange also passes, with both nodes shown Running in the Mac graph.
Separate-access-network testing remains a further check.

Only `wss://` is accepted for public desk addresses. Plain `ws://` is restricted
to localhost development. Clients verify certificate chains and hostnames.
`PARVI_RELAY_CA_FILE` may select a private CA file without changing OS trust.
iOS preparation bundles public build-host trust anchors because BEAM cannot
invoke macOS certificate-store commands inside the phone sandbox.

## Protocol and behavior

See [RELAY_PROTOCOL.md](../../../docs/RELAY_PROTOCOL.md) for the wire contract,
credentials, bounds and restart behavior. There is no public node directory on
this endpoint. Erlang cookies, external Erlang terms and arbitrary RPC never
cross the relay. WSS encrypts each client-to-desk connection; messages are not
end-to-end encrypted from other desk operators.

Connections authenticate ephemeral Ed25519 identities with fresh challenges.
A recipient owns per-swarm capability-addressed mailboxes. The desk stamps the
sender identity and checks the destination mailbox scope. Native swarm workers
validate invitations and incoming member messages. No chat is stored server-side.

On socket loss clients reconnect with bounded exponential backoff, reopen their
mailboxes and resend membership observations. A desk restart loses its routing
state; running nodes reauthenticate with the same in-memory keys and rebuild it.
There is no durable offline queue or exactly-once delivery. Sending while locally
disconnected fails; a disconnect after submission can still lose a message.
An initial admission timeout is a failed operation, not proof of peer death.

This first implementation uses one service instance. Multiple independent desk
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

The relay integration test runs a temporary Phoenix desk with three separate
BEAM VMs **without node names or Distributed Erlang**. It checks overlapping
swarms, isolated chat, peer invitations, mutual removal/revocation and a desk
restart. `--idle` verifies ping/pong beyond the inactivity timeout. The TLS test
uses a private temporary certificate; it checks WSS chat and rejects wrong
hostnames and untrusted certificates. It never installs a trust anchor.
The helper currently locates Windows build products and the portable Elixir
cache; override `PARVI_TEST_ERL` / `PARVI_ELIXIR_ROOT` for another local runtime.
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
