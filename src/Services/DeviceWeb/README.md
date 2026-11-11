# BEAM Audio Device Web service

Optional owner-local HTTP service for a Device's existing `ba_device_api`.
This is an Apache-2.0 BEAM Audio component; it contains no product UI or branding.
Cowboy handles HTTP, Ranch owns connections, and an OTP supervision tree owns the
listener. It uses the same Cowboy, Ranch and patched Cowlib versions as the Reception.
The public Reception remains a separate Phoenix application with a different trust
boundary and protocol; there is no duplicate custom HTTP server to maintain.

## Run with a supplied frontend

Requires Erlang/OTP 28+ and rebar3 on PATH. First compilation fetches locked
dependencies; subsequent starts reuse builds. No Elixir, Python or native audio
build is required. From the BEAM Audio checkout:

```sh
bash src/Services/DeviceWeb/run.sh --assets /absolute/path/to/frontend --preview --open
```

On Windows with OTP and rebar3 on PATH:

```powershell
.\src\Services\DeviceWeb\run.ps1 --assets C:\path\to\frontend --preview --open
```

The launcher compiles Erlang sources, starts an unnamed BEAM VM and serves
http://127.0.0.1:8766. `--port` selects another port. `--open` opens the default
browser after the listener starts. Keep the terminal open; Control-C stops the
VM (if Erlang shows its break menu, type `a` then Enter).

Preview only reports `mode: "preview"`; a frontend supplies its own UI fixtures.
Commands return 409 and never invoke the Device. No Device, identity, Reception
connection or audio is created by this launcher.

### Attach to an existing Device

```sh
bash src/Services/DeviceWeb/run.sh --assets /absolute/path/to/frontend \
  --device-record /absolute/path/to/device/running.json --open
```

This transitional standalone mode reuses `ba_cli_device:call/2` for the existing
owner-local, instance-checked JSON-line Unix socket. It rereads the record for
each request, retaining the CLI's bounds and timeouts. It does not start, stop or
kill the Device. Socket/native-audio platform support is unchanged; Windows
preview does not establish Windows live Device support.

### Run inside the Device's BEAM instance

Add this application's compiled `*/ebin` directories (including dependencies) to
the Device's code path. After starting the `buffee_control` runtime:

```erlang
application:set_env(ba_device_web, options,
    #{assets => "/absolute/path/to/frontend", port => 8766}),
application:ensure_all_started(ba_device_web).
```

Without a `record` option, requests call `ba_device_api:request/1` directly. Stop
the optional endpoint with `application:stop(ba_device_web)`. Its listener and
connections stop with it; it neither stops the Device nor changes audio consent.
The macOS CLI can load/start this optional application during Device startup:

```sh
bin/beamaudio new device --devicename OpenSound --web-assets /absolute/path/to/frontend
bin/beamaudio get web --devicename OpenSound
bin/beamaudio monitor --all --devicename OpenSound
```

Build the service first. `--web-port` selects its port (default 8766; 0 chooses a
free port). `get web` returns the actual local URL. This starts an idle Device;
Create/Join and the Device Handler lifecycle stay in the existing OTP runtime.
Stopping the Device stops the web service too. Native app bundles do not yet
automatically package/start this optional application. Without `assets`, the
service exposes the API without a frontend.
The application publishes its origin as `ba_device_web` application metadata and
clears it on stop. Core CLI metadata reads this optional value without importing
web-service modules, so native releases remain independent of this application.

## Browser contract

- `GET /api/session` → `{ "mode": "device" | "preview", "token": "…" }`.
- `POST /api/command`, JSON content type and `X-BEAM-Audio-Token` header → the
  existing Device command/snapshot response. Frontends poll with
  `{ "method": "snapshot" }`; the service invents no second state model.
- `GET /` serves `index.html` from the explicitly supplied asset directory.
  Only direct, non-hidden files with supported web extensions are served;
  directory traversal and arbitrary host files are not exposed.

The listener binds only to IPv4 loopback. Host, Origin, Fetch-Site and a random
per-application session token protect the local browser boundary. The token is
kept out of supervisor specifications/reports. Commands are allowlisted;
stop/kill, arbitrary RPC and browser-supplied instance credentials are rejected.
Bodies are limited to 16 KiB, replies to 2 MB, and body reads to five seconds.
Managed-process metadata is reduced to its display name. Normal requests and
invitations are not logged. Static responses carry no-store, CSP, nosniff and
referrer protections. This is a local owner interface, not a public web API or a
defence against other programs already running as that OS user.

All Device policy, consent, permissions, networking and audio timing remain in
the runtime. The browser receives state and submits commands; neither HTTP nor
the frontend carries audio. Do not publish this endpoint through the Reception.

## Checks

```sh
bash src/Services/DeviceWeb/test.sh
```

EUnit exercises HTTP/session/asset boundaries, malformed and oversized requests
(including chunked bodies), preview isolation, the real CLI client against a
temporary socket, credential redaction, direct commands against an isolated
idle OTP Device, and listener shutdown/token renewal. Fixtures do not require
OpenSound or contact a Reception. Tests need permission to bind local TCP/Unix sockets.
Physical audio, live Buffee admission, Windows execution and browser acceptance
remain separate checks.

## Persistent Windows Web Devices

With `--local-device`, the Windows launcher reserves a per-user Device slot and
keeps its identity under `%LOCALAPPDATA%\BEAM-Audio\Web\device-N`. The seed is
protected with Windows DPAPI for the current user. Closing the runtime releases
the slot; the next launch reuses its identity and saved Owner return record.
Concurrent launches use different slots. `BA_IDENTITY_SEED` and `BA_STATE_DIR` can
supply an explicit existing Device instead. Earlier ephemeral Web launches have
no stable identity to recover. Source compilation does not validate Windows DPAPI
or native audio: those platform checks still require Windows.

The standalone Web launcher starts the real shared control runtime. It currently
does not configure a Windows audio Worker or package native capture/output. Its
audio consent switches therefore do not establish streaming or playback. Windows
audio integration is the next concrete work item, separate from web control.
