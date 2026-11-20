# Current implementation and validation

## iPhone engine shell; GStreamer removed — 2026-11-20

- iOS runs the engine in-process (`ba_audio_engine_start` → 127.0.0.1 control
  port; Erlang connects with the same `{packet,4}` terms). A closed connection
  releases all streams; a crash report left by the previous run is posted to
  chat at next engine use. Libraries cross-built for iOS from the same pinned
  sources; the iOS OTP runtime's own `libei` is linked.
- Verified: iOS libraries and engine library build; a link test and an
  unsigned `xcodebuild` of the app succeed. Not verified: running on a phone,
  audible playback, the loopback control path at runtime.
- Removed: Apple GStreamer host, iOS GStreamer runtime glue, Mac native-stream
  helper and capture, GStreamer download/packaging scripts, Windows native host
  and its build, `src/Audio/experiments`, the native-stream smoke test,
  AUDIO_ENGINE_INTERFACE.md. Windows builds without audio. 178 core tests pass.

## Session audio switched to the engine on Mac/CLI — 2026-11-20

- Transport `engine_flac_srtp_v1` replaces GStreamer AAC in Sessions
  (`ba_stream_handler_engine`, `ba_engine_media_session`); the GStreamer media
  session and its tests were deleted. The receiver sends `signal.endpoint`
  (X25519 public key, engine port, addresses as one space-separated field:
  signed control forbids JSON arrays); the provider answers `signal.stream`
  with the stream key wrapped by ChaCha20-Poly1305 under HKDF(ECDH, attempt).
  Unit tests cover wrapping and validation; 178 core tests pass.
- One engine per Device (`ba_audio_engine:ensure/0`), started by
  `ba_audio_sup:start_media` before the worker (starting it from the worker's
  init deadlocked the supervisor; found live). Clock probes and the Mac
  capture start are asynchronous, so macOS's System Audio Recording prompt no
  longer blocks Erlang (it did, live, and cascaded into chat crash notices).
- Live: two CLI Devices on one Mac in a real Session (public Reception): the
  receiver's subscription went active and playing; over ~25 s ~7k packets,
  0 late/rejected/re-positioned, missing frames only at start-up. Duplicates
  (one per extra address) are expected until connectivity checks. Not yet
  heard by the owner through the Mac app; iPhone/Windows have no engine yet.

## Own audio engine: debug loop and macOS engine — 2026-11-20

Implemented steps 0 and 1 (engine part) of the plan in [AUDIO_ENGINE.md](AUDIO_ENGINE.md).

- **Chat to file:** `beamaudio monitor` appends every chat entry its Device sees
  to `builds/live/chat.log` (UTC time, Device name, text). Checked with a
  disposable CLI Device: two sent lines appeared within a second.
- **Engine:** C++17 in `src/Audio/engine/` (speaker, capture, net, timing,
  term, crash), macOS shell `src/Audio/adapters/macOS/engine_shell.mm`, Erlang
  owner `ba_audio_engine`. Libraries are pinned, checksummed sources built
  under `builds/` (libFLAC 1.5.0, libsrtp 2.8.1, libsamplerate 0.2.2,
  cpptrace 1.0.4, nlohmann/json 3.12.0) plus OTP's `ei`. FLAC 24-bit, 192-frame
  packets, SRTP AES-CM-128/HMAC-SHA1-80, one dual-stack UDP socket.
- **Crash reports:** checked a segfault and an uncaught exception on another
  thread: reports carry the reason, file:line frames and the last commands
  (keys redacted); the owner stops with `{native_engine_exit, 139 | 134}`.
  Posting them into a live Session chat is implemented but not exercised.
- **Measurement** (`tests/macOS/audio-engine-sync.escript`, 30 s, tone sender
  and two silent receivers on one Mac, loopback, 200 ms delay): no late,
  rejected or re-positioned packets; scheduling error converged from ~20 µs to
  ~1–6 µs mean per receiver, sender ~0–4 µs. This is the engines' own
  scheduling against Core Audio timestamps and reported device latency, on one
  shared clock; not physical speaker timing, not cross-device, not a lossy
  network. ~5–7k frames were missing only at start-up (packets sent before the
  receivers existed).
- **Not done:** Session integration (stream setup, X25519 key agreement,
  replacing `ba_native_media_session`), app packaging, comparison with the
  GStreamer path, owner listening test, iOS/Windows shells.
- `scripts/cli/beamaudio` and `beam-audio` were committed without the executable
  bit (mode 100644); restored locally, commit the mode change.

## Compact Session name investigation and Apple policy preservation — 2026-11-20

Retried the owner's existing compact invitation with a separate, audio-disabled
CLI Inspector. The running Windows Web Device and Inspector discovered and
authenticated each other through public Reception. Both remained at revision 0
with the generic name Session; the creating Device was not reachable and neither
online Device supplied a signed copy of Gossip 1. This is no longer the deployed
Reception protocol mismatch. The Inspector was stopped; the user's Device was
not stopped, reconfigured or renamed.

The compact v6 invitation encodes creator key, nonce and secret, not a name.
The owner explicitly chose to keep it compact and learn the name from signed
policy; do not add the name back to the link. Earlier v5 invitations included it.
A fresh two-Device public CLI check confirmed signed-name propagation at revision
1, zero rejected policies, and name retention after cold restart with the creator
offline. No user invitation or identity was used in that separate test Session.

Found a separate data-loss bug in Apple app startup: an obsolete migration deleted
saved_sessions.term on every macOS/iOS launch, erasing current signed names and
privileges. Removed that startup deletion routine entirely. Legacy transient
snapshot files are not used by the current runtime; current policy memory must
survive. Replaced the old deletion test with preservation checks for both Apple
platforms: both failed before the fix and pass afterward. Core EUnit 183/183.
An additional real public CLI test using iOS startup configuration exchanged a
signed name and retained it after a cold restart with the creator offline.
Apple native app builds/deployment were not performed on this Windows machine.
Already erased policy cannot be recovered from the nameless link alone; it must
arrive from a Device retaining the signed policy. No existing Session name was
invented or overwritten during this investigation.

## Matching Reception deployed to Render — 2026-11-20

At the owner's request, deployed pushed commit
`5f8d0cc4034e45ada7806a9d14e22d77a8b3e45a` with the Render CLI. Deployment
`dep-dc02iubm8hqs739c1et0` is live on `beamaudio`, completed at 13:06:57 Helsinki
time. The service ID in the README was stale (404); CLI service inventory verified
the current `srv-dbu7fih42hec73bpsjv0` against its name, repository, root directory
and public URL. Updated the README to that ID.

Post-deployment public checks pass: /health, signed Ed25519 authentication for two
disposable clients, opening/discovering both mailboxes using the renamed session
field, and authenticated sender-to-recipient message delivery. The test used a
random unused scope, carried no audio or user invitation, and closed both clients.
The previous invalid_message mismatch is resolved on the public service. The two
previous local app URLs were no longer listening, so those windows' peer/name
state could not be verified at those addresses. Existing unit results do not
substitute for that live app/name check.

## Public Session discovery blocked by deployed protocol mismatch — 2026-11-20

Both owner's local apps reported the same Session ID and local admission, but
Reception was connected with `invalid_message` and no reachable peers. A separate
CLI Inspector reproduced the same result with audio consent entirely OFF.
Compact v6 invitations contain creator/nonce/secret, not the Session name; signed
policy from another Device supplies that name. Without discovery, the apps remain
at revision 0 with the generic name and only their own Device.

An authenticated, disposable WebSocket probe on a random unused scope confirmed
that public Reception rejects `lookup` with the new `session` field, but accepts
the pre-rename field and returns `found`. It did not join or alter the owner's
Session. GitHub main is still add951e, preceding the local cleanup/rename commits;
the deployed service demonstrably still uses the previous transport contract.
The current Reception source already implements the renamed contract. Resolution
requires publishing/deploying the matching Reception revision, then verifying
discovery and signed name propagation; no public deployment was performed here.
The source service must not be treated as matching the deployed instance.

Also fixed the CLI entry point to load ba_core defaults before dispatch. Without
that, compact invitation files with the default Reception were silently treated
as invalid because parsing called default_desk before application:load. The exact
owner-supplied invitation now starts the public CLI Inspector successfully.
The Inspector reproduced the service mismatch and was stopped afterward; owner's
Devices were not stopped, reconfigured or hot-patched. No invitation or seed is
included in this report.

## Web runtime failure on pre-rename tab settings — 2026-11-20

Read-only HTTP inspection of the owner's running Windows app found that
`list_sessions` returned a tab with the retired `buffee` field, while `snapshot`
returned HTTP 503. `ba_sessions` updated an absent `session` field with `:=`,
crashing the coordinator and producing DeviceWeb's generic runtime-unavailable
message. This was not established by the earlier stubbed frontend tests or the
CLI test with fresh settings. The earlier explanation about invalidated old
return checkpoints did not account for this settings-schema failure.

`ba_sessions:init/1` now normalizes tab metadata to id/name/session and persists
that canonical shape. A worker snapshot supplies the actual Session identity;
return authority and invitations are preserved separately. No old-schema runtime
branch or user-state deletion is added.

Added registered `tests/Windows/web-session-rejoin-smoke.py`, using the Windows
host with the current compiled core and built frontend, actual DeviceWeb HTTP
and headless Chromium. It reproduces pre-rename settings and checks that Gossip 1
is current after restart. It additionally removes the return checkpoint and
verifies that the invitation in user settings alone rejoins and becomes current,
then checks compact-link Join from an idle pre-rename tab. Failed with HTTP 503
before the backend fix; all scenarios pass afterward. The existing browser
harness accepts a real Device URL for these checks rather than stubbing commands.
Only disposable identities and state are used; no public Reception or audio.

The owner's supplied compact invitation was separately accepted through real
HTTP on a disposable Device with Reception redirected to loopback and audio OFF.
This verifies parsing/local admission, not reaching the owner's live peers.
Rechecked: core EUnit 182/182, DeviceWeb 6/6, Node 35/35, eight existing browser
scenarios and Python runner tests 2/2 pass. The complete cross-platform inventory
has not been run; Reception integration remains unavailable without its compiled
dependencies. The running owner's app was not stopped or hot-patched. Current
core artifacts are compiled; the packaged Windows app must be rebuilt and its
runtime restarted to load the fix.

## Web saved-invitation startup fix — 2026-11-20

The web startup's auto-rejoin read `state.contacts`, a view assigned only by the
scheduled redraw. Loaded settings were already in the store, but startup could
reach auto-rejoin before that redraw and offer Create instead. It now selects
the remembered invitation directly from loaded snapshots. The already-joined
check likewise reads each live snapshot's contacts rather than the rendered view.
The invitation continues to be stored by `ba_contacts` in `settings.config`.

Reproduced in the existing Chromium harness with a saved Gossip 1 invitation,
clipboard access denied and the first redraw delayed. The regression failed
before the fix and passes afterward; all eight browser scenarios and 35 Node
unit tests pass. Static web assets rebuilt. No running Device was changed or
restarted; the owner's actual Gossip 1 state was unavailable through the local
CLI, so its saved link and live reconnection were not inspected. This is a
confirmed startup race, not evidence that old-format state was the only cause.

## Cleanup pass 3 follow-up — 2026-11-20

- Removed unused per-subscription gain from intent, receiver startup, the OTP
  native-media command and both Apple/Windows native command handlers. No caller
  changed its fixed 1.0 value. Subscription intent is transient Session state;
  no persisted subscription migration is needed. Native volume elements remain
  for playback mute/pause.
- Protocols call the existing `ba_session_passport:exact/2` directly: one exact
  map validator, with the duplicate implementation and forwarding helpers gone.
- Fixed the control smoke's expected root supervisor children after passes 1–3.
  Updated component README terminology/renamed links, removed obsolete runtime
  profile/Inspector claims, and replaced the stale pass-3 handover in PLAN.md.

Validation on Windows: core EUnit **182/182**, DeviceWeb **6/6**, Web UI **35/35**,
Python runner tests **2/2**. Public `cli-api-smoke.py` passed. A separate public
CLI cold-restart check created a disposable audio-disabled Device and a Session,
stopped/restarted it, and confirmed the same Device identity, Session and saved
invitation with Reception offline. Only disposable test Devices were stopped.
MSVC `/W4 /WX /Zs` syntax checking of the Windows native host passed; no native
helper was repackaged and no app was deployed. Apple native compilation and
physical playback were not checked here.

The local `session-reconnect-smoke.py` could not start: compiled Phoenix/Elixir
Reception dependencies are absent in this checkout. Its peer/revocation cases
remain unverified. No production Reception request or deployment was performed.
The committed rename intentionally uses new saved-state filenames/version and
incompatible invitations/wire fields; losing pre-rename return state is consistent
with that migration. New-format return works in the CLI check, which does not
prove the owner's Windows app or cross-device reconnection. Next substantial
cleanup remains the periodic UTC clock, then the shared request behaviour.

## Cleanup pass 3: buffee → session rename (wire, modules, API, UI) — 2026-11-20

- **Disambiguated terms (Step A):**
  - Authenticated relationship between two Devices renamed to **link** (`links` in `ba_session_control_protocol`, `link` in message contexts and packet headers, `link_renewed/replaced/expired`, `audio_link_up/down/renewed`, `time_link_down`, `drop_link`, status reply `"link": "authorized"`).
  - Native media worker in audio receiver/source/supervisor renamed to **media** (`media := Pid`, `ba_audio_sup:start_media/1`, diagnostic `transport.media`).
  - "Session" only means the Session itself.
- **Renamed buffee → session end-to-end (Step B):**
  - Modules: All 16 `ba_buffee*.erl` modules renamed to `ba_session*.erl` and all 9 test modules in `src/control/test` renamed to `ba_session*`.
  - Wire & Relay: `ba_reception_sessions.erl` and `ba_relay.erl` use `<<"session">>` instead of `<<"buffee">>`. Wire domains updated (`beamaudio-session-membership/v1:`).
  - API: `create/join/leave/end_buffee` renamed to `create/join/leave/end_session` across core, DeviceWeb, CLI, and WebApp.
  - Swift: `BuffeeRuntime` → `DeviceRuntime`, `BuffeeValue` → `RuntimeValue`, `BuffeeValue.swift` → `RuntimeValue.swift`.
  - Smoke tests: `ba_buffee_control_probe.erl` → `ba_session_control_probe.erl`, `buffee-*-smoke.py` → `session-*-smoke.py`. Leftover test jobs from pass 2 removed from probe and smoke scripts.
- **Validation on Windows:**
  - Core EUnit: 182 / 182 tests pass (0 failures).
  - DeviceWeb EUnit: 6 / 6 tests pass (0 failures).
  - Web UI (Node): 35 / 35 tests pass (0 failures).
  - Python tests: `test_run_tests.py` 2 / 2 pass.
  - Project naming audit: `naming-check.py` 343 / 343 text files pass.

## Cleanup pass 2: test jobs, single sources, dead code — 2026-11-20

- Test jobs removed end to end: `ba_buffee_job`, `ba_device_test_worker`, the job
  offer/cancel/report flow in `ba_buffee_control` and its protocol, the `job_offer`
  right, the `"test"` entry of the signed `capabilities` reply (a wire change, as
  accepted), Session control's monitoring of `ba_device_handler` (it only protected
  jobs), the snapshot's `jobs` field and `BUFFEE_JOBS.md`. `ba_device_handler` keeps
  capabilities and the audio Worker.
- One way for each setting: the default rights list is `ba_buffee_membership:defaults/0`
  (was an app setting written in two places plus two different literal fallbacks);
  the default Reception is only `default_reception_desk_url` in `ba_core.app.src`
  (`ba_buffee_passport:default_desk/0`; three literal copies removed, the CLI no longer
  hard-codes it); the Reception CA is only the `relay_cacertfile` setting
  (`BA_RELAY_CA_FILE` removed).
- No fallback identity: `ba_device_store:identity/0` requires `BA_IDENTITY_SEED`
  instead of silently making a random key; `node_name/1` (Distributed Erlang) removed.
- One hex validator, `ba_hex:valid/2`, replacing two copies and two wrappers.
- Dead API removed: `ba_audio` stubs/aliases (`subscribe`, `ready`, `listen`,
  `watch_sources`, `sessions`, `handler`, `backend`, `close`, `pause`,
  `validate_request`), `ba_audio_receiver` `refresh`/`gain` (and `output_gain`),
  `ba_buffee_desks` `route`/`send_route`, `ba_buffee_membership:depart/0`,
  `ba_desk_connections_sup:stop/1`, `ba_session_scope:spawn_link/1`,
  `ba_stream_handler:default/0`, `ba_native_stop:socket/3` (with its tests); several
  internal helpers no longer exported.
- Tests: the job tests went; the protocol test keeps its sender-signature and
  join-certificate checks on a capability request; tests that relied on the random
  identity now set a seed.

Validation on Windows: core eunit 182/182, DeviceWeb 6/6, web UI 35/35,
`run-tests.py` unit tests OK, xref reports no undefined calls. Core Erlang 365k → 336k
characters, 50 → 49 modules (`ba_hex` added; two job modules removed). Not verified:
app builds and Session-level integration smokes; Apple apps need the new runtime
(the capabilities wire format changed).

## Cleanup pass 1: one runtime behaviour — 2026-11-20

Owner direction: cleanup first, one default way, no fallbacks, work in passes.
The core had three runtime profiles; only `buffee_control` was used by the apps,
yet `legacy_apps` was the default and ~20 places branched on the profile.
- Removed the profile setting and every branch; the `buffee_control` behaviour is
  now simply how the runtime works. `ba_runtime` is just `start/0`; `ba_sup` has
  one child list; `ba_bridge` is only the app-window gate.
- Deleted the trusted-cluster stack, found by reachability from the real entry
  points (`ba_bridge`, `ba_ios`, `ba_cli`/`ba_cli_device`, `ba_device_web_cli`):
  `ba_chat`, `ba_discovery`, `ba_dist_channel`, `ba_inspector`, `ba_legacy_cluster_*`,
  `ba_media_channel`, `ba_native_bridge`, `ba_network`, `ba_node_api`,
  `ba_node_diagnostics`, `ba_webrtc_dist`, `ba_buffees`, `ba_direct`,
  `ba_peer_connection`, `ba_legacy_connection`, `ba_invitation`, `ba_buffee_wire`,
  and `ba_events` (its `ba_pg` scope only ran under the legacy profiles).
- `ba_relay` keeps only its live mode: pid-addressed owners, the Device's own
  identity, an explicit URL, events as `{relay,URL,Event}`. Gone: the registered
  name and API, the throwaway-key `buffee` delivery, the env/app URL defaults and
  `reconnect` (only the legacy API used it). `BA_RECEPTION_DESK_URL` and the
  `reception_desk_url` setting no longer exist.
- Dead settings removed: `audio_consent` (nothing read it), the `consent` option of
  `ba_app_session:configure/1`, the `ba_transport` `native_ice_servers` override
  and iOS's ExICE STUN-host pre-resolution (ICE servers come only from
  `direct_stun_urls`), `config/local.config`.
- Deleted `src/control/transport` (Elixir/Rust), `scripts/build-native.sh`,
  `scripts/setup-host.py`, macOS `package-native.py`, iOS `prepare-transport.py`
  and `transport/`, `src/Tools/Inspector`, the CLI's `inspect legacy`, and
  Reception's legacy HTTP directory (`src/`, `rebar.config`, `run-legacy.sh`).
- Builds: the Mac app no longer compiles the transport or loads `native_lib`; the
  Apple hosts no longer pass a profile; iOS has one runtime variant (no
  `--transport`, no transport NIFs) and links OTP `crypto` with the
  `libcrypto.a` shipped in the pinned iOS OTP runtime, as the former `relay`
  variant did. The CLI build is the core compile plus the native helper.
- Tests: deleted those that only exercised removed code (legacy cluster, chat,
  connection strings, relay client, ExWebRTC carrier, OTP distribution/trust, the
  wx relay UI, Mac bridge/relay smokes, Reception TLS/public client checks). Tests
  of live code that silently ran under the legacy default now set up the real
  conditions: consent via a running `ba_device_config` (`ba_test_consent`), the
  Session state table, an `on_air` grant. Undo/redo now cannot re-grant consent
  in tests either, as in the apps. `relay-smoke.py` became the Reception fixture
  `tests/ReceptionDesk/local_reception.py`.
- Windows build scripts delete a helper folder only after deleting its
  `ba_native_stream.exe` succeeds, so a build never half-deletes the DLLs of a
  running Device (seen with the Web UI running).

Validation on Windows: baseline before the pass was 224/224 eunit; after it core
eunit 203/203 (the difference is deleted legacy-only tests), DeviceWeb 6/6,
`run-tests.py` unit tests OK (two dead assertions about the deleted PCM e2e test
removed; they failed at baseline too), xref reports no undefined calls. Core
Erlang 528k → 365k characters, 71 → 50 modules. Not verified: the Mac app, the
iOS app and their builds (no Mac here; the xcconfig/link changes need an Xcode
build), the Windows app rebuild (blocked while the owner's app and Web UI were
running; the build now refuses cleanly), and the Session-level integration
smokes in `tests/control/`.

## No PowerShell; Windows builds without legacy steps — 2026-11-20

Owner direction: no PowerShell, and nothing builds legacy transports. Every
`.ps1` is gone from both repositories. Windows runs `build.sh` from Git Bash
(or OpenSound's Build.cmd); logic is Python, `.cmd` files call Python directly.
- `scripts/platforms/Windows/setup.py` replaces `setup.ps1` + `erlang-deps.ps1`:
  pinned OTP 29.1.2 and rebar3 3.28.0 (versioned URL), downloaded with Windows'
  `curl.exe` (Python's OpenSSL rejected this PC's certificate chain), verified
  before taking their final name so an interrupted download is retried. Its
  `fetch` is shared by the GStreamer SDK and Reception Elixir downloads.
- Core `build.sh` has a Windows branch: tools, core compile, native AAC host.
  The legacy transport, Python GStreamer runtime, Elixir/Rust/Perl tool setup and
  the unused `windows` rebar profile (`fs`) are no longer built; their scripts
  are deleted. Reception keeps its own Elixir (`ReceptionDesk/run-windows.py`).
- The app window is launched by `ba_device_web_cli` itself (Chrome, then Edge;
  `BA_WEB_BROWSER` overrides, a `.py` stand-in runs under Python because OTP
  refuses to spawn `.cmd`). `open-browser.ps1` is gone.
- `DeviceWeb/run-windows.py` replaces `run.ps1`, keeping the DPAPI
  `identity.dpapi` Web Device seeds; `Start Web UI.cmd` calls it.
- Legacy Inspector Windows scripts removed; use the CLI on Windows.

Validation: both `build.sh` runs from a clean tool state (rebar3 and the
GStreamer SDK downloaded and verified), the app-window lifetime check from
`tests/Windows/shared-web-smoke.py`, DPAPI round trip plus reading the two
existing Web Device identities, DeviceWeb `run.sh --build-only`, Reception
`run.sh --setup-only`. Start Web UI.cmd itself and the full Windows smoke tests
were not run.

## Windows native AAC host — 2026-11-20

Windows had no audio after PCM/Opus were deleted. It now has the native AAC
path. Owner choices: a C++ helper built against the official GStreamer MSVC
package, and FFmpeg `avenc_aac` to keep 320 kb/s (Media Foundation stops at
192 kb/s).
- `src/Audio/adapters/Windows/native_stream.cpp` (`ba_native_stream.exe`) ports
  `GStreamerStreamHost.mm` 1:1 (control protocol, clock mapping, RTCP mapping,
  sink scheduling, watchdogs, stop ACK) with json-glib and Winsock. `atenc`/
  `atdec`/`osxaudiosink` become `avenc_aac`+`aacparse`/`avdec_aac`/`wasapi2sink`.
  ON AIR is one `wasapi2src` loopback (`exclude-process-tree` of BEAM's PID)
  resampled to 48 kHz stereo F32 and fanned out to provider peers, with
  sample-count positions and GstSystemClock host times.
- `ba_windows_native_audio` (capture adapter, same port protocol as the Mac,
  simple `<<1,Rate:32,Channels:32>>` format) and `ba_windows_native_host` (keeps
  one `--host` helper and sets `BA_NATIVE_STREAM_PORT`, restarts with backoff).
  `ba_app_session` selects both for `BA_PLATFORM=windows` when
  `BA_WINDOWS_NATIVE_STREAM_HELPER` names an existing helper. Without it, Windows
  reports sending unavailable and has no output, as before.
- `scripts/platforms/Windows/build-native-stream.py` pins the 1.28.8 MSVC
  installer (SHA-256), installs it once per user into
  `builds/intermediates/Windows/gstreamer-sdk` (no user env var or system
  install observed), compiles with `/W4 /WX`, and packages 34 DLLs + 16 plugins +
  app-local VC++ runtime + licence texts (~43 MB) into `builds/CLI/native-stream/`.
- OpenSound `build.py` copies that to `builds/Windows/OpenSound/audio/`;
  `os_windows_host` sets the helper variable. DeviceWeb `run.ps1 --local-device`
  uses the core build when present.

Validation (this Windows PC): `native-stream-smoke.py` passes against the
Windows helper (244,736 decoded frames, 264 RTCP-mapped packets, mapping in
617 ms, max software schedule error 17.3 ms vs ~5 ms on the Mac, 580 ms jitter
budget; all five lifetime checks pass). A scratch probe with real devices:
WASAPI loopback capture → AAC → silent receiver decoded 239,616 frames, 0 drops;
synthetic → muted `wasapi2sink` rendered 284 buffers, 0 drops, 758 ms jitter
budget after the device's reported latency. eunit: `ba_windows_native_tests`
(real `--host` handshake, port withdrawn on stop), `ba_app_session_tests`
(capability test updated from deleted modules), `ba_native_stream_tests`,
`ba_audio_restore_events_tests`: 16 tests, 0 failures. Packaged app booted
headless with a throwaway identity: `audio/ba_native_stream.exe --host` runs as
BEAM's child on loopback and exits when BEAM is killed.
Not done: no Session-level Windows↔Mac/iPhone stream, no listening test, no
check that the loopback exclusion actually removes local playback, no
microphone, CLI (`ba_cli_device`) still Mac-only. Stale `.beam` files of deleted
modules remain in `builds/intermediates/control` and are copied into app builds.

## Native output latency budget — 2026-11-19

The native jitterbuffer used the entire Session Response time, while the sink
also needed downstream/output lead. The sink offset added render delay again.
The host now uses GStreamer's negotiated downstream latency to reserve that
lead within the existing Response budget, reduces RTP buffering accordingly,
and lets BaseSink submit early for render delay. Capture timestamps, Session
policy and native clock-rate correction remain in force.

The silent native test now simulates a sink with 200 ms render delay and a
20 ms lateness limit. Before the fix it fails with 205 ms presentation error;
afterward it passes with 5.1 ms maximum error, 244,736 decoded frames, 265 mapped
RTP packets, mapping in 621 ms and a 580 ms jitter budget within 800 ms total.
Stop/control loss/timeout/clock expiry/hung-media/source-owner checks also pass.
iOS native source passes a targeted compile check; Mac app packages successfully;
7 native-control tests pass after the diagnostics change. Owner rebuilt both
apps through Xcode and reports **still wavering at 2 s**. Thus the reproduced
software-budget bug is fixed, but the audible wavering is unresolved. Owner
requested stopping for today; no further testing or tuning. The newly enabled
live timing summaries were not read before stopping. Resume from those local
logs next time. Physical synchronization and sound quality remain unqualified.

Added analysis-consented, bounded local timing summaries every five seconds:
clock correction, capture sample-clock skew, decoded/mapped frames/packets,
rendered/dropped output buffers, render delay and jitter budget. No audio data,
SDP or candidate addresses are logged. Initial info-level summaries were filtered
by the default Logger level; corrected to notice. No Inspector remains connected.


## Empty ICE candidate closed native streams — 2026-11-19

Owner clarified the next consent change: Calibration (combined mic/speaker),
Processing (DSP/computing) and Inspect (private data), each Always / Ask / No;
requester-held signed inspection grants persist in its user's memory. Recorded
in PLAN; not yet implemented. The temporary Inspector was stopped on this
clarification; continue diagnosis from the Mac/iPhone's local logs.

- Joined an isolated audio-disabled CLI Inspector and read both app logs. The
  Mac publishes and iPhone clock is ready; answers reach a Mac with no provider.
  Added closure-path/attach/exit diagnostics; a restarted Mac identified
  `signal_send_failed`, excluding the earlier unconfirmed clock-churn theory
  for that observed closure.
- Reproduced GStreamer's empty ICE end-of-candidates event. The stream schema
  rejected empty strings, so sending that valid event closed the media attempt.
  Allow the empty marker while retaining binary type and 1,024-byte limit;
  native GStreamer already accepts it. Both apps require the updated runtime.
- Added a regression through signed control-message sending and receiving,
  including rejection of non-string and oversized candidates. It fails before
  the fix; afterward 41 focused control/native/publication tests pass. Mac app
  rebuilt; iPhone runtime prepared with zero unresolved core imports. No iPhone installation or
  listening acceptance performed by the agent. First owner retry was silent,
  but process inspection confirmed the Mac still ran the pre-fix 21:29 process;
  requested a full Quit/reopen. The exact signal kind and send error are now
  logged too. After the actual Mac restart, owner confirms audible short bursts
  from the iPhone; provider teardown now says `remote_close` every ~3.5 s.
  Requested Xcode Stop/Run on the iPhone to install the updated runtime; its
  remaining use of the old schema is suspected, not yet confirmed.
- Native smoke passes (241,664 decoded frames, 272 RTCP-mapped packets, mapping
  in 493 ms, maximum software schedule error 5.2 ms). Earlier lifecycle checks
  and a disposable real OTP-to-native provider handshake also pass. These are
  software checks, not proof of phone playback or physical synchronization.
- Owner supplied an Xcode crash in libnice 0.1.24 `_tcp_sock_is_writable`
  (`peer:ice`, EXC_BAD_ACCESS), preceded by GLib bad-descriptor warnings. A
  lifetime/cleanup error is suspected, but the root cause remains unproven.
  Do not claim that this signalling fix also fixes the native crash.
- Initial native clock-plan failures now retain their reason instead of being
  flattened into `native_lifecycle_handshake_failed`.

## Native capture follow-up — 2026-11-19

After both apps updated, owner reports one open transport on each Device;
150 ms is silent, 800 ms plays with wavering, and 2 s has the same wavering.
This establishes audible native Mac→iPhone transport, not acceptable quality.
Mac logs also show `native_capture_discontinuity` (capture sample position
before the stream anchor). The capture helper previously rewrote the tap
process list for every system audio-process-list notification, even when the
excluded set did not change. It now compares sets and skips those no-op writes.
Mac helper and app compile/package successfully; owner listening retest pending.
The relation between these writes, observed resets and wavering remains an
inference. Legitimate capture-clock resets still terminate a media stream;
no speculative timestamp-recovery engine or library upgrade was introduced.
Owner retest reports essentially unchanged wavering. Later logs show repeated
`presentation_changed` provider failures; added old/new delay and policy revision
to that diagnostic and rebuilt the Mac. The steady-run log showed manual changes
150→300→800→2000 ms with the same timeline; autonomous policy churn was not
established. Follow-up native output-budget regression/fix is documented above.

## Evening live testing — 2026-11-19

- Gossip ON AIR crash fixed (atom vs binary note kind crashed membership).
- Web Device could not join: its process had run since 17 Nov (old protocol);
  a Mac restart fixed it. Joining a second Session verified with CLI Devices.
- Apps now also log to `runtime.log` in the Device state folder (rotated).
- Receiver logs the reason for discarded stream messages; its first version
  crashed the receiver (fixed, guarded). iPhone audio still not playing; see
  PLAN "Resume here".

## One Mac, one Device key — 2026-11-19

The Mac app lacked admin rights in a Session because it had started as a second
desktop Device: each window/copy took the first free identity slot, and slot 2
is a different key from the creator named in the invitation. Owner decision:
a Mac app always uses its one key. `NativeIdentity.loadDesktop` now always uses
the single identity and refuses a second running copy ("OpenSound is already
running on this Mac"); the app has one window (`Window`, not `WindowGroup`).
The creator is recognized by the public key in the invitation and proves it by
signing; Reception never issues keys (a fresh key is only for a kicked Device,
in the rights plan). Existing slot-2 data is left on disk unused. Validation:
`tests/apple/desktop-instance-smoke.py` passes; Mac Xcode scheme and app build
succeed.

## No Manager: request board, gossip and sealed messages — 2026-11-19

Owner direction after the web app could not reach the Manager's request board.
- The Manager role is gone: newcomers fetch the signed statement from a random
  reachable neighbour; the Device list and change recipients no longer include
  a Manager. (The `manager` field remains in the signed statement format until
  the rename/format change.)
- Reception's present Devices become a sticky random sample (keep present
  neighbours, fill free places at random, at most 32).
- `ba_session_board`: signed request entries (with the requester's join
  certificate) and grant holders' signed `granted`/`declined` answers. Merge is
  a union by ID; a request is open until answered, held, or a day old. Boards
  sync on every new contact and new entries are forwarded to neighbours, a few
  per message. Grant holders decide new requests by their Always/Ask/No answer
  (No posts a decline). The point-to-point `privilege_request` message is gone.
- `ba_session_gossip`: ON AIR sends a signed `on_air` note to neighbours; each
  Device checks it, acts once (reads that source's catalogue; announced sources
  count as known for a minute so the read follows a hello), forwards it, and
  forgets it after two minutes. The source re-announces every 30 s.
- Every control message is sealed with ChaCha20-Poly1305 (key from the link
  secret, Session ID as associated data); Reception routes opaque bytes.
  Signed messages are capped at 24,000 bytes so sealed ones fit 32,768.

Validation: eunit 224 tests, 0 failures (board, gossip, envelope tests added).
Local-relay smokes pass: crash-chat, session-moderation, session-privileges
(request/Ask/decline/grant/take/No/Always on the board), buffee-membership,
buffee-time, parallel-sessions, cli-session-memory. Gossip beyond direct
neighbours and the web-app board case were not exercised by a test; no app
build or live check of this change.

## Mac app ON AIR restored through the native helper — 2026-11-19

The Mac app's ON AIR greyed out after PCM was deleted: the app bundled no native
helper or GStreamer. The app build now builds `ba_native_stream`, copies it into
`Contents/MacOS`, and `scripts/platforms/macOS/package-gstreamer.py` copies only
the selected plugins and the libraries they and the helper load (27 libraries,
17 plugins, 53 MB instead of the ~700 MB runtime) into `Resources/gstreamer`.
`MacErlangRuntime` sets `BA_MAC_NATIVE_STREAM_HELPER` and `BA_GSTREAMER_RUNTIME`.
GStreamer's registry now lives in the Device state folder (writable, outside the
signed bundle) and plugin scanning runs in-process (`GST_REGISTRY_FORK=no`).
`native-stream-smoke.py` accepts the same two variables and passes against the
bundled files; a cleanup race in its lifecycle check (broken pipe after an
intended helper exit) is now tolerated. Not yet: the Mac app still cannot play
received audio (no native receiving host in the app), and ON AIR was not
pressed in the running app. Dev builds rely on `DYLD_LIBRARY_PATH`, which a
hardened-runtime release build would block.

## One audio transport: PCM and Opus deleted — 2026-11-19

Owner decision: native AAC (GStreamer RTP) is the only transport; delete PCM and
Opus now and accept the gap. Deleted: PCM and Opus stream handlers, packet codec,
Erlang Mixer/mix, PCM media session (ex_webrtc data channel), PCM input, meters,
presentation/RTP-time helpers, Mac/iOS/Windows PCM adapters (Erlang, Swift, C++),
`DeviceAudio.swift`, `opus_capture.inc`, the Opus/PCM build steps in the CLI, Mac
and Windows builds, and their tests. `audio_input.mm` builds only the native
helper. Native is no longer gated by `BA_NATIVE_STREAM_TRIAL`: the iPhone always
starts its native host, the CLI always uses the native helper, and the receiver,
source, stream protocol and handler selection accept only `gst_aac_rtp_v2`.
`ba_no_capture` reports sending unavailable on platforms without native capture.
Native ICE server selection moved into `ba_native_media_session`.

Validation: eunit 219 tests, 0 failures; xref shows no calls to deleted modules
(ExWebRTC entries are xref's existing blind spot for Elixir). The native helper
rebuilt from the native-only `audio_input.mm`. `native-stream-smoke.py` passes:
253,952 decoded frames, 283 RTCP-mapped packets, mapping in 231 ms, max software
schedule error 5.1 ms, lifetime checks (control EOF/timeout, clock expiry, hung
media, source-owner EOF) pass. The PCM end-to-end test was deleted with its path.
Builds (follow-up): `build.sh all`, the Mac app `build.sh`, and the Xcode "OpenSound
iPhone" and "OpenSound Mac" schemes (unsigned) succeed. Fixes: core `build.sh`
built the deleted Opus preparation; the iPhone runtime used the deleted
`IOSBroadcastAuthorization`. The iPhone app also no longer suspends audio when it
goes to the background (it used to disconnect every stream unless broadcasting),
per the owner's background-playback requirement; background playback on a
phone is not yet observed. No listening test.

## Join from a copied invitation (OpenSound UI) — 2026-11-19

When OpenSound starts or comes to the foreground, a `beamaudio://` link newly
on the clipboard opens the Join dialog, filled in, unless a remembered Session
(`contacts.sessions`) already has that link (each Session has one permanent
link) or the same link was already offered. On startup this runs before the
automatic return to the last Session. It never opens over another dialog.
Apple hosts read through a new `native_clipboard` bridge method that only reads
when the pasteboard change count moved and it holds text or a URL; the browser
(Windows app window, web) uses `navigator.clipboard.readText()` and stays quiet
where the browser refuses. Logic: `WebApp/public/clipboard-invitation.mjs`.

Expected platform behaviour, not yet observed: iOS shows its "Allow Paste"
prompt the first time new clipboard text is read (Settings can set Paste from
Other Apps to Allow); recent macOS may show a similar paste prompt; Chrome/Edge
ask once for clipboard permission. Validation: web unit tests 33 pass
(node@22); OpenSoundKit `swift build` for macOS succeeds; the iOS branch and the
apps were not built or run.

## Dark Sessions: join certificates replace membership — 2026-11-19

Owner direction: Devices only see the Devices they bump into, plus the Manager;
nobody knows who else is in the Session. Implemented:

- **Admission per request.** The invitation key is derived from the existing
  link secret (old links keep working). Each Device signs its own join
  certificate; control protocol v3 carries it on every packet and the receiver
  checks it against the public invitation key, with no cache. The membership
  pairing handshake, participant list, `pairs`, presence handling, the
  `membership` Reception message type, `peer_online/1`, route exchange and
  the 32-peer/15-participant limits are removed.
- **Rights.** The control layer takes members' rights from the signed
  statement and default rights for every other joined Device, refusing removed
  Devices. Rights changes apply in place without restarting relationships. A
  grant holder's change goes to rights holders before and after, the removed,
  the Manager and its encountered Devices; on every new relationship the side
  with the newer revision sends its statement (`session.request` kind
  `policy`). A Device with no statement yet checks in with the Manager.
- **Addressing.** Any Device ID is reachable at the Session mailbox; Reception
  lookup supplies at most 32 neighbours (`participants` in status).
- **Device list.** This Device, the Manager and Devices it has encountered (at
  most 64); Connected means a live relationship. An explicit `monitor --all`
  also reads Reception's reachable Devices.
- **Clock.** Authority placement uses Reception reachability; this fixes the
  regression where the timeline changed after the first grant holder left.
- **ON AIR push.** A Device with live sources sends `catalog.changed` to the
  Devices it can reach on each change, to newly reachable ones, and to all every
  30 s. Listeners read only announced sources and sources they already know
  (offers, saved subscriptions), re-reading those every 5 s; a lapsed known
  source gets a hello. Hello-to-everyone audio discovery is gone. An offer
  arriving while Playback is not allowed asks this Device's user, naming the
  ON AIR Device ("open your speakers").

Validation: eunit 269 tests, 0 failures. Local-relay smokes pass:
`crash-chat`, `session-moderation`, `session-privileges` (after narrowing one
expectation to need-to-know and waiting for the 2 s reachability report),
`buffee-membership`, `buffee-time`, `parallel-sessions`, `cli-session-memory`,
`cli-smoke`, all rerun after the ON AIR push change except `cli-smoke`.
`session-moderation-smoke` no longer waits for the moderator to see its target
(dark Sessions: kicking needs only the Device ID). `cli-buffee-smoke` reads all three Devices but fails
its name check because labels now read `Mac | test1 | …` rather than `test1`;
this is label format, not this change. `session-peer-admission-smoke` asserts
v5 links and was already outdated; `device-label-smoke` needs a Windows
runtime. `device-session-e2e.py` (headless WebRTC with a test sink): the ON AIR
push delivers both offers and the listener subscribes, but media setup never
reaches active (receiver rejects `accepted`/signals: invalid_media_signal 4,
invalid_control_or_attempt 2, stale signals). The same test at 97770c0 (before
today's control work) fails at the same step with the same counts, so this is
pre-existing and not yet diagnosed. No audio was heard; no app build or live
multi-Device check.

## Session requests through the pipeline — 2026-11-19

`privilege_request`, `privilege_release`, `rename_request`, `remove_request` and
`ended` left the membership channel. They are one signed control operation,
`session.request` with a `kind`, validated by schema, authorized by the
`ba_device_request` rights table (rename: on_air; remove and End: end_session;
privilege ask/release: anyone) and executed by membership on the grant holder or
target. Always/Ask/No for rights requests is `ba_device_request:approve/2`;
pending requests stay in membership's per-Device list. End no longer needs the
pairing token; `pairs` bookkeeping was removed. Local consent asks (speaker,
microphone, calibration) also call `approve/2`. Publisher stream admission and
execution-time consent checks in adapters stay where they are.

Remaining outside the pipeline: admission. Control accepts packets only from
peers that completed the membership HMAC pairing, so pairing is still the
Session-wide authentication step.

Validation: eunit 269 tests, 0 failures. Local-relay smokes
`session-moderation-smoke.py` and `crash-chat-smoke.py` pass.
`session-privileges-smoke.py` passes every privilege request/answer step, then
fails twice at the clock timeline check after the first grant holder leaves; not
yet diagnosed, likely from control v2 (no standing links between remaining
Devices). No app build or live check.

## Control requests authenticate themselves (protocol v2) — 2026-11-19

Owner direction: authenticate when something needs approval, not by keeping
every Device in the Session authenticated. `ba_buffee_control_protocol` v2
removes the hello/challenge/proof handshake and nonce lease renewal. Each packet
carries the sender instance, a rising sequence and the sender's wall-clock time.
The receiver accepts it if all of these hold: the signature and current policy
check out, it was sent within ±5 minutes, its sequence rises within that
instance, the instance has not been replaced, and an unknown instance's packet
was sent no more than 2 s before the receiver's state started.

A relationship starts with the first valid packet, is extended by traffic and
lapses when idle; lapsed and closed relationships keep replay state.
`ba_buffee_control` no longer runs the 250 ms connect-everyone loop or
background renewal; `connect/1` is one `hello`/`ready`. Consumers follow:

- the clock introduces itself to its authority, at most every 2 s;
- the monitor reads peers directly;
- audio discovery no longer limits introductions to the lower Device ID;
- the receiver accepts renewals whose deadline has since moved later;
- the app's Device list shows Session presence (membership participants)
  instead of control-link state.

Decided during implementation: the first proposal's timestamp-only approach was
kept rather than a lazy handshake, because chat and other one-shot requests then
need no send queue. Accepted consequence: Devices whose wall clocks differ by
more than 5 minutes cannot exchange control messages. Residual replay window:
packets sent in the 2 s before a receiver restart. v1 Devices cannot talk to v2
Devices; every Device needs the update.

Validation: full eunit 267 tests, 0 failures (handshake/lease tests replaced by
freshness, replay, restart, lapse/resume, renewal and simultaneous-hello tests).
Local-relay smokes `crash-chat-smoke.py` and `buffee-membership-smoke.py` pass.
`buffee-reconnect-smoke.py` fails at the grant holder's restarted Session-name
check, a membership persistence step; whether it failed before this change was
not established. `buffee-control-smoke.py` defaults to the public Reception and
was run once against it before its beams were rebuilt (old code); it was not
rerun. `device-session-e2e.py` was updated to introduce peers explicitly and was
not run. No app build or live multi-Device check was performed.

## One request/approval pipeline, first increment — 2026-11-19

`ba_device_request` now holds the stages a Device applies to every remote
control request: authenticate (existing per-packet Ed25519 verification and
policy check in `ba_buffee_control_protocol:receive_packet/4`), authorize (one
table of the Session rights each operation needs, replacing five separate
checks in `dispatch`), approve (`approve/2`: Always approves, Ask records a
Requests entry via `ba_device_config:request/2`, No refuses), then execute.
Refusals keep each operation's existing wire error reply.

Behavior change: a job offer to a Device whose DSP consent is Ask now raises a
Requests entry naming the requester instead of rejecting silently; the offer is
still answered `consent_required` and the requester's retry is a new request.

An earlier uncommitted draft re-verified the same signed packet inside
`ba_device_handler` and wrapped local API commands in a no-op pipeline. Both
were removed: the second check verified identical bytes again, and local
commands are the owner's own decisions. Per-request authentication still relies
on the pairwise control handshake/lease; membership requests keep their own
approval storage. Validation: full eunit, 270 tests, 0 failures; no live
Session, smoke test or app build was run.

## Request approval and verification direction — 2026-11-19

Owner clarified that the Device receiving/executing an action approves the
request through one common pipeline, including requests from a Manager. Approval
can be automatic but remains an explicit stage with identity/authorization
checks before execution. Managers receive no extra privileges from placement.
Record this as the next control design, alongside on-demand relationships and
local signed-policy verification; it is not implemented by the cleanup passes.

The current control protocol verifies an Ed25519 signature on every received
control envelope and checks locally installed Session policy. A one-shot
microbenchmark on this Mac ran 5,000 OTP crypto signature verifications in
202.1 ms, approximately 40.4 microseconds each. It used a generated diagnostic
key and a small constant message, with no real identity, network or Device work.
This measures the cryptographic primitive only, not parsing, delegation chains,
full approval latency, phone performance or hostile traffic capacity.

Owner decision after that measurement: **do not cache verification results**.
Verify request signatures and supplied grant/delegation evidence per request,
then check replay protection, current Session policy/revocations, local consent
and the explicit approval decision. Signed Session policy and revocation records
remain necessary state; they are not cached successful-verification decisions.
This supersedes the earlier caching recommendation. No request/approval
implementation or live behavior changed in this discussion.

## Second unused-code cleanup — 2026-11-19

Removed the old Windows meter-only capture server and its unused native helper
(`ba_windows_audio` / `audio_input.cpp`), plus the abandoned Python WebRTC receiver
left after the first pass removed its launcher. Current Windows capture/playback
use `ba_windows_input`, `ba_windows_output`, `audio_capture.cpp` and
`audio_output.cpp`; their callers/build inputs are retained.

Removed the obsolete per-packet GStreamer scheduling planner, its five tests,
standalone proof/escript and Windows proof launcher. Removed the unreferenced RTP
target-extension prototype/tests for that superseded design. The live legacy
Opus path has separate RTP target handling and remains wired; it was not mistaken
for dead code. The native AAC timing/lifetime checks remain the maintained
replacement. Removed an unused native capture-position accumulator; actual PTS
continues to use Core Audio sample positions.

The retained comparison had imported SDK setup from the removed proof. Extracted
that setup to a small `experiments/gstreamer/runtime.py` and reused it from both
the comparison and raw-audio measurement tools, removing their duplicate loader.
Updated experiment instructions and current architecture documentation instead
of leaving commands for deleted implementations.

Validation: core compile and **268 remaining EUnit tests pass** (five removed
tests belonged to the retired planner); all three receiver-analyzer tests pass.
The shared runtime loads pinned GStreamer 1.28.8 and finds the required WebRTC/
jitter-buffer factories without starting media. Mac native-host syntax and
remaining Python entry-point checks pass. No Windows build, app build/deployment,
new listening test, broad registered-suite run or live Device operation.
Core test log: builds/test-results/cleanup-pass2-20261119/core-eunit.log.

Scale requirement recorded in AGENTS.md, ARCHITECTURE.md and PLAN.md: ordinary
Devices must avoid periodic Session-wide pings/scans; routine checks should be
scoped and concurrent. Inspection confirms that explicit CLI `monitor --all`
collects peers concurrently, but current control still scans authorized peers
and maintains their links from a 250 ms tick. That is an existing scaling limit,
not removed or benchmarked here. Cleanup adds no polling, fan-out or central
coordinator; topology/liveness redesign remains separate work.

## First unused-code cleanup — 2026-11-19

Owner reports audio works OK, pauses the audio migration and requests an
incremental cleanup before committing. Removed the uncalled receiver-only
`ba_audio_engine` selector, its two adapters/shared socket binding, the unused
per-packet GStreamer control helper and unused Windows playback launcher. Removed
their dedicated tests and obsolete execution-gate assertions. The stream-handler
behavior no longer requires the uncalled `output_control/2` callback or the removed
engine's types; actual native controls remain on the owned Media Session.

Removed the two iOS receiver hosts never constructed by the app, their old Opus
receiver/custom output implementation and Google WebRTC framework/header/resource
packaging. Extracted the static GStreamer initialization still needed by the AAC
trial into `IOSGStreamerRuntime`, which does no transport, playback or event-loop
ownership. It validates the actual AAC pipeline factories and propagates an
initialization error to the native host. The libwebrtc comparison's minimum-delay
binding now lives with that experiment; unused RemoteIO timing helpers were
removed. The working PCM path, opt-in Opus handler and native AAC trial remain.

Validation: core compile and all **273 remaining EUnit tests pass** (11 removed
tests belonged to the unused implementations). Targeted iOS arm64 compiler checks
pass for the small runtime initializer and shared native stream host. Xcode
project syntax/reference checks and runtime-preparation syntax pass. No full app
build, deployment, live setting change, audio listening or broad test-runner pass.
See the current Audio README for ownership/usage; the obsolete engine interface
documentation was reduced to the implemented contract and retained media paths.

Capture separation discussion: Core Audio process taps can exclude our playback
while other apps' audio is captured on the same physical output. Existing Mac
capture already excludes the configured playback-helper executable across local
instances and refreshes the process list. Coverage across different builds or
future native output hosts still needs verification; no capture behavior changed
in this cleanup. This can be handled in the native adapter without moving audio
through Erlang or adding a virtual audio driver.

## CLI confirmation of the active audio path — 2026-11-19

Joined Paavo 007 with a fresh, audio-disabled Inspector through the public CLI.
After discovery settled, both Mac and iPhone returned current metrics. The
running Mac runtime has no `BA_NATIVE_STREAM_TRIAL` setting and uses
`ba_audio_input`; the catalogue advertises legacy float32 PCM. The iPhone reports
the Erlang Mixer and the existing iOS output backend. **The observed stream is
legacy PCM, not the new native AAC trial.** This resolves the uncertainty in the
earlier listening report for the presently running apps; it does not prove which
settings every earlier app instance used.

Across about 30 seconds: Mac sent 2,847 media packets and its capture-drop count
increased by one. iPhone received 2,823 packets, submitted 1,435,392 frames, and
dropped **21 overlapping blocks**. Its late/missed-target counters did not grow
in that interval; two additional long mixer wakeup gaps were recorded. The
cumulative maximum mixer wakeup gap was **3,074 ms**, not a newly measured stall
duration. Receiver and source reported Response time **840 ms**; the older local
Web Device still reported 150 ms. Capture and phone speaker both reported running
with fresh nonzero meters. Counters do not establish audible output or explain
every discontinuity, but ongoing overlap rejection is confirmed independently
of the historical lateness counts.

The native AAC implementation therefore still needs a real-device test with its
profile positively selected. Do not infer AAC codec quality from this legacy
run or expand the Erlang media path to address it. No capture, playback, Response
time, consent or app-instance settings were changed. The temporary Inspector was
stopped after collecting the samples. Private local snapshots and a bounded
summary are in builds/CLI/private/audio-path-check/; invitations are not copied
into this report. No implementation changes or automated test run.

## Manual Mac → iPhone feedback — 2026-11-19

Owner reports music plays and iPhone speaker activation stays on reliably, but
quality is imperfect and playback remains discontinuous. Mac ON AIR behavior
was incorrect; the exact start/stop/button-state failure needs clarification.
50 ms Response time is too short in this run; other tested values worked.
Switching from 50 ms to Automatic produced roughly 10–20 seconds of glitchy
audio before settling around 150 ms. At 150 ms playback works but still has
interruptions. This establishes audible playback, not music-quality acceptance
or synchronized speakers.

**Backend qualification remains open.** Read-only CLI inspection through the
existing local Web Device sees a `Mac default output` offer with a PCM descriptor
and no native handler/transport marker. This is a legacy offer, not evidence for
`gst_aac_rtp_v2`. Direct Mac/iPhone metrics timed out, so that catalogue observation
does not conclusively identify the entire listening run. Do not count it as
native AAC acceptance without confirming the active offer/backend. No settings,
audio toggles or user Devices were changed during inspection.

Code inspection: legacy lateness summaries run every five seconds, consistent
with multi-interval Automatic settling but not a proven explanation for this
run. The native trial does not yet submit lateness advice to Automatic and
currently recreates streams on Response-policy changes. Both remain step-4 gaps.

Reverse ON AIR testing is blocked by this build's explicit iOS ≤26 capability
gate. Its other-app capture implementation uses the iOS-27 ScreenCaptureKit path;
there is no ReplayKit broadcast extension for iOS 26. Microphone sharing remains
available through the existing path; it would not qualify reverse native AAC.
Apple documents the older [ReplayKit broadcast-extension mechanism](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler).
No implementation changes, build, deployment or automated tests in this feedback
triage; current code and user observations were inspected and recorded.

## Native Session-clock scheduling — 2026-11-19

Connected plan step 3 in the opt-in AAC trial. New `ba_audio_native_clock` maps
five local native clock probes through the existing Session presentation API;
the lowest-round-trip observation establishes the clock before prepare. Refreshes
every five seconds command bounded ±500 ppm correction without a clock phase
step. Native mapping expires after twelve seconds independently of control
heartbeats. A changed Session timeline or Response-policy revision ends the
stream; the source publication rebinds when the Session timeline changes.

Core Audio sample positions and the first matching host-time anchor determine
capture timestamps. A private calibrated GstClock supplies the Session reference
in the NTP epoch; native RTP/RTCP sender reports carry the sample-clock mapping.
The receiver uses GStreamer's reconstructed reference timestamps, gates unmapped
packets and schedules output at capture time plus Session Response time, accounting
for native pipeline latency. A short initial sender-report burst fixes an observed
4–5-second acquisition wait when the first report precedes usable RTP state.
The media profile is now `gst_aac_rtp_v2`; both hosts must rebuild, with no
fallback to unscheduled v1 media. PCM/encoded audio remains entirely native.

Validation: core compile/EUnit **284 tests, zero failures**. The native helper
builds and shared iOS source passes a targeted arm64 compiler check. The silent
synthetic test uses a reference three hours away from OS UTC: both peers connected,
mapping acquired in **427 ms**, two clock calibrations occurred, **243,712 frames**
decoded, and maximum software-sink target error was **5,074,897 ns**. Both stops
were confirmed. All five native lifetime cases pass: control EOF/timeout, expired
clock mapping despite live heartbeats, blocked media loop and source-owner EOF.
The test runner now declares this smoke's macOS/helper prerequisites.
Logs: builds/test-results/native-clock-20261119/.

Limits: this measures local software scheduling, not Session clock accuracy
between Devices or physical speaker synchronization; status stays
`synchronized=false`. Local control RTT is exposed, not a global uncertainty
bound. Real Mac capture → iPhone listening, full app builds/deployment, hardware
rate correction and physical stop tail remain untested. Demand-based capacity,
combined queue accounting, loss recovery and seamless policy changes remain step 4.
No live Devices were changed.

## Full registered test run — 2026-11-19

Ran OpenSound/scripts/test-all.sh against the current checkout: all 60 registered
suites/scenarios were selected. Result: **35 passed, 14 failed, 11 unavailable**.
The core EUnit suite passed all **283 tests**. Native AAC media/lifetime smoke,
OpenSoundKit Swift and web frontend tests passed. Clock production cadence,
125-second renewal and maximum-delay renewal also passed.

The full suite is not green. Failures include DeviceWeb's socket-bridge test,
the older core Swift UI tests (removed ChatRuntime/ChatSnapshot types), older
control/layout/reconnect/identity assertions, two clock/startup/reference-restart
audio cases and legacy Reception/transport/trust smoke tests. Follow-up triage
found **no confirmed AAC-refactor regression**: runtime scenarios also fail
with the pre-refactor modules, while two fail at different timing/connectivity
assertions; stale UI/launcher/API assertions are unchanged. This is a bounded
comparison, not proof that every failure has the same cause. See
[the triage report](TEST-TRIAGE-2026-11-19.md). No failing application/test code was changed in this
verification. Unavailable scenarios need another platform, missing bundles,
BA_GSTREAMER_PYTHON or the configured Chromium executable.

Machine-readable results:
builds/test-results/20261119-092300/summary.json.
This supersedes any interpretation that the earlier focused checks established
an entirely passing repository suite; device listening remains unverified.

## Native AAC stream prototype — 2026-11-19

Implemented the first opt-in native Mac source → iPhone receiver path, using
Apple AAC-LC at 320 kb/s stereo and GStreamer RTP/WebRTC (DTLS-SRTP). The owner
clarified that high-quality music compression is acceptable and approved this
recommendation; the earlier bit-exact float requirement no longer applies to
this selected profile. Source format stays float32 metadata; `atenc` currently
requires native 16-bit PCM input. No custom codec, voice processing or Erlang
media forwarding is added.

Core changes: a native Core Audio helper build drains capture within native
code; an OTP source adapter publishes the explicit `gst_aac_rtp_v1` transport
profile; the existing Audio supervisor dispatches its native Media Session;
subscription output/gain bypass the Erlang Mixer. Local native control is
versioned/generation-fenced JSON only. The new session registers for consent
revocation, monitors required owners/supervisors/registry, checks authorization
on heartbeats and waits for correlated native stop completion. Source helper
ownership is tied to its requester and required OTP owners.

Native lifecycle: control socket EOF starts teardown independently of the media
loop; missing control expires after two seconds. A 1.5-second stalled cleanup
forces helper/host exit. Source-pipe loss forces the Mac helper out even during
startup. No detached media process is created. iOS reuses IOSAudioSession's
existing shared acquisition/release mechanism so stopping one playback client
does not deactivate another recording/output client.

Validation: Mac helper builds. Native synthetic AAC → RTP/WebRTC → decode with
silent output connected both peers, decoded 105,472 frames in the recorded run,
and confirmed both stops. Native checks pass for control EOF, control timeout,
stalled media-loop forced exit and source-owner EOF. Focused Erlang engine,
setup/app and native ownership/profile checks pass: 24 distinct tests, including
all six final native tests after adding registry-loss coverage. iOS native source and
Swift session/bridge API pass targeted compiler checks; Xcode project syntax
passes. Initial socket tests were denied by the execution sandbox and passed
when rerun with loopback access. No live Device was inspected or changed.

Limits: **development trial only**, `BA_NATIVE_STREAM_TRIAL=1`; default remains
legacy. At this prototype stage Session timing was not connected; the later
step-3 work above supersedes that limitation. Status reports synchronized=false.
Buffer-demand policy and the
combined ten-second queue budget are unqualified (trial starts at 800 ms).
TURN is explicitly unsupported in this new binding. Full iPhone/Mac app builds,
real capture → iPhone connection/listening, OS route changes and physical stop
tail/speaker synchronization were not tested. Other inputs remain legacy.
Usage and exact continuation are in src/Audio/README.md and PLAN.md.

## Native backend selection and control contract — 2026-11-18

Selected GStreamer for the first complete native stream integration after
inspecting the existing GStreamer/libwebrtc bindings, isolated scheduling and
receiver experiments, production Media Session and OTP consent/stop machinery.
The selection is based on explicit media timeline/lifecycle control, not a claim
that the earlier tone comparison proves superior music quality. NetEq's current
binding does not execute Session presentation or explicit rate correction.

Recorded the replacement control contract in AUDIO_ENGINE_INTERFACE.md, with the
older per-packet receiver interface marked legacy. OTP remains the authority:
streams must stop on owner/supervisor/authority/runtime loss, including forced
native termination after bounded cleanup. Endpoint loss triggers teardown but
is not a stop acknowledgement. Variable native buffering is supported by design
up to ten seconds, not a fixed ten-second prefill, and must be flushed on stop.

Concrete gaps found: iOS GStreamer close returns after queuing teardown; Windows
receiver teardown and helper exit depend on the GLib loop; the shared native
binding closes its socket without confirmed stop and refuses the current
profile. The receiver engine abstraction has no production session caller in
this checkout. Existing prototypes cannot be described as an integrated path.

Validation: source inspection and primary OTP/GStreamer/NetEq documentation;
documentation diff/links checked. No runtime sources changed, backend enabled,
compilation, automated tests, app build, deployment or live Device operation.
Step 1's assessment/contract are recorded; its lifecycle implementation is still
open, beginning with a disposable endpoint and native crash/stop enforcement.
The five implementation steps and retained legacy issues are in PLAN.md.

## Native media boundary and buffering audit — 2026-11-18

The owner explicitly clarified that Erlang is the piping/control system and
audio must never travel through it. Both PCM and encoded payloads must remain
in native/OS media components; Erlang retains Session control, consent,
supervision, clock/presentation policy and timing/diagnostic metadata. Updated
repository instructions and PLAN accordingly. The default implementation still
violates this boundary: native capture → Erlang PCM interpretation/transport/
Mixer → native output. The encoded Mac path also sends Opus through Erlang.
Existing GStreamer/libwebrtc prototypes cover parts of a native implementation;
their common binding currently refuses `buffee_control` with
`native_revocation_protocol_required`. No native pipeline was switched on and
no runtime source was changed by this audit.

For one 48-kHz stereo float32 stream, payload storage is 384,000 bytes/s:
3 s = 1,152,000 bytes and 10 s = 3,840,000 bytes, excluding queue/library overhead.
With 512-frame input blocks these need 282/938 blocks. The existing shared
Erlang queue allows 32 MiB total, 8,192 total blocks, 4,096 per source and targets
up to 31 s ahead: enough for either duration for one such stream, not an
unlimited multi-stream guarantee. Seven existing Mixer checks passed, including
two 30-second streams queued and drained in virtual time. This proves shared
software buffering, not native ten-second playback or physical synchronization.

Native iOS allows 2,048 scheduled buffers and targets up to 35 s ahead. At the
current 256-frame output size, 3 s needs 563 buffers and 10 s needs 1,875; ten
seconds leaves little count headroom, and smaller fragments consume more slots.
The Mac native helper allows only 128 buffers and targets less than 1 s ahead:
about 0.683 s at 256 frames/48 kHz. The current Mixer submits at most 500 ms
ahead even when Response time is 3 or 10 s, retaining the rest in Erlang.
Therefore today's native path does not provide the requested cross-platform
3/10-second preloading. Windows has a native target-indexed queue and a small
hardware buffer, but this audit did not qualify its memory bounds or ten-second
native playback. Native queue budgets should be expressed in time/frames and
bytes, with actual device tests, rather than assumed from nominal buffer count.

Transport audit found unordered delivery with retransmission disabled, plus a
receiver that rejects any sequence older than the last accepted one. Even an
early reordered packet can therefore be discarded before the timed queue.
Waiting longer does not recover loss. Quality-first native integration needs
reordering and deadline-bounded recovery, alongside sample-clock correction.
Capture targets currently use native capture timestamps, not encoding completion
time; processing stalls do not automatically add delay or rewrite old targets.

The owner proposed continuous sample-ordered audio with a global-time code about
every five seconds. Standard RTP timestamps plus RTCP Sender Reports provide
this media/global-time correspondence (RFC 3550 §6.4.1); RFC 7273 distinguishes
reference and media clocks, and RFC 6051 addresses rapid initial synchronization.
Send an initial mapping on join/start, maintain sample continuity, and apply
controlled corrections rather than stepping at every report. The owner accepted
this recommendation before handing off to a new chat. It replaces the earlier
independent absolute-target requirement in the architecture, but the runtime
still uses that legacy protocol; no native migration has been implemented.
Current clock accuracy is unqualified: a measured ~100 ms timing RTT permits
roughly ±50 ms path-asymmetry error for that exchange before master/local mapping
errors; larger audio buffers do not reduce this uncertainty. External UTC error
shared by all followers is distinct from relative speaker alignment.

Primary references: [RTP/RTCP](https://www.rfc-editor.org/rfc/rfc3550.html),
[RTP clock sources](https://www.rfc-editor.org/rfc/rfc7273.html),
[rapid synchronization](https://www.rfc-editor.org/rfc/rfc6051.html),
[NTP error metrics](https://www.rfc-editor.org/rfc/rfc5905.html), and
[Apple scheduled audio buffers](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).

## Listening after the initial clock burst — 2026-11-18, 22:49–22:54 Helsinki

The owner rebuilt and confirmed immediate playback, then reported odd sound,
possible gradual degradation and improvement after restarting the speaker.
Later reports explicitly said deterioration had stopped and sound remained OK.
The Inspector confirmed five initial samples completed, the same iPhone runtime,
and no further clock filter resets. In one 43-second comparison the Mac had no
new capture drops; iPhone failures rose by 93 late inputs, 20 missed handoffs,
30 native late blocks and 27 overlaps. Overlaps recurred about every 1.5 seconds,
including while the master reported no remaining correction. Response time
was manual 150 ms. This is ongoing packet loss, not proof of worsening quality.

The native output was reopened between observations: its counters restarted
and host-clock calibration RTT improved from 26.163 ms to 2.451 ms while the
Session clock reset count stayed at one. Recalibration is a possible contributor
to recovery, not an established explanation. A subsequent one-second recording
showed advancing output and bounded queues, with no captured progressive buildup
to silence; the owner's report of the earlier decline remains unresolved.
No audio settings or runtime code were changed during this inspection. The
recorder and exact audio-disabled Inspector were stopped afterward.

## Rapid initial clock calibration on idle join — 2026-11-18

Clock acquisition already started on membership; subsequent measurements now
use a bounded initial burst instead of five-second spacing. The existing
supervised clock worker requests up to five samples at 250 ms spacing, keeping
one request in flight, and completes two seconds after the first valid reply
if fewer arrive. The lowest-RTT observation directly sets the initial mapping
before audio scheduling is allowed and seeds the ordinary median filter.
Raw time remains visible from the first authenticated reply. `presentation/1`,
`to_monotonic/1` and automatic subscription restoration wait for initial
calibration, not for the full 20-sample window. Later corrections retain the
existing slew; already assigned targets are not rewritten. Diagnostics expose
initial completion, sample count and selected RTT. No wire protocol change.

Validation: core compiled; 35 focused clock/filter/mapping/subscription/diagnostic
checks pass. Tests cover raw-time visibility with audio fenced, direct removal
of a provisional 100 ms error without a long slew, and completion on the sample
count or timeout. The signed two-Device idle-join check with production tracking
cadence observed raw time at 0.17 s and five-sample completion at 1.37 s, with
zero pending correction and audio scheduling then enabled while the median
window remained warming. These are local software checks,
not a measured acoustic alignment guarantee. Mac/iPhone apps were not rebuilt
or deployed. ON AIR return recovery, receiver stalls, master placement and
same-source overlap rendering remain separate unfinished work.

## Clock audit and recovery report — 2026-11-18

The owner reports that restarting the iPhone now restores playback quickly
without pressing buttons, but Mac ON AIR off/on did not resume until the iPhone
speaker was muted/unmuted. This distinguishes successful saved-intent restoration
in that restart from a still-failing source-return path; its cause was not
captured. Receiver code intends automatic subscription restoration and retries
inactive output every 250 ms, so manual toggling should not be required.

Source audit confirms that `synchronized` gates mapping authorization and
freshness, not measured clock accuracy, remaining slew or uncertainty. An initial
100 ms mapping error needs 200 seconds to remove at the configured 500 ppm,
after a correction check (every 30 s). This is a concrete possible long-settling
mechanism, not a proven explanation of the reported startup wait. Master choice
still follows the original reference or sorted online ON AIR privilege holders,
using each Device's local presence view. Active broadcaster placement and a
shared master announcement remain unfinished. See BUFFEE_TIME.md for the audit.
No runtime changes, app builds or new tests were performed for this analysis.

## Rebuilt Mac → iPhone listening recheck — 2026-11-18, 22:12–22:16 Helsinki

The owner reported roughly three minutes between enabling the speaker and
hearing music, followed by fragmented playback, possibly worse while typing on
the broadcasting Mac. Read-only CLI snapshots did not capture usable remote
diagnostics before sound began, so the cause and precise duration of startup
remain unproven. The first usable sample already had a full, ready clock,
41,980 cumulative native late-block failures and fresh native playback. Those
cumulative failures cannot be assigned to the startup interval from this sample.

The same Mac/iPhone instances remained running. From 22:14:49 to 22:15:49, the
Mac's capture drop count stayed at 34 while 5,554 more capture blocks were
published. The iPhone counted 1,016 additional late input packets, 51 missed
handoff targets, 64 native late blocks and 33 overlapping packets. Its maximum
Mixer wakeup gap increased from 2,000 to 2,663 ms, and long wakeup gaps increased
from 22 to 34. The clock stayed ready at 20/20 samples without another reset;
engine/player and speaker route remained active. Response time was **manual
150 ms**, not the previously successful 800 ms. This establishes deadline and
overlap failures during the listening report, not their complete root cause
or a correlation with individual keystrokes.

Source inspection confirms eight native Mac capture slots (about 85 ms for
the observed 512-frame/48-kHz callbacks). The shared capture drop count combines
try-lock contention, a full ring and invalid/oversize buffers; it does not
identify which occurred. From 22:12:45 to 22:14:49 it rose by five, so capture
loss also exists, but increasing that queue alone cannot explain or resolve
the later breakup with no new capture drops. No playback settings or runtime
code were changed. No build or tests were needed for this inspection.

## Raw clock availability and reproduced clock-slew drops — 2026-11-18

The master now seeds its host clock immediately, including cold provider
handover; configured SNTP can refine it through the existing slew. External
reference failure remains visible but no longer removes a usable host mapping.
A follower creates a mapping from its first authenticated four-timestamp sample.
Filter fullness is separate: `estimate_quality: provisional` identifies a warming
window, and `raw_offset_ns` exposes the raw measurement as a canonical decimal
string. Partial medians refine the existing mapping without stepping it.
Membership, sample freshness, authorization and post-resume fresh-sample barriers
still apply. Received packet targets are neither reconstructed nor rewritten.
Legacy `filtered_utc_time` names the mapped estimate even while provisional.

Validation: 33 focused clock/filter/subscription/restore/diagnostic checks pass.
A two-Device signed-control check with production 5-second sampling and a
20-sample filter obtained usable raw time after 0.28 seconds while still warming.
This is local software evidence; no app rebuild/deployment was performed.
Provider selection still prefers the original reference. Authoritative placement
on a broadcasting Device and periodic push remain unfinished.

A deterministic exercise of the real clock mapping and PCM mixer found another
concrete cause: 100 contiguous 512-frame/48-kHz blocks had zero drops under a
steady mapping, but 25 `overlapping_packet` drops during a -500 ppm source-clock
slew. PCM bytes and transport were unchanged. Mapped start intervals shorten
while block durations remain nominal; tiny overlaps discard entire blocks.
This proves a mechanism, not its fraction of the live phone's failures. Core
Audio callback timestamp jitter and native clock-map uncertainty remain suspects.

The owner's proposed timestamped audio regions fit overlap-add, crossfading and
continuous resampling. Proposed direction: continuous per-source rendering state
feeding steady hardware-rate output, independent sounds summed, deliberate
splices crossfaded. Fading every packet would modulate continuous audio; summing
duplicate parts of one source can boost amplitude or cause interference. Start
targets remain explicit; rate-correction duration must also be defined. This
rendering change is not implemented.

Primary references: [GStreamer audiomixer](https://gstreamer.freedesktop.org/documentation/audiomixer/audiomixer.html)
supports synchronized live mixing; [libsamplerate streaming API](https://github.com/libsndfile/libsamplerate/blob/master/docs/api_full.md)
smooths ratio changes while retaining state; [WebRTC NetEq](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md)
provides time stretching and recovery merging, but its adaptive playout must
not silently replace assigned targets. No backend was selected or substituted.

## Monitored iPhone cold start — 2026-11-18, 21:41–21:44 Helsinki

At the user's request, recorded one-second signed CLI observations through one
audio-disabled Inspector while the Mac kept broadcasting and the iPhone app
was restarted. No playback settings or runtime code were changed during the
experiment. The recorder and exact Inspector were stopped at the end; user
Devices remained running.

The new iPhone runtime first appeared at 21:41:31 with 1/20 clock samples.
At 21:41:36 its speaker reported `output_or_clock_unavailable`, still acquiring
the clock. Repeated speaker toggles produced disabled → ready → error states
while samples accumulated; the clock was never reset again (reset count stayed
2). At 21:43:07 the 20th sample made the clock ready and speaker running;
completed native output was observed at 21:43:08. The startup wait was about
95–100 seconds, rather than a failure to maintain the native output engine.

By the final 21:44:08 sample, the same runtime had completed 2,827,264 frames,
with fresh 7-ms completion age, speaker volume 650/1000, an open transport,
no suspension and no pending output stop. The owner confirmed audible playback.
Automatic Response time rose from 532 to 630 ms. There were 133 discarded blocks:
92 late arrivals, 39 overlaps, one native late block and one handoff miss.
This confirms about a minute of software playback progress after acquisition;
it does not qualify acoustic synchronization or all recovery paths.

Confirmed UI/control mismatch: `speakerStatus` presents a row error as muted,
but the click handler toggles saved `live.muted`, which can still be false.
The first click therefore mutes an already muted-looking icon; the second
unmutes it. The UI also depicts an unmuted desired state as active before
output is actually ready. Pending correction: preserve the saved speaker
choice across startup, represent clock acquisition as waiting, and settle
genuine start failure/timeout to a retryable muted state with one-click retry.
The experiment identified this behavior; that correction is not implemented yet.

## iPhone speaker recheck: system volume zero — 2026-11-18

The public CLI joined the remembered Session as an independent audio-disabled
Inspector. Two fresh samples of the same iPhone runtime, 15.6 seconds apart,
showed Playback consent and speaker `running`, engine/player running, fresh
non-silent submitted-output levels, and completed frames increasing from
151,808 to 885,504. The native route was `speaker`, suspension was false and
stop was not pending. Both samples reported system output volume **0/1000**.
The user was asked to raise iPhone media volume while OpenSound is foregrounded;
audibility after that action remains unconfirmed. No audio settings, consent or
runtime code were changed during this recheck.

Automatic was active and shared Response time rose from 155 to 175 ms between
samples. Some late/overlap drops continued; software counters do not establish
acoustic playback or qualify the automatic curve. The exact Inspector created
for this check was stopped afterward; user Devices were left running.

## Audible iPhone playback; Automatic Response time — 2026-11-18

The owner confirmed that Mac→iPhone audio plays at 800 ms Response time, after
shorter settings caused intermittent playback. Fresh CLI observations showed
the updated iPhone's native engine/player running on the speaker route, volume
600/1000 and advancing native scheduled/completed frames. Prior missed-target
and native-late drops were present. This is user-confirmed audible playback;
sustained quality and acoustic synchronization remain unqualified. The exact
Inspector created for the recheck was stopped; user Devices were not changed.

Implemented the owner's follow-up: the shared Mixer summarizes missed output
times over five seconds. Two or more discarded blocks trigger a signed chat
warning, at most once per 30 seconds per Device. Measured lateness is averaged
and added to the observed Response time to estimate the full requirement.
Incoming late packets, Erlang handoff misses and iOS native late rejections are
covered. Unknown lateness is reported without a guessed recommendation. iOS
handshake v3 adds the native overshoot in nanoseconds; v1/v2 replies remain
accepted. Other native backends retain their existing diagnostic limitations.

The existing Automatic radio choice is enabled. Settings editors (`grant` or
`on_air`) opt the Session in; an ordinary Device with `time_read` can then submit
an authenticated absolute minimum, not change the mode or choose the policy.
The existing clock authority alone commits and broadcasts a revisioned shared
Response time. Manual values turn Automatic off. It raises future source targets
only; it neither retimes assigned packets nor decreases the delay.

For current delay C and measured deficit D (ms), the increase is floored from
`D * 300 / (max(300,C)+D) * (min(2700,3000-C)/2700)^2`.
This limits single large spikes and increasingly resists growth around 300,
600 and 1000 ms. A 100 ms deficit adds 75, 33, 14 and 1 ms at C=300, 600, 1000
and 2000 respectively; it adds zero near 3 s. Automatic never raises beyond
2999 ms; existing larger manual settings are not silently lowered. The chat
warning still shows the full measured requirement, including when weighting
prevents an increase. This curve is an initial policy, not a listening-qualified
estimator or proof that additional delay will cure every playback failure.

Validation: 58 focused Erlang checks and 26 frontend state checks pass; shared
frontend syntax and iOS Swift type-checking pass. Prepared iPhone runtime
refresh passes with 111 core modules, 809 imports and no unresolved calls.
A two-Device local integration
check confirms an ordinary reader's signed request raises the shared Automatic
value from 150 to 330 ms, cannot enable the mode, and cannot override manual
800 ms. It uses disposable Devices and no audio hardware. No new build was
deployed and Automatic was not enabled in the user's live Session. Rebuild all
participating apps (and restart Web) before testing the new policy messages;
manual-mode wire payloads keep their previous shape.

## iPhone output recovery and CLI Session memory — 2026-11-18

An independent audio-disabled Inspector joined the user's live Session through
the public CLI. Mac system capture was running with non-silent capture levels.
The iPhone had Playback consent, a synchronized clock and an open media
transport, but reported `native_stop_unconfirmed`, `output_stop_pending: true`
and a previous `output_closed` failure. Its submitted-output meter was about
15 minutes old: historical rendered frames did not mean ongoing playback.
The original output closure's OS cause remains unknown. Historical native-late,
late-packet and overlap drops remain separate timing problems.

iOS output now advertises local handshake version 2. If its original socket
cannot acknowledge stop, Erlang closes that socket and requests an explicit
stop acknowledgement on a fresh connection to the same native listener. The
listener serves connections serially and acknowledges only after the previous
engine/session cleanup has returned. Missing acknowledgements and older
bindings remain fenced; EOF is still not accepted as stop confirmation. Normal
stop also releases the audio session before acknowledging. Targets, Playback
consent and buffer policy are unchanged.

The CLI monitor now privately remembers its last selected Session under
`BA_CLI_HOME` (the normal Device-state directory by default). Both an explicit
invitation and monitoring a named Device remember the selection. A later
`beamaudio monitor --all` rejoins it, including after its observer was stopped.
`--invitation-file` selects another Session. `--no-user-state` skips remembered
monitor selection and automatic observer discovery, requires an explicit
invitation file or Device name, and does not overwrite the saved selection.
It does not erase or reset a named Device's identity, consent or configuration;
use a separate `BA_CLI_HOME` for fully isolated Devices.

Validation: seven iOS TCP/output regression checks pass, including fresh-ACK
recovery, missing-ACK refusal and old-binding EOF refusal. The two Swift
output/session sources type-check against iPhoneOS 27.1 for arm64/iOS 17.
Native iPhone runtime preparation passes with zero unresolved core imports. Six
focused CLI checks and the public CLI Session-memory integration check pass,
including restart/rejoin, opt-out, retained identity, Forget and explicit Join.
The live Inspector was stopped by its exact name; user Devices were not
stopped or reconfigured. The user's current Session was remembered for CLI
monitoring. Full app rebuild/deployment and physical playback remain user checks.

## Apple runtime packaging dependency fix — 2026-11-18

Reproduced the iPhone build failure in `check-runtime-calls.escript`: the new
core `ba_windows_device:boot/0` imported `ba_device_web_cli:main/0`, but native
Apple runtimes do not bundle DeviceWeb. Moved Windows Web startup to
`ba_device_web_cli:windows_main/0` and updated its PowerShell launcher. The
shared Windows binding keeps `configure/1`, used by both native and Web hosts;
the core no longer depends on the optional Web service. Import checks remain
unchanged.

Validation: core and DeviceWeb compile; full native iPhone runtime preparation
passes with 110 core modules, 800 unique imports and zero unresolved calls.
The initial sandboxed preparation could not read macOS public trust anchors;
the rerun with host certificate access passed. Full Mac/iPhone app builds,
Windows launcher execution and physical playback were not performed.

## Windows Web audio, moderation and Settings — 2026-11-18

Windows native and source Web launches now share `ba_windows_device` binding
setup. The browser launcher selects Windows audio automation, reuses the built
WASAPI capture/output helpers and loads the prepared Windows transport/Elixir
libraries. It keeps its own existing DPAPI identity and Web label; native
Credential Manager identity/leases are unchanged. Build Windows once before
starting Web, or supply BA_WINDOWS_AUDIO_HELPER_DIR. No separate browser audio
implementation was introduced.

Settings now uses **Can moderate**, a switch matching Admin and On air. The
existing `end_session` wire privilege permits individual kicks and Session End;
it does not grant privilege-management rights. A live kick uses the existing
signed, paired End message addressed only to its target, so even an Admin can
be kicked and moderation continues without an Admin online. Present grant
holders can additionally record removal in signed membership policy, including
for an offline target. Persistently recording an offline removal still needs a
grant holder; moderation itself never receives policy-signing authority.

The Settings audio-diagnostics fieldset and its renderer are removed. The
moderator-request policy is last on the page. Existing CLI diagnostics and
calibration consent are retained.

Validation: Windows package build with --test passed (6 DeviceWeb + 32 frontend
checks), 12 focused core checks passed, and 7 isolated headless Chromium
scenarios passed. The real Web launcher smoke test captured WASAPI frames in a
private local Session, reported speaker ready and stopped its own process tree;
it used no microphone or public Session. A four-Device local integration check
confirmed ordinary Devices cannot kick, a moderator cannot grant privileges,
can kick another Device and the Admin, and can continue kicking afterward.
The same regression subsequently passed through the public CLI with a private
CLI home and four audio-disabled Devices; all test Devices were stopped by
their exact names before the temporary home was removed.
Speaker-ready and capture counters do not qualify acoustic playback. Rebuild
and restart apps to load these source changes; Mac/iPhone qualification remains
pending on the Mac machine.

## Ask consent procedure and inspection by calibration — 2026-11-18

- "Ask" now asks: `ba_device_config:request/2` records one pending request per
  requester for a protected use (Device ID or `local`), shown in the Requests
  panel; `answer_consent` Allow turns the use on, Decline is remembered until the
  policy changes; No refuses. Covers Recording (mic button), Playback (speaker
  button) and calibration.
- Audio meters/analysis switches removed: inspection follows Calibrate speaker /
  Calibrate microphone. A remote `monitor --metrics` read raises a calibration
  request on Ask. e2e: inspector asked, each Device approved, validated, then
  each Device turned calibration off locally.
- Windows home page shows `Version 0.<OpenSound commit count>` like macOS/iOS.

## Windows capture — 2026-11-18

- `ba_windows_input` + WASAPI helper `audio_capture.cpp`: microphone (48 kHz
  mono) and ON AIR system audio via process loopback excluding this VM's tree.
  QPC capture time per packet from the helper's own frame count (raw WASAPI
  stamps jitter ~1 frame and caused overlapping-packet drops; device position is
  unusable for process loopback). Clock mapping +/-51-102 us.
- e2e (`--windows-capture`): 4 s steady, exactly 192,000 frames published and
  played contiguously on a second Device, 0 late, 0 dropped, confirmed stop;
  microphone 3/3, system audio 4/5 (the failure was a 66 ms receiver mixer stall
  at the 50 ms lead). Capture is unavailable (greyed) only without the helper.

## Windows playback, CLI and test portability — 2026-11-18

- Windows speaker playback through the shared pipeline: `ba_windows_output` and
  WASAPI helper `audio_output.cpp` (same port protocol as macOS plus stats).
  `device-session-e2e.py --windows-output HELPER` passed: 240,000 frames played
  at their targets, 0 late, 28.5 ms output lead. Not yet listened to.
- `beamaudio` runs on Windows (`bineamaudio.cmd`); loopback endpoint guarded by
  the instance secret. `cli-smoke.py` and `cli-api-smoke.py` pass on Windows.
- Formerly Unix-only unit tests pass on Windows; `ba_native_stop` now kills a
  stuck helper with `taskkill` there. Receiver no longer crashes when
  membership is unavailable.
- Mixer lead scales with Response time (50–500 ms); the 30 s scenario passed
  3/3 after dropping blocks under ~200 ms OS stalls. New diagnostics:
  `mixer.max_wakeup_gap_ms`, `mixer.long_wakeup_gaps`, connection-setup stages.
- `buffee-time-smoke.py` line 85 (clock recovery after control restart) failed
  once in three runs on this loaded host; intermittent, not yet explained.

## Live iPhone inspection — 2026-11-18

User confirmed iOS 26.6.1 and OpenSound foregrounded. Defer ON AIR system-audio
capture on that release; do not add a duplicate capture implementation. Speaker
playback remains a separate supported path.

Joined the supplied live Session using an independent audio-disabled Windows
Inspector. The managed CLI correctly reported macOS-only launch support; an
isolated launcher used the existing public Device API monitor implementation
instead. Both observer runs left the Session and stopped; no user Device was
stopped or reconfigured, and no capture/playback was enabled.

Twenty follow-up samples read the native Mac, Windows Web and Mac Web Devices.
One member, ID prefix `0C15DC65`, stayed disconnected/connecting and provided no
capabilities. Its identity as the iPhone still needs user confirmation; saved
membership is not live connectivity. The native Mac captured two Sources but
reported zero open media transports; system-output samples were silent (-96
dBFS). Historical setup_timeout/invalid_control_or_attempt failures were present
but did not increase during observation. These samples do not establish the
iPhone's native output state. Verify its Session and self Device ID next, then
inspect routing/presence or native counters as indicated by that result.

## Windows mixer and iPhone ON AIR investigation — 2026-11-18

Ran the complete original 54-scenario inventory: 11 passed, 19 failed,
24 unavailable. Fixed Windows bundled-tool discovery, Mix/rebar invocation,
inventory path normalization and Windows audio transport lookup. Added the
headless Chromium regression to the inventory (now 55 scenarios). Reception
ExUnit subsequently passed four checks; runner checks pass.

Reproduced a real audio drain-rate failure: 250 packets received but only
2,816 output frames submitted. The mixer now drains bounded batches of up to
16 blocks within a 50-ms submission window. Absolute presentation targets,
Session Response time, consent and per-block authorization checks remain.
The monitored five-second/150-ms case passed twice after the final change:
250 packets, 240,000 frames, no drops/gaps/late output. The 125-second two-source
renewal case passed 6,250 packets/source and 6,000,000 mixed frames, with no
drops/gaps/late output and verified final revocation. Nineteen focused Erlang
checks, 29 Node checks and six real headless Chromium scenarios passed.

ON AIR previously disabled itself with a Mac-specific hover hint when iOS
reported capture unavailable. A tap now opens the native availability reason;
permission/cancellation/start errors also open a visible dialog. The current
system capture implementation requires iOS 27; this is independent of playback.

The complete suite remains failing/incomplete. Final audio rerun: 3 passed,
5 failed, 1 unavailable. Maximum-delay playback still had 12 dropped blocks
and a gap; receiver-restart timing, offset/privilege expectations and the
authorization-expiry fault test also failed. Several general tests are Unix-
specific or refer to retired Windows wx behavior; others need investigation.
See [full report](WINDOWS-AUDIO-2026-11-18.md) and its saved JSON report paths.
No physical iPhone was observed, rebuilt or deployed from Windows. Its exact
playback failure remains unconfirmed; sync both checkouts and rebuild on Mac,
then inspect the live native output/clock/consent counters and OS version.

## iOS diagnostics compilation repair — 2026-11-18

Corrected the new output diagnostics call from nonexistent `AVAudioSession.shared`
to Apple's `AVAudioSession.sharedInstance()`. Both IOSAudioOutput.swift and
IOSAudioSession.swift now pass Swift type-checking against the installed iPhoneOS
27.1 SDK, targeting arm64/iOS 17 with the real ba_beam.h bridge header. Earlier
syntax-only parsing could not detect this API mistake. Full Xcode app build and
physical playback remain user checks; no deployment was performed.

## Switchable diagnostics and monitored end-to-end test — 2026-11-18

Implemented Device-wide persistent meter/analysis settings through public
`audio_diagnostics` API, local shared Settings UI and authenticated remote
monitor configuration. A supervised observer caches observations independently
of automation. Received and submitted-output meters are distinct. Optional iOS
native summaries report scheduling/completion/queue/rejections, engine/player,
route/volume, rate/channels/latency, accepted-target lead bounds and mapping RTT.
Erlang owns meters/policy; native callbacks update bounded counters only.
Analysis includes 16 coded recent failures. OFF preserves audio consent and
mandatory counters; no PCM or credentials are sent through diagnostics.

The single-source E2E attaches an independent audio-disabled Inspector and uses
normal signed monitoring replies to validate packet/frame totals, both meter
stages, clocks/Response time and local/remote switches. During implementation,
it caught an array-rejection mismatch in the signed protocol and a non-JSON
internal trace representation; both are fixed and covered by regressions.
The test harness now drains child stderr with a bounded in-memory tail rather
than risking pipe backpressure, and reports runtime exit on request timeout.

Final validation: 65 focused Erlang tests pass (diagnostic projection/limits,
protocol authentication/replay/round-trip, iOS TCP binding and supervision/jobs).
Two new frontend checks and the public generic CLI API integration check pass.
Core compiles; Swift syntax and frontend JS syntax checks pass. The final full
five-second E2E passes: 250/250 packets, 240,000 output frames, no gap/drop/late
output, both clocks synchronized, Response time 150 ms, renewal continuity and
buffer revocation. Test output is explicitly tagged `test_sink`; its accepted
frames are not native/physical playback evidence. Earlier intermittent Mixer
handoff misses are not declared repaired by this pass.

Not done: full test inventory, Windows execution/build, iOS compilation/deployment,
visual acceptance or live iPhone listening. The original iPhone silence still
needs a live run with the new measurements. No user app/Reception restart or
live Session changes were made. Changes are local and uncommitted in both repos.
See the Windows handoff at the top of PLAN.md. Inspection privacy remains a
recorded requirement, separate from the implemented diagnostic switches.


## Run Tests.command includes the automated inventory — 2026-11-18

Replaced the four-suite shell list with a shared core Python catalog/runner;
the product launcher forwards arguments and its existing exit status/Return
prompt. Discovery includes EUnit projects (including DeviceWeb and legacy
Reception), ExUnit, both Swift packages, frontend Node tests, standalone Python
checks/experiments and test escripts. Existing Device/Session audio scenarios and
production clock cadence are explicitly enumerated. Inventory is 54 entries.

Execution is sequential, continues after failures, reports every selected case,
and writes a JSON summary under ignored core builds/test-results. Missing builds,
dependencies and wrong-platform cases are UNAVAILABLE with a reason. Exit codes
are 0 for a fully passing selection, 1 for any failure, 2 for otherwise incomplete;
partial selections never claim all tests passed. There are no invented iPhone
hardware tests, and Windows tests cannot run on this Mac.

Validation: the actual Run Tests.command --list path inventories 54/54 without
execution. Two runner tests pass, checking coverage and a real subprocess chain
that fails, encounters an unavailable prerequisite, and still executes a later
passing test, including summary exit codes. A real launcher-selected five-second
end-to-end run passed 250/250 packets, all clock/150-ms checks, 240,000 frames,
and revocation. This single pass does not erase earlier intermittent deadline
failures. Full cross-platform/54-scenario execution was not performed; the
launcher is ready for the user's full run. Shell/Python syntax and diff checks
pass. The core default profile compiles before EUnit/integration so standalone
scripts use current modules; project caches remain under core builds/.

## Device/Session end-to-end test name — 2026-11-18

The canonical runner is `tests/control/device-session-e2e.py`, reflecting
Session joining, privileges, master/follower clocks, shared response time and
audio delivery/output. Repository references are updated. This rename changes
no test behavior or known failures; Python syntax and references were checked.


## Backend end-to-end clock and Session policy assertions — 2026-11-18

Renamed the test `device-session-e2e.py` and updated references. The two-Device
scenario now supports `--ephemeral`: contact/group invitations, not a different
Session runtime. Renewal mode returns before the later full lifecycle scenario.

Checks before transmission, every second during, and after drain now assert:
sender hosts a ready master with an upstream anchor; receiver is fully filtered
and fresh; both share the same master instance/timeline; their mapped UTC is
within a bracketed 5 ms tolerance of the fixture host's system UTC. This does
not prove zero error or externally verified UTC. The reference needs no follower
filtering. Added matching ready Response time assertions on both Devices;
the canonical test and two-Device default use 150 ms.

The first stricter ephemeral run passed clock and all 250-packet delivery checks
but lost 512 rendered frames at 150 ms (two missed targets); the 1,000 ms
comparison lost 256 frames (one missed target). Rendered values were correct,
with one output gap in each run. Earlier passing runs do not prove reliability;
no lossless assertion was weakened. The final explicit-150-ms run also passed
all clock/policy and 250-packet assertions, then failed with two missed targets
and 239,488/240,000 rendered frames. Native capture/speakers remain outside
this test.

## Exact five-second two-Device audio baseline — 2026-11-18

The old audio regression was not currently passing: its explicit peer connect
collided with automatic admission, response-time writes relied on obsolete
`offset_write` authorization, and receiver consent was not enabled. Its synthetic
capture input also defaulted to `legacy_capture`, which the secure profile denies.
Updated the fixture to use automatic control connection, the authorized sender
for Response time edits, explicit Device API speaker/ON AIR consent and the
appropriate broadcast/microphone input permission. No production gates changed.

Added `--single-source` to the existing renewal scenario: exactly two independent
Devices create/join via local Reception, one sends known synthetic PCM for five
seconds over real WebRTC, and the other uses the production Mixer with a test
output binding. Added exact per-transport sent/received packet deltas and
rejection checks alongside existing frame/value/target/queue assertions.

Both 1,000 ms and normal 150 ms runs passed: 250 packets sent and received,
240,000 frames, no rejected packets, gaps, Mixer drops or late sink writes.
Transport/publication identities remained stable through shortened lease renewal;
the final receiver revocation prevented a separately queued future buffer playing.
All temporary runtimes/Reception were cleaned up. Clock warmup uses three samples
at 250 ms and leases are four seconds; production defaults are unchanged.
No native audio hardware, iPhone, live Session or public-CLI-only playback test.
The longer three-Device/Opus/lifecycle scenarios were not fully rerun.

## Latest handoff after user Run Both — 2026-11-17

The network-hint repair is now running on the user's devices. iPhone instance
781EB6CB reported two open Media Sessions and live received levels at 21:14:27
Helsinki while reacquiring after `sample_gap` (7/20, reset count 3). At 21:16:19,
the same instance was synchronized at 20/20, with two active/mix-ready streams,
21 queued blocks and 8,275 rendered blocks. Reset count remained 3, with no
pending native stop. The user reports the volume buttons now control media
volume. This is positive output-lifecycle evidence, not listening/quality
acceptance. Native late-buffer failures were 2,252; Mixer also reported 149 late
packets, 52 missed targets and 56 overlaps. The remaining timing issue is open.

The monitor's master-clock N/A was traced through the public CLI to the old
managed Web Device 1D354C22, whose local clock snapshot has neither
`master_clock` nor reset-diagnostic fields. Native Run Both does not restart
that independent VM. The native Mac source is BD29A553 and the iPhone 781EB6CB;
neither needs to be stopped to update the Web monitor. Next manual step: stop
only the named Web Device (`scripts/cli/beamaudio stop device --devicename OpenSound`),
then reopen Start Web UI.command so it reloads current core code with the same
saved identity. This restart was not performed by the agent. Then verify the
master UTC/age display and capture native target-lead logs without attaching a
debugger. No separate Inspector joined this investigation.

Current source validation remains 32 passing focused tests. Clock Manager,
ON AIR master placement/retention and approximately 30-second pushed updates
are recorded requirements for the next increment, not implemented features.

## Network hints interrupted playback; monitor shows master UTC — 2026-11-17

The user rebuilt/ran the diagnostic code. At 20:58:49 Helsinki, iPhone instance
17ECB4C5 reported reset reason `network_changed`, count 4 and 8/20 samples.
Following another user-heard burst, at 21:02:08 it had 232 rendered blocks,
four native late-buffer drops, reset count 8, filter 2/20, holdover and no Mixer
streams or open Media Sessions. It was not suspended and had no pending native
stop. This confirms the network hint handler caused reacquisition; NWPath
equality alone did not prevent it. Mac capture continued throughout.

Network hints now bring forward the existing discovery poll without clearing
the filter, closing media or moving the resume fence. The control owner repairs
missing connections; authenticated leases and normal sample freshness still
stop invalid/stale work. Explicit resume retains its fresh-sample requirement.
A regression covers repeated hints during acquisition and active playback,
unchanged media state and the subsequent discovery refresh.

The CLI/embedded monitor prints the master's UTC value, Device and sample age
without requiring `--metrics`; stale readings are labelled. A local master
reports current mapped UTC. A follower exposes the last authenticated master's
`t3` reading before its own filter fills, without presenting a local estimate as
the master's report. A changed provider cannot inherit an old provider's sample.
JSON stores full UTC nanoseconds as a decimal string under `clock.master_clock`.
No new time packet, polling path or dependency was added.

Validation: 32 focused monitor, clock, network-event, diagnostic, native-output
and subscription tests pass. Added checks cover UTC rendering, age/staleness,
missing samples, local-master values and pre-acquisition follower readings.
No agent-run native build or deployment. The user subsequently ran Both; the
latest handoff above records the result and the old Web monitor backend.

Recorded the user's clock design: a Manager maintains one master on an ON AIR
Device, retaining it while that broadcaster continues; several ON AIR Devices
are allowed. Reuse existing synchronization and OTP lifecycle/delivery, with
about 30-second distribution. Manager/placement/push changes are not implemented
here; existing `on_air` settings-edit permission is confirmed.

## iPhone bursts followed by clock reacquisition — 2026-11-17

The user ran the prior output repair, but reported silence and volume buttons
controlling the ringer. CLI inspection through the existing Web Device showed
zero Mixer output while the iPhone clock was acquiring; `speaker: ready` means
the capability is available, not proof of an active native audio session.
At 20:46:42 Helsinki, following a user-heard burst, instance 5DDA4DA3 had rendered
182 blocks, counted eight native late-buffer rejections, and returned to clock
holdover with filter 1/20 and an empty Mixer. There was no output socket failure
or pending stop. After relaunch, instance 743B3362 repeated the pattern: at
20:53:28 it had rendered 141 blocks, one native late rejection, and again had
filter 1/20, holdover and no Mixer streams. Mac capture remained active.

Read-only debugger attachment was attempted to inspect the native route, but
the expression ran before asynchronous attachment completed and LLDB exited.
The user reported the app stopping at that time. Process inspection confirmed
exit; no OpenSound crash report was present. The debugger is the likely cause,
not a confirmed application crash. The existing app was relaunched through
devicectl without rebuilding or changing identity/settings. No further attach
attempt was made. Saved identity was confirmed through the CLI after relaunch.

Added bounded clock reset reason/count metrics and tags for explicit resync,
resume, network changes, reference changes, sample gaps, and missing time
permission. An empty filter preserves the reason that cleared it when the next
sample arrives. Added receiver suspension/active/mix-ready counts. Fixed
`transport.sessions` to count actual worker status rows instead of all saved
subscriptions, and added `transport.open`. None proves physical speaker output.
Source review found iOS unconditionally resynced after every subsequent usable
NWPath notification; it now compares NWPath values and ignores unchanged paths.
Whether duplicate notifications caused the live resets remains unproven.

Validation: 18 focused clock, diagnostic, iOS-binding and restore EUnit tests
pass; iOS runtime Swift parsing and diff whitespace checks pass. NWPath's
Equatable conformance was verified in the installed iPhone SDK. No new full
native build or deployment. The user has been asked to rebuild/Run the iPhone
so CLI inspection can identify the actual reset trigger. Sustained playback
and native route/session state remain unverified.

## iPhone native rejection and dead output handle — 2026-11-17

Inspected through the existing managed Web Device's public `call device` /
`monitor` API; no new participant or audio-setting changes. Mac capture stayed
active with fresh nonzero levels and Web playback disabled. iPhone instance
E46AC51F stayed at 92 rendered blocks between 20:25:09 and 20:30:14 Helsinki,
while output-write failures rose from 2 to 13. At up to 256 frames per block and
48 kHz, 92 blocks represent about 0.49 seconds, consistent with the user's burst,
not a physical playback measurement. After the user's restart, instance BFA6B12B
rendered 23 blocks, then reported a closure and two write failures by 20:34:01.

Xcode's existing native console reported a late/out-of-bounds presentation target
(the old error combines both cases). Source review confirms rejection threw out
of the output loop and closed TCP. `close_confirmed` retained the handle without
a stop ACK, while `open_permitted` treated it as usable, repeatedly writing to
the dead socket. The Mixer hands off within 20 ms of the native target; local
TCP batching is a plausible contributor, not a measured cause of the rejection.
Clock filters also reset into acquiring/holdover; their trigger remains unknown.
`transport.sessions` counts subscription rows even without an open worker, so
was not taken as proof of flowing media.

iOS now reports late targets, out-of-bounds targets and queue exhaustion as
individual buffer rejections. Erlang counts `native_late_packet`,
`native_target_out_of_bounds` or `native_output_queue_full`, rearms active-once
TCP, and continues later targets on the same output. No target is changed. The
native log includes target lead in milliseconds; both output TCP endpoints use
NODELAY. A real closure with unconfirmed stop now blocks stale-handle reuse and
exposes `mixer.output_stop_pending` in CLI metrics. EOF still is not a stop ACK.

Validation: 20 focused EUnit tests pass, including four new real Mixer/iOS Erlang
binding TCP tests and existing CLI isolation, native-stop, consent-revocation
and diagnostic tests. Checks cover repeated rejection events, subsequent PCM
on the same socket, exact converted targets/PCM, NODELAY, acknowledged stop and
blocked reuse after EOF. Swift typechecking against the physical-iOS SDK passes.
The sandbox initially blocked loopback/`ps`; checks passed with those enabled.
No full app build, installation, audio recording or listening test. The running
iPhone has the previous code; user-led Xcode Run/listening is next.

## Generic CLI pass-through for public Device commands — 2026-11-17

Added `beamaudio get methods` and `beamaudio call device --devicename NAME
--request JSON`. Omitting `--request` reads one UTF-8 JSON object through EOF,
so scripts can pipe or redirect a private request file. The method registry is
in `ba_device_api:methods/0`; app-facing methods reuse `client_methods/0`, with
owner-local configuration, diagnostics and host lifecycle commands added.
No per-operation CLI parameter parser is needed. Existing convenience commands
remain, as do the separate local process creation/stop/kill operations.

The adapter passes named fields, types, scope IDs and request/revision IDs
unchanged to the existing Device API over its instance-checked local socket.
Argument validation, consent and privileges stay in Erlang. Non-public method
names and supplied instance credentials are rejected; this does not expose
arbitrary module/function application or a new remote-control protocol.

Validation: core compilation, CLI help and `cli-api-smoke.py` pass. The smoke
uses only the public executable with one idle temporary Device: discovery with
no side effects, JSON/stdin/Unicode/types, real Session scope routing, rejected
invalid input and Device API errors reaching the caller. No Reception, audio
hardware, UI, live Device changes or native app rebuild. AGENTS.md introduces
the generic path alongside monitor/inspect.

## Live Session audio inspection; visible Inspector identity — 2026-11-17

Joined the user's supplied Session using a temporary audio-disabled CLI observer
and the existing signed diagnostic reads. During a 59-second web playback sample
at 150 ms Response time (20:06:32–20:07:31 Helsinki), received packets increased
by 5,530 with no new transport rejections; mixer drops increased by 40: 39
overlapping blocks and one missed target. Rendered blocks increased by 10,981;
clipped frames increased by 69,447. Source capture peaked around +2 dBFS.
These establish overlap rejection and clipping, not a count of missing network
packets: the current report does not expose packet sequence gaps. Queue readings
were about 8–10 blocks. Later the user muted the web Device; its local CLI
snapshot confirmed that, and its render counter stopped.

The iPhone's saved settings showed playback allowed and unmuted. It completed
the 20-sample clock acquisition, then lost readiness/reset its filter repeatedly.
It did attempt output: the last inspected instance had 18 rendered blocks,
eight output-write failures, one output closure and 72 clock-unavailable drops.
The final Response time was 300 ms, changed by the user during observation.
The generic output error does not identify the exact native failure. Native
source review shows resume/network changes resync the clock; no particular
observed reset trigger was proven. Older pre-restart error totals were kept
separate from this instance. iPhone ON AIR remains a separate issue.

Same-Mac native/web playback is not an independent physical-device test. Source
review found the capture exclusion matches a configured output-helper path;
native and CLI packaging use different paths, so recapture/feedback is a
possibility requiring isolation, not a confirmed explanation for these readings.

The user mistook the observer for a ghost app because the compact UI hid
`Buffee monitor` inside `Mac | Buffee monitor | ID`. Observer labels now start
with `Inspector Mac` (or Inspector + platform), preserving the purpose even in
existing compact views. Identity/storage names and privileges are unchanged.
The agent's observer was stopped; no automatic rejoin after the user's removal.
The copied iPhone settings and temporary invitation were deleted. No audio
content was recorded, no playback settings changed, and no app was deployed.

Core label tests and frontend name-projection tests pass; the public-CLI
regression checks an independent observer's visible Inspector label with audio
OFF. Root/core/product AGENTS.md now point agents to the public CLI at startup.
The audio faults are diagnosed observations, not fixed or playback-qualified.

## Session response time in UI and monitor — 2026-11-17

New Session clock policies and frontend preview/fallbacks now default to 150 ms.
Saved response times are retained. The former Automatic/custom-number control
is six native radio choices: Automatic, 50ms, 150ms, 300ms, 800ms and 2s.
Automatic is always disabled, with a visible "Not implemented" hint and native
tooltip. The existing `grant`/`on_air` editing boundary is unchanged. Older
custom values remain visible in the status text without silently rounding them.
Renamed the displayed Settings profile Tight to Strict, including introduction
text. Its existing behavior, saved `tight` key and blue colour are unchanged.

The monitor prints `Response time: ... ms` from its existing shared clock
snapshot, including "not ready" or N/A where appropriate, without `--metrics`.
JSON already carries the policy under `clock.offset_policy`.

Validation: 15 focused clock/monitor EUnit tests and 22 frontend state tests pass;
frontend JavaScript syntax is checked. The public-CLI smoke checks 150 ms in
both JSON and console output using disposable Devices and a local Reception.
No automated visual review, audio playback/listening, native bundle build or
live Session change. The suspected timing cause is not yet established.

## Public CLI regression coverage and Forget parity — 2026-11-17

Added `beamaudio forget session --devicename NAME --sessionid ID`, forwarding to
the same `forget_saved_session` Device API as the app. The backend was already
shared, but the public CLI had no command for it. Added `monitor --metrics` to
request the existing opt-in diagnostics in scripted JSON without an interactive
keypress; it enables no audio.

`cli-session-memory-smoke.py` uses only the public executable with two temporary
Devices and a local Reception. Checks: metric JSON while audio is OFF, stable
identity and Session return across restart, Forget staying absent on cold
restart, another Device retaining its Session, and explicit Join remembering it
again. Core compilation and this CLI regression pass. No UI, actual playback,
listening, native rebuild or live Device changes. Existing audio transport tests
use synthetic signals/test sinks; a public-CLI known-tone start/stop/level smoke
remains unwritten. Visual and listening acceptance stay user-led.

## Device identity and forgotten Session persistence — 2026-11-17

Found three running managed Web Devices alongside the native Mac app. The Mac
Web shortcut always used `--next-instance`, so relaunching while a previous
Device remained running created another independent key/state directory. It now
reuses the named Device's existing web endpoint; a fresh start uses that exact
name and fails on an occupied/stale record instead of selecting another key.
An attached launcher does not stop a Device it did not start. Separately,
DeviceWeb's bare `--local-device` used a fresh temporary identity/state directory
when the platform supplied neither; it now requires persistent settings.

Forget previously removed only the contacts entry. Membership observations
could recreate it, and a grant holder's saved return record could rejoin it
after restart. Forget now records an ID-only suppression marker and clears the
return link and cached accepted privilege policy in both the default and named
Session scopes, through the running owner where present. Other Sessions and the
Device key stay intact. Explicit use of a Session link remembers it again.
Leave retains its existing privilege-preserving behavior. Forget is local:
another Device can still supply its accepted signed policy on a later Join;
the creator's inherent privileges follow from its key and the invitation.

Validation: core and DeviceWeb compilation; 13 focused EUnit tests; isolated
launcher checks for reuse, first start and stale-record failure; bare local Web
startup rejects missing persistence before creating a Device. The extended local
restart smoke checks stable identities, forgotten Sessions staying absent,
explicit return and removal of saved delegated privileges. The parallel-Session
smoke also passes: Forget clears a closed named scope and its cached grant while
another Session still exchanges chat; offline rejoin keeps the Device ID and
has no cached grant. Its harness now loads the current `control` build, follows
the returned Session ID and flushes settings before orderly test restarts.
No visual/audio review, native app rebuild, public Reception change or running
Device cleanup.

## Test and documentation sweep after the join model — 2026-11-17

All 223 control unit tests and the six Session smokes (`buffee-membership`,
`session-peer-admission`, `session-privileges`, `session-restart`,
`buffee-reconnect`, `parallel-sessions`) pass; tests/control/README now runs the
whole eunit suite instead of an outdated module list.

Real defects fixed: (1) a policy signed by a `grant` holder giving up its own
grant was rejected everywhere; the signer now needs grant before its change and
keeps its certificate in that statement. (2) When two Devices started the
handshake at once, each could remember a different pair, so End was silently
refused; each side now keeps its recent pairs. (3) A Device that vanished
without `offline` stayed a participant forever; two successive successful
lookups without it now drop it. (4) "is here" was repeated after every
privilege change because control links reset; it now follows Session arrival.

Stale tests updated to current decided behaviour: contacts keep Sessions as
entries, not groups; consent is Device-wide (user rule 2026-11-16); retired
`role` replaced by privileges; Device labels start with the Device type;
`ba_settings` is a supervised child; the test probe flushes settings before
halting (the app's own shutdown already flushes). New unit test: equal-revision
policies converge. PLAN, NAMING and BUFFEE_JOBS no longer describe the passport
or v4 links as current. Still unverified: Windows, iOS, hosted Reception and
the OpenSound WebApp tests (local Node lacks libsimdjson).

## Pairwise Session admission; passport removed — 2026-11-17

Implemented the accepted admission model in `ba_buffee_passport`,
`ba_buffee_membership` and `ba_buffee`; Reception is unchanged. The creator signs
one permanent v5 link (Session ID derived from the creator's key and a nonce).
Every present Device advertises a secret-derived Session mailbox; each pair
proves the link with an HMAC handshake and exchanges the signed v2 policy. Join
needs no creator, `grant` holder or Manager, and grants nothing. Delegation
certificates let a newcomer trust a delegated `grant` holder while the creator
is away; equal revisions converge by statement hash. Each Device saves its
accepted policy per Session (`buffee_sessions`), so Leave and shutdown keep
privileges. The passport credential, inviter route, hub handshake and
`recover_authority`/`rejoin` records are gone. Decision: older v3/v4 links and
saved records stop working.

Validation: focused eunit (`ba_buffee_passport_tests`, `ba_buffee_tests`,
`ba_session_privileges_tests`, `ba_app_session_tests`,
`ba_buffee_control_protocol_tests`, `ba_session_memory_tests`) pass, 53 tests.
New `tests/control/session-peer-admission-smoke.py` passes: creator offline,
delegated grant accepted by a newcomer, empty Session keeps its ID and grants
nothing, returning Device keeps `on_air`. `buffee-reconnect-smoke.py` and
`session-restart-smoke.py` pass. `buffee-membership-smoke.py` passes every
membership/privilege step and fails only its final contacts-group persistence
check. Failures not caused by this change, each also failing at HEAD (run in a
scratch copy): `ba_contacts_tests` (expects no `sessions` key),
`session-privileges-smoke.py` (chat "is here" count) and
`parallel-sessions-smoke.py`. Smoke fixes for stale expectations: the probe
grants DSP consent before test jobs, an existing control session counts as
connected, and Desk sockets outlive a Session. OpenSound WebApp link fixtures now
say v5; `node --test` could not run (local Node is missing libsimdjson). Not
verified on Windows, iOS or the hosted Reception; no app rebuilt.

## Planning handoff to Mac — 2026-11-17

The user approved Reception-based peer discovery, Manager coordination separate
from privileges, and ordinary ("guest") participation on every Join. Joining
an empty Session never creates Admin; administrative authority must come from
an explicit grant rooted in the original creator. Persistent-admin design is
deferred. The accepted requirements, implementation order, live reproduction
and acceptance checks are at the top of PLAN.md. This handoff changes documents
only; the central admission dependency is still unfixed. Both checkout working
trees remain local/uncommitted, with no push or transfer to Mac performed.


## BESTSESSION2 live monitor and stale Admin display — 2026-11-17

Read-only snapshots from the user's current browser and EXE backends confirm
both target 94275F980055429F7368BCCCE0DA59BE, with distinct Device identities.
Both Reception connections are authenticated/error-free, membership is waiting,
privileges are empty, rejected messages are zero and backend Device lists are
empty. A disposable Windows observer ran production ba_cli_monitor:run_local
three times using the supplied invitation (no audio, chat or privilege changes).
Every sample remained discovering/waiting; an explicit Reception lookup of the
invitation admission mailbox returned zero active advertisers. This establishes
an unavailable invitation admission route, not proof of a particular remote
Device being powered off. Current fresh-join code cannot discover/admit the two
waiting Devices to one another without an existing grant-holder introduction.
That centralized admission dependency remains; it was not bypassed or redesigned.

The apparent Admin privileges were a distinct UI error: cached offline rows were
keyed by UI slot only and survived switching from the previously created Session
to this different Session. The row cache is now scoped to the actual Session ID;
the local row derives current privileges from its own backend snapshot, including
while the authenticated member list is still empty. Offline rows remain within
the same Session. No actual privileges/persistence were changed. 27 frontend
tests and four headless browser regression scenarios pass, including the exact
old-Admin -> waiting-Join transition. Web/Windows assets rebuilt.

The diagnostic observer stopped after the bounded check. Its redacted output is
in builds/intermediates/session-monitor/monitor.log; the invitation input was
removed afterwards. Existing user runtimes/Sessions were left running unchanged.


## Shared device-row flicker and invitation routing — 2026-11-17

The oversized black symbols were the ordinary on-air/speaker SVGs briefly
rendered without CSS. OsDevice replaced its entire shadow root, including the
stylesheet link, when state changed; outer Session-row refreshes also replaced
Device elements. The component now creates its DOM/stylesheet once and updates
text, visibility and attributes in place. SVG presentation attributes bound size
and outline rendering even when CSS is delayed or unavailable. Device/Session
row reconciliation patches existing light-DOM nodes, retaining custom elements,
disclosures and focused actions. The stylesheet URL is relative to the module
for bundled hosts as well as HTTP.

Read-only checks of the user's two local backends confirmed distinct Device
identities and distinct Session IDs (7882… and 2FF4…), both Sessions named with
the pasted invitation URL. Both were creators of their own separate Session;
this was not automatic recreation of the invited Session. Existing Sessions,
privileges and persistence were left untouched at the user's request. The opening
dialog now identifies invitation input and switches visibly to Join, retaining
the complete link instead of truncating it to the old 100-character name limit.
Normal names still create through the existing API and backend validation.

Validation: 26 frontend tests pass. An isolated real headless Chromium check
passes 50 rapid state changes with delayed CSS, 80 row updates with CSS returning
503 (stable Device/style/action nodes and keyboard focus), and the actual opening
form sending Join, never Create, for a long invitation. No runtime exceptions.
Windows and Web assets are rebuilt from the shared sources. Existing running
windows require reload/relaunch; existing wrongly named Sessions are not migrated
automatically. No admin-persistence or admission-policy redesign was made.


## Audio catalogue events and clickable Windows build — 2026-11-17

Removed the unconditional five-second peer catalogue query. Sources send
`catalog.changed` on registration, source process exit, pause change and rebound.
Receivers fetch on notification or authenticated peer-up; startup reads the
initial state of established peers once. An in-flight snapshot remembers/coalesces
later changes; bootstrap/peer-up do not duplicate an already-pending read. These
are signed audio-control messages with the same session, identity and replay
checks. Existing wire shapes/domains remain; old publishers need updating to emit
notifications. No Reception change or general Manager request board is included.

32 focused EUnit tests cover idle ticks with no network catalogue reads, initial
state/reconnection, notification coalescing, publication lifecycle, exact wire
shape, signed delivery/replay rejection and existing restore behavior. Local
reconciliation/retry timers, UI sampling and clock/lease maintenance remain;
this is not a claim of an entirely event-driven runtime or physical playback.

OpenSound/Build.cmd is the requested double-click build. All Windows packaging
logic now lives in build.py; Bash and optional PowerShell entries delegate to it.
Verified Build.cmd end to end, Git Bash build/tests, a fresh MSVC launcher and
identity-helper compilation, six DeviceWeb HTTP/API tests, 25 frontend tests and
the packaged Windows local three-Device/restart/concurrent-Session check. User
computer control remains stopped; no new visual or audio hardware test occurred.


## Windows shared frontend and mesh repair — 2026-11-17

OpenSound Windows uses exactly the shared Web assets and the common
`buffee_control`/DeviceWeb API, in an installed Chrome/Edge app process. Removed
its wx UI/model/chart/supervisor sources and obsolete model tests. Thin Win32 and
Erlang hosts retain existing Credential Manager keys, slot lease and state paths.
Browser subprocesses do not inherit the identity seed; app-process exit flushes
settings and stops the runtime. Web development DPAPI slots remain separate.

Found/repaired: only clock-authority pairs connected automatically; other pairs
needed the optional monitor. The control owner now connects all admitted online
peer pairs with one deterministic initiator. Clock/monitor duplicate initiation
is removed. This is mesh establishment, not the proposed request-board/admission
redesign. Synchronous cross-peer/cross-Session coupling remains in other paths;
see PLAN.md's concurrency audit.

Validation on Windows: package compilation; six applicable DeviceWeb EUnit tests
(Unix socket bridge omitted); 25 frontend tests; 35 signed-control/clock tests;
`tests/Windows/shared-web-smoke.py` passes isolated app shutdown/settings and
secret-environment checks, three-Device visibility without a monitor, local chat,
member and creator restarts, old invitation/new Device, two concurrent Sessions
and repeat-Join deduplication. The local Reception needed recompiling stale
artifacts first. Test clocks use system time and Reception is loopback-only.

The supplied BESTSESSION2 invitation parsed and local Join returned success;
public Reception authenticated, but remote admission remained waiting. No
particular Device's online state/version was established. A broad public test
Session/chat run was rejected by automatic approval review; it was replaced by
local tests. Only the user's specific invitation was tested publicly, without
chat or privilege changes. No Reception deployment occurred.

The app window was observed, but Edge account onboarding prevented complete
visual interaction; the user stopped computer control with Escape. Chrome is
now preferred when installed. Browser-window closure and existing native
credential restoration have not received full visual acceptance. Native Windows
capture/playback remain unconfigured in the shared profile; the old metering
input/autonomous output do not meet its shared PCM/revocation contract. No
physical playback or speaker timing claim is made.


## Implemented

- Trusted independent ownership and Chef/Guest roles; multiple Owners, explicit
  role changes/removal/Destroy, saved return after Leave and full shutdown.
- Acquired shared-clock continuation on an available synchronized Chef without
  an online Owner. Physical timing remains unqualified.
- Shared Web/Mac/iPhone frontend and BEAM control. Reception at
  https://buffee-reception.onrender.com runs compatible revision d32bc35.
- Large local JSON replies no longer truncate the monitor's line-mode buffer;
  malformed replies return a controlled error. Device and UI outlive the monitor.
- Web cleanup adds the Session toolbox, consolidated settings, accepted-chat
  draft clearing, append-only paginated Device rows and signed Chef requests.
  Owners see Allow on requesting Devices; toggling consent off does not cancel
  the request. Re-enabling sends another request. Permission never enables capture.

## Observed operation and limits

User confirmed chat across Web/Mac/iPhone, automatic rejoining, and audible
microphone output. Same Web processes survived about 18 hours with sleep and
reported internet loss; microphone audio was flowing at inspection. This proves
survival/recovery, not continuous overnight playback. No recent chat crash notices
were present. TLS failures preceded Reception starting again; reconnection worked.

Audio still reports overlapping packets, missed targets and output closures.
iPhone microphone capture has exceeded binding limits. System capture awaits
Chef authorization on Guest Devices. Counters lack event timestamps. Windows
Web audio integration and DPAPI behavior require Windows validation.

The cleaned Web UI has Audio switches only; Devices holds Session participants
above expandable saved groups. The persistent header shows Session and OS Device
names, without repeating page titles or displaying a preview banner. Automatic
invitation inbox delivery and drag-to-invite remain deferred. Existing Invite creates a link for manual sharing.

## Verification for the web cleanup

Frontend: 14 checks pass. DeviceWeb HTTP: 7 checks pass. Focused core role,
snapshot and protocol checks: 37 pass; OS-label/snapshot/lifecycle checks: 10 pass.
The full EUnit run encountered a shared-process setup collision (12 cancelled);
separate job/handler checks pass (18). A disposable three-Device check passes
repeated Chef requests, grant/clear/re-request, ownership and clock lifecycle.
Browser preview checks cover chat draft clearing, consolidated settings, no preview
banner, Audio/Devices separation and the compact header. See component READMEs for commands.
No native app installation, production audio session mutation or Reception
redeployment is included in that cleanup.

## Latest web refinement checks

Removed the remaining Audio heading, changed the composer placeholder to
Message everyone in this session, and replaced Undo/Redo glyphs with vector
curved arrows. Status sits beside the Session/device identity instead of inside
the toolbox. Saved devices is the sole lower-list heading.

New Sessions default to 300 ms; saved values are preserved. Local clock edits
and authenticated remote edits now require Chef or Owner. Clock hosting or an
old offset_write permission alone does not grant editing. Owner-only Destroy
remains enforced. Focused core checks: 45 pass; frontend checks: 16 pass. The
three-Device/two-Reception clock check confirms Chef edits propagate to all peers,
Guests are denied and revision conflict/recovery behavior remains intact.

Empty groups are supported in both UI and backend. Add to group is available in
Device menus; group membership was verified inline in the browser preview.
Drag-to-group handlers are implemented, but native drag automation did not confirm
the gesture. Role-colored initials supplement the existing role badges. No running
user Device, native application or public Reception was restarted for this work.

## Parallel web Sessions and Device labels

The web app now has browser-style Session tabs, an Add tab + control, and
OpenSound branding on the same top row. Closing a tab performs Leave, never
Destroy. Switching tabs keeps each view, draft and runtime alive. Invite uses an
envelope icon in the Session toolbox.

A Device-owned Session manager starts one local OTP supervision tree per added
Session. Term-named registrations and per-Session ETS/files separate membership,
clock, chat, consent/history and media workers. All Sessions share the Device
signing key, saved contacts and one authenticated Reception socket per URL.
Mailbox routing multiplexes Session messages locally; Reception is unchanged.
Existing default-Session state stays compatible. Owner return uses the saved
Session state; closed tabs remain closed after restart, while open tabs restore.
Display metadata now includes the type and OS name, such as Mac | BC-CG69… or
iPhone | Paavo’s iPhone. Display names do not replace cryptographic identity.

Critical checks: core and DeviceWeb compilation; frontend syntax and 14 state
checks; a local two-Device/two-Session Reception check passed shared identity and
socket use, isolated chat/consent, independent close, Owner return and restoration
after full shutdown. Both two-added-Session and default-plus-added-Session cases
passed. Device-type label checks: 2 pass; HTTP boundary and tab command checks:
7 pass. No automated visual review, native installation, public Reception change
or listening/timing qualification was performed. Concurrent physical audio and
manual UI acceptance remain unverified.

## Native Session-tab parity

The macOS and iOS WebViews now load the same outer Session-tab shell as the web
app instead of redirecting directly to one Session page. The native bridge
supports listing, creating and closing tabs; each iframe remains on the
packaged local origin, and snapshots are forwarded only to the matching Session.
Session-management replies preserve request IDs so asynchronous bridge calls can
be correlated. The Mac/iOS JSON bridge routes commands through `ba_sessions`,
just like the web service. The native allowlist also includes the current Device
role and removal actions used by the shared frontend.

OpenSoundKit tests pass (4 tests), including idle-state navigation and native
tab creation/closing. The iOS target compiles. DeviceWeb EUnit passes (7 tests),
including list/create/close via the native bridge and request-ID correlation.
The apps were not packaged or installed, and visual acceptance and concurrent
physical audio remain unverified.

Invite toolbox fix: any authorized participant may display and forward its
existing reusable invitation; ownership is not required to share an existing
link. Newly saved memberships preserve that link across rejoining. Old saved
Guest memberships without a link need an invitation-based rejoin to recover it.
Owner-only administration and targeted readmission remain unchanged.

Web UI increment: Devices is the default first tab, My Device second, Chat last
with an unread count. Offline row menus remain accessible. Kick removes admission
and invalidates the old passport but permits a fresh invitation-based join; Ban
is not implemented. Playback/Record use the existing local audio controls; Calibrate
and DSP are unavailable placeholders. System audio moves to the Session header.
My Device shows participation and provides Chef requests and self-demotion (an
online Owner must apply a non-Owner Chef’s signed demotion request). Internal
names are unchanged. Security architecture and choppy playback remain next steps.
No native app build or visual acceptance is included.

My Device refinement: “Let system use my device for:” introduces the controls.
Role is an icon with a tooltip; role-selection buttons are removed. System audio
requests Chef approval when enabled by a Guest. Calibrate now records independent
local permission for microphone/speaker calibration, with undo/redo and persistence;
it does not enable continuous recording or playback. A calibration execution
workflow is not implemented by this UI change. DSP remains unavailable.

Web home tab: the logo is a permanent, unclosable first tab. It opens static
branding/help content; Session tabs remain independent and continue running while
home is selected. Closing the last Session selects home. No runtime change.

Role icon placement: moved beside the Session name in the persistent Session
header; My Device contains consent controls only. Tooltip behavior is retained.

Web chat layout: viewport-height flex layout reserves the composer at the bottom;
only history scrolls as messages arrive. Removed the page-container focus outline,
retaining control focus indicators. Navigation tabs now have solid unselected
surfaces and conventional edges. CSS-only change; manual visual testing pending.

Session viewport follow-up: nested Session documents use their iframe’s percentage
height rather than a separate dynamic viewport height. Session panels fill their
parent explicitly. Safari zoom/layout acceptance remains for manual verification.

Web Session Settings now opens from the clickable status indicator beside the
Session name; the duplicate gear button is removed. Keyboard/button semantics
and connection-state tooltip are retained.

Web visual trial: Invite is temporarily hidden; system-audio consent is a speaker
icon toggle in the toolbox, with pressed state and descriptive status tooltip.
Existing consent and Chef-request behavior is retained.

Web header refinement: removed repeated Session/device names from the Session
header. Session tabs display the participation/ownership icon with a descriptive
tooltip. Session Settings states the local device name and explains Owner and
Chef/Guest roles in words. Frontend syntax checks pass; visual review is manual.

Web Session toolbar trial: all controls are right-aligned in Invite, system-audio,
Undo, Redo, Settings order. Settings uses a bordered gear whose color indicates
connection state; its accessible label and tooltip also explain the status.

Web refinement: fixed toolbar button/SVG geometry, continuous selected-tab/page
surface with navigation flush to the header bottom, and inline expandable
Connection details inside Session Settings. Frontend syntax checked; visual
acceptance remains manual.

Session Settings now saves valid name/response-time edits on field change and
role selections immediately, with only Close. Guests request Chef approval;
self-demotion retains ownership. Chef name changes go to an online Owner and
propagate via the revisioned signed membership statement; Owners rename directly.
Connection details stays inline. The navigation baseline extends to both edges.

Web settings grouping refined: Device heading/name/role form one spaced section;
role uses native radios styled as a segmented control. Connection details uses the
shared chevron shape, no input-like border, and selectable text. Invite now uses
person-plus artwork; gear geometry is radial and square-constrained. Navigation
order is Devices, Chat, My Device. JavaScript syntax checked; manual visual review
pending.

The introduction tab loads `src/Apps/WebApp/public/introduction.md` from the
OpenSound checkout. Edit that file; supported Markdown is headings, paragraphs
and unordered lists (no raw HTML or inline formatting). Asset builders copy it
with the UI. The content is shortened from the product README for app users.
Session navigation is now a left sidebar, becoming a bottom bar on narrow screens;
Session tabs remain at the top. Manual visual validation is pending.

Navigation visual trial: replaced the sidebar/bottom bar with always-visible
compact text navigation (Devices, Chat, My Device), using an underline for the
current view. Session actions align right and wrap below navigation on narrow
screens. No hamburger or secondary tab outlines. CSS-only; manual review pending.

Header wrapping fix: removed the narrow-screen full-row navigation width.
Navigation and actions now share a row whenever their actual content fits.

Apple frontend update: the shared native host reads the fixed bundled
introduction.md through a local bridge; web still fetches that same file, and
both use the same renderer. The screenshot’s short introduction was fallback
content after the web-style load failed in the native host. Home now has Join a
Session with a paste-link dialog, using a new parallel Session without replacing
existing ones. Invalid-link retries reuse the new blank tab. Native rename command
allowlist is also aligned with the web API. macOS and unsigned iOS device builds
succeeded; both packaged frontends match all source assets byte-for-byte.
Reopen the built Mac app; iPhone signing/install remains an Xcode step. Native
visual/Join acceptance remains for manual testing; no running Session was stopped.

Native home-action startup fix: early bridge requests could be discarded before
the runtime/channel was ready, leaving + and Join disabled. The shared native
host now retains bounded pending commands until the first runtime response, even
when that response has no Device snapshot because all Sessions are closed.
Optional browser session storage cannot abort UI initialization. A focused actual
macOS WebKit test with delayed runtime/no Sessions passes introduction loading,
Join dialog opening and the + new-Session command. The runtime in that test is a
stub; real macOS/iPhone connection acceptance remains manual.

Plus-button behavior corrected: the web/native shell requests new_session with
create=true, creating an authorized New Session immediately under the same Device
identity. Home Join still allocates a separate blank context for its invitation.
A disposable runtime check confirms + returns authorized membership, Owner role
and matching Session/Buffee ID. Duplicate native branding inside Session pages
is removed. macOS/iOS rebuilds include the change; real-device UI acceptance is
manual.

Native presentation scale: centralized PlatformUISettings defaults iOS to 120%
and macOS to 100%, applied through WKWebView.pageZoom. Same shared frontend; no
user setting or gesture restriction. iPhone sizing/reflow requires manual review.

iOS Session creation fix: display-name fallback eagerly evaluated os_name(),
which treated iOS as desktop Darwin and invoked scutil through os:cmd. iOS cannot
spawn that desktop command. Name lookup now uses the supplied BA_DEVICE_NAME
first and an iPhone fallback on iOS, avoiding desktop OS queries. Three focused
label tests pass, including supplied/missing iOS device names. A real iPhone
creation check remains manual after installing the rebuilt app.

iOS scaling correction: replaced WKWebView.pageZoom with a host-supplied
--ui-scale and relative component measurements in the shared stylesheet. iOS
remains 120%, Mac/Web 100%; viewport sizes and media breakpoints do not scale.
Pinch zoom remains unrestricted. Manual iPhone sizing/reflow check is pending.

The focused native WebKit regression check now also applies 120% component scale
at phone width and verifies that neither home nor the nested Session document
has horizontal overflow; it passes. This is macOS WebKit with a stub runtime,
not a real iPhone layout/keyboard acceptance test.

## Device consent security — first implementation slice

The agreed plan now prioritizes Device-owned enforcement before choppy playback
repair, with OS-isolation feasibility separate and no terminology refactor.

`ba_device_config` now has one Device-wide owner, shared by Session trees and
stored only at the Device root. Playback/Record/Calibrate/delegated-DSP grants
start OFF on startup or owner-process restart; previous saved grants/history are
not restored. History cannot re-enable a revoked permission; that requires an
explicit local change. Current-profile defaults no longer enable Playback.
Changes notify all Session Handlers. Join no longer copies configuration between
Session scopes. System-audio broadcast intent is held separately by each Session
and resets on its Leave/shutdown, rather than becoming a Device-wide switch.

Validation: seven existing configuration tests pass; one new focused multi-Session
security test passes shared-owner identity, cross-Session grant/revocation
visibility, separate broadcast intent, close independence, history protection and
fail-closed permission-owner restart. This verifies state semantics only. The
existing legacy profile preserves its established persisted configuration behavior.

NOT COMPLETE / NOT DEPLOYED: existing media reconciliation is still asynchronous;
no synchronous stop/flush acknowledgement, complete native execution gate, DSP-job
gate or OS isolation has been added. Device grants are a ceiling in the target
architecture; audit and separate per-Session operation initiation before claiming
that enabling a grant does not itself start work across Sessions. Local grant API
caller authorization also remains to be audited. Do not claim consent security is
complete or deploy this slice as a verified security boundary. No native app build,
installation, Reception deployment or live Session mutation was performed here.

## Execution-path audit and first execution gates

Added docs/CONSENT_ENFORCEMENT.md with resource paths, covered checks and explicit
remaining bypass/race/acknowledgement work. The Device owner publishes a protected,
read-only permission view; missing owner/view denies. Added current-profile gates
at Mac/iOS PCM open/write, mixer enable/render, native engine open/play/schedule,
Mac/iOS capture startup/callbacks/shared publication, Opus comparison startup/data,
Windows capture startup, and delegated test-worker admission/startup. Existing
legacy-profile behavior is intentionally not a security guarantee.

18 focused tests pass, covering Device-wide state, history/restart safety, denied
resource calls before side effects, late capture blocks and worker admission.
Compilation and diff checks pass. No native rebuild/deployment or live Session
was changed. Synchronous native stop/flush, queued-work fencing and independent
native/OS enforcement are STILL INCOMPLETE; do not describe the settings reply as
proof that all hardware/delegated work has stopped. The next implementation is
that acknowledged revocation barrier, not playback-quality tuning.


## Default audio revocation barrier — resume checkpoint

Implemented generation fencing and a Device-wide OTP pg executor registry. OFF
publishes denial first, waits for registered executors, and requires native stop
ACKs for default Mac/iOS PCM playback and microphone capture. Timeout/failed ACK
keeps permission OFF with pending confirmation and blocks regrant; losing a failed
executor is not success. Queued PCM and capture callbacks cannot regain validity
after OFF/ON. Registry replacement invalidates old grants/handles. The installed
test worker acknowledges termination; real delegated DSP is not implemented.
Autonomous native playback is blocked in the current profile pending its stop
protocol. UI snapshots show OFF/pending even when the command reports failure.

Validation: 26 focused Erlang tests and 14 frontend state tests pass. Mac Swift
output, Objective-C++ capture and iOS Swift audio sources pass source checks. No
app build/install, live Session mutation, Reception deployment or real hardware
stop/tail validation. Matching native helpers need rebuilding before use. Earlier
entries describe preceding slices; this entry supersedes their no-ACK status.

Next: per-Session broadcast OFF/role-loss acknowledgements, native crash/restart
recovery, remaining local grant caller audit and optional backend paths. Security
is still incomplete; OS isolation and physical stop guarantees are not proven.
See CONSENT_ENFORCEMENT.md. Manual additions at the end of PLAN.md are preserved.

## Privileges replace roles — 2026-11-15

Model: no Owner/Chef/Guest roles; Devices hold privileges `grant`, `on_air` and
`end_session`. `ba_session_privileges` replaces `ba_buffee_roles`. Membership
gains `request_privilege/1`, `grant_privilege/2`, `take_privilege/2` and
`end_session/0`; `set_role/2` and `request_chef/0` are gone. The Device API
commands are `request_privilege`, `grant_privilege` and `take_privilege`.
Snapshots carry `privileges`, `grant_holders` and per-Device `requests` in place
of `role`, `roles`, `owners` and `chef_requests`. Ending now needs `end_session`
instead of ownership. A `grant` holder's own request applies at once.

Wire: `owner` and `stream_publish` keep their signed spelling. New permission
`end_session` and new membership messages `privilege_request` /
`privilege_release` replace `chef_request` / `guest_request`, so every Device in
a Session needs this build. Sessions saved before this change have a creator
without `end_session`; it must request that privilege before it can end them.
Reception is unchanged.

Validation: focused EUnit for privileges, Session lifecycle, passport, clock and
control protocol passes (51). `tests/control/session-privileges-smoke.py` passes
with a local Reception and three disposable Devices; `buffee-time-smoke.py`
passes. Full core EUnit: 205 tests, one failure in `ba_monitor_tests` (device
label) that fails identically without this change. DeviceWeb EUnit has one
consent-undo failure, and `buffee-membership-smoke.py`,
`parallel-sessions-smoke.py` and `buffee-reconnect-smoke.py` fail, all identically
without this change (consent work in progress).

NOT DONE: the web UI and its preview state still use role commands and fields,
so role controls (Allow, Make Chef, Share ownership, Destroy visibility) do not
work against this core until the UI update. The native allowlist in OpenSoundKit
has the new command names, but no app was rebuilt or installed. No automatic
approval, time-limited grant or request board exists. Design standards and the
component catalogue in OpenSound still describe roles.

## Policies, hello and the web shell — 2026-11-15/16

Core (committed 2026-11-15): Device policies `always | ask | no` per protected
resource (`ba_device_config:policy/1,3`, Device API `policy`), calibration consent
split into `calibrate_microphone` and `calibrate_speaker`, and a grant holder's
`on_air_requests` policy that answers on-air requests automatically. `ask` is
only recorded: nothing in the system can ask yet, so it behaves as off. Session
chat gains local info entries: "is here" when an authenticated link to a Device
comes up, and a line for every signed change of `grant`, `on_air` or
`end_session`. Info entries are derived by each Device and never sent.
Validated by 65 focused EUnit tests and `session-privileges-smoke.py` (three
Devices, local Reception).

Web UI (2026-11-16): window-level Session tabs are replaced by a native Session
selector with status text, a fixed-label ON AIR button and a bottom row of
icons (Home, Chat, Devices, My Device, Session). The Session view no longer
rebuilds its controls on each refresh; that had wiped the Session name and
Response time fields while typing. Leaving or ending a Session removes it from
the selector. Relinquishing a right now asks first. Invite is visible again in
Devices. Frontend state tests: 18 pass (run with node@22; the default Homebrew
node on the development Mac fails to start). Checked in headless Chrome against
the preview adapter at 900 and 390 px wide: create, rename while refreshing,
on air, view switching and a second Session, with no page errors.

Answering requests (2026-11-16): "Auto accept all requests" is its own switch
(`auto_accept`); turning it on or off never changes the choices under it, which
show greyed as "Ignored while auto accept is on". A request for a right adds a
chat line ("… asks to go on air") on the asking Device and on each Device that
can answer. A grant holder sees a red balloon on the asking Device's row menu,
the request spelled out in that menu, and a banner under the top bar; both
offer Allow and Decline (`decline_privilege` clears the reminder only; the
asking Device is not told). Core: 65 EUnit tests and the three-Device smoke
test pass. Web: 20 frontend tests pass; headless Chrome check in preview at
900 and 390 px. Known gap: an effective Always still sets the old consent flag,
so turning the switch on starts the microphone until the request board lands.

Automation (2026-11-16): My Device is renamed Automation and made compact.
A second top switch, "Auto grant full rights" (Device API `auto_grant`),
answers requests for rights; under it are the on-air right
(`on_air_requests`) and moderator rights (`moderator_requests`, used for
`grant` and `end_session` requests, which earlier always waited). "Auto
accept all requests" no longer answers rights requests. GPS is a new
`location` choice, recorded only. Core: 65 EUnit tests pass; the three-Device
smoke test passed on a second run (the first timed out on clock sync before
any privilege step). Web: 21 frontend tests; headless check at 900 and 390 px.

Session picker (2026-11-16): the `+` button is gone. The picker lists joined
Sessions by name, shows "Not joined" (not "New Session") for an unjoined slot,
and always ends with "Create a new Session…", which opens the create dialog and
is never left selected. An unjoined slot is reused before a new one is opened;
the last slot stays after Leave. Join and Create are on Home only; Devices
shows just the list; the Session page keeps its controls, disabled, when not
joined. The picker sits at its own width in the top-left corner, ON AIR in the
top-right. Headless check in preview at 900 and 390 px.

Fixes from the user's first real-runtime test (2026-11-16): with auto accept
on, `calibrate_microphone` reached `ba_device_handler:capability_metrics/1`,
which only knew speaker/microphone/broadcast, and the handler crash-looped
("ba_device_handler stopped (case_clause)" in chat, "Device unavailable").
It now takes every consent key. Separately, ON AIR's system-audio helper exited
at once (likely macOS System Audio Recording permission) and a pending read
wrote to the closed port, crash-looping `ba_mac_audio`; that read now reports a
capture failure instead. The top bar is gone: the picker and ON AIR float in
the top corners over pages that run to the top edge.

ON AIR delay (2026-11-16): once capture ran, `ba_mac_audio:status/1` exposed
its permission token (an Erlang reference) and `ba_device_audio` copied the
whole status into `handler.audio.broadcast`, so every snapshot failed JSON
encoding and the UI showed "Device unavailable" with ON AIR grey. The status
now omits internal handles. Chat gains local lines "<Device> is going on air"
and "went off air", derived in `ba_device_audio` from this Device's published
sources and peers' offers (any source counts, microphone included). Saved
groups get a menu with Rename and Delete; removed saved Devices and groups now
leave the list instead of staying as greyed rows. 71 focused EUnit tests and
the three-Device smoke test pass. The on-air chat line and the ON AIR timing are
not verified on real Devices.

Invite tab (2026-11-16): the Invite button and dialog are replaced by an
Invite page in the centre of the bottom row (share icon): OS share sheet, copy
link, the link and a QR code. Inviting a saved Device or group opens it.
Automation uses a lightning icon, Session a settings gear. Headless check in
preview at 900 and 390 px; the OS share sheet is not checked in the native hosts.

Persistence (2026-11-16, the user's rule): a Device returns to the state it was
in, for every Device property: automation (both top switches and every
Always/No choice, `device_gates`), every grant, ON AIR, rights (kept in the
Session policy and by rejoining) and the current Session. Session properties
(response time, name, invitation link, chat) belong to the Session and are never
saved with the Device. Previously the secure profile ignored the saved
configuration and started with everything OFF, and the choices were never
written. Only a first start begins with everything off. This replaces the old
"permission owner restarts with every grant OFF" behaviour and its test; a
restart of that owner also returns the saved grants. Covered by
`ba_device_consent_tests`; 71 focused tests pass. The saved history is restored
too, so Undo still works after a restart.

Settings and Sessions (2026-11-16): Automation and Session are merged into
Settings (both top switches, Rights, Leave/End). A top switch that is on hides
the rows under it. Devices becomes Sessions: the current Session's name (with
Rename session and Invitation link in its menu), Response time and Devices, then
Saved sessions (saved groups, renamed accordingly; each with Rename session,
Invitation link, Delete saved session). Connection details are removed from the
UI. A saved session's Invitation link uses the earlier group-invite path (it
creates a Session from the group if none is open). Headless check in preview.

Single page, one Device store, push (2026-11-16): the web app is one document
(no per-Session frames). `store.mjs` holds every open Session's state and one
record per Device (name, connected, on air, mic, own speaker) built from all of
them; it tells views only when something visible changed (fast-changing
readings are left out of the comparison). `<os-device>` (`device-view.mjs`,
shadow DOM, styles in `device-view.css` because the CSP allows only same-origin
stylesheets) is the one view of a Device, reused wherever it appears; each row
adds that Session's own part (status, Admin, menu with rights/Kick/Ban). One
Session is current (Chat, Invite, Settings, ON AIR); Devices shows every live
Session, then remembered ones, groups, Saved devices. Push: `GET /api/events`
(DeviceWeb, token header) streams the Session list and each Session's reduced
state only when it changed (checked every 300 ms on the Device side); an
outside rename reached the page in about 0.3 s. Native hosts keep request/reply
with a 1.5 s refresh; the store still redraws only on change. Redraws are
scheduled with a timer, not an animation frame, so hidden windows stay
current. 23 frontend tests (store: one record per Device, change-only), 6 Swift
WebKit tests, preview and real two-Session runs pass.

Links between Devices (2026-11-17). Devices were admitted but never stayed
linked (shown "Not connected", no chat, no streams). Three causes, all fixed:
1. `ba_device_handler:capability_snapshot/1` sent an audio entry for every
   consent key (also `calibrate_*`, `dsp`), but the capabilities wire contract
   allows exactly speaker/microphone/broadcast. Each Device's own reply failed
   validation and `ba_buffee_control` answered with `reset/2`, dropping every
   link about a second after it formed. Now only the three wire entries are
   sent, and an invalid own reply is logged and answered "unavailable" to that
   one peer instead of resetting all links.
2. Mailboxes (`buffee_desks`) are new after every restart, so after both sides
   restarted each held a stale route for the other. A waiting member now also
   sends its hello to the invitation link's mailbox (`stable_route/1`), which
   the creator re-registers on every start.
3. CLI-started Devices (the web launcher uses `beamaudio new device`) never set
   `restore_buffee_on_start`, so the default Session slot was not restored and
   a creator never returned as authority. `ba_cli_device` now sets it (not for
   monitors).
New `tests/control/session-restart-smoke.py` (app path through the Device API:
link, restart both, relink, chat) passes; 77 focused EUnit and the three-Device
smoke pass. Note: link handshake and chat packets travel through the Reception
relay (`ba_buffee_desks:send`), not directly between Devices.

Presets (2026-11-17): Settings gets one Automation choice, saved as `preset`
inside `automation`: No control (both top switches on, choices kept hidden),
Friendly (trust everyone on; Playback, calibration, GPS Always; Recording Ask),
Tight (moderator, Recording, GPS No; on-air, Playback, calibration Ask), and
Advanced (shows every setting as it is, changes nothing). Choosing a preset
writes its real values in one change (grants go through the same stop barrier);
touching any single setting or switch makes it Advanced. A new Device starts in
Tight (`device_default_preset`, apps only); a Device that already has settings
starts in Advanced and keeps them. Tight's Ask on Playback means Session audio
stays silent on that Device until the approval prompt exists (plan step 4);
Playback now offers Always/Ask/No. New command `preset {name}`. Tests: core
preset test (defaults, each preset, restart), 25 frontend, 6 Swift, CLI and
restart smoke pass; checked in the preview at both widths and on a real runtime
(fresh = tight; friendly survives a restart).

Settings layout (2026-11-17): the Control choice (No control / Friendly /
Tight / Custom) is first; everything else, including My status, Admin, On air,
Kicks, Response time and Undo/Redo, is shown only in Custom. The other three
show an explanation of the level instead. "Custom" is the label of the stored
preset `advanced`.

Control slider (2026-11-17): the four levels are stops on one centred track
(Wild, Friendly, Tight, Custom) with a large balloon that travels between them
and an explanation whose centre follows it. "Wild" is the label of the stored
`no_control`; "Custom" of `advanced`.

Control level fixes (2026-11-17): a level that both stops one grant and gives
another (for example Custom with Microphone Always, then Friendly) was refused
by the consent barrier (`separate_permission_changes_required`) and the error
was hidden while Custom showed no text, so only Custom seemed to work. The core
now applies a level in two changes: stops first, then grants. A level error is
shown even in Custom. Choosing Wild asks first ("This will lose all control...",
Cancel / I understand); Cancel keeps the current level. Each level has a colour
(Wild orange, Friendly green, Tight blue, Custom purple; never red), used by the
balloon, the selected word and the Settings button in the bottom bar. The
invitation QR code is now SVG; the only PNG left is the apple-touch-icon, which
iOS requires as PNG. Tests: core preset test with the mixed case, 26 frontend;
real-pointer check on a real runtime (mixed change to Friendly, Wild Cancel and
I understand, colours). Not rebuilt into the Mac/iOS apps.

Stuck stop (2026-11-17): after Wild, the Mac app's Device refused every other
level: `revocation_pending` held five keys while no audio helper was running.
A helper that never acknowledged a stop was never escalated, and its own exit
did not count. `ba_native_stop:port/3` now accepts the helper's OS exit status
(waitpid) as proof it stopped, and kills a helper that does not acknowledge in
1.5 s, confirming only once its exit is seen. A socket EOF (iOS) and a port
already closed still confirm nothing; a dead Erlang executor still does not fake
an ACK. Tests: native stop (exit, killed silent helper, closed port), revocation
and consent pass. Not yet seen on a real Mac helper.

NOT VERIFIED: the new shell against a real Device runtime or in the Mac/iOS
hosts; no app was rebuilt. The OpenSoundKit WebKit tests still target the
earlier tab, toolbox and Settings markup and need rewriting. See PLAN.md.

Old saved Session records (2026-11-17): after the new join model removed
`recover_authority`, every Device with a Session saved by an older build crashed
on start (`binary_to_term(...,[safe])` refuses the unknown atom), so `Start Web
UI.command` waited forever. A `buffee_connection` record that cannot be read is
now ignored with a warning and the Device starts with no Session, as the join
model intended for old records; other records still fail loudly. Checked by
starting a copy of an affected Device through `beamaudio new device`. The CLI
still waits for readiness instead of reporting a runtime that died at boot.
New `OpenSound/scripts/test-all.sh` (and `Run Tests.command`) runs core EUnit
(223), the web frontend and OpenSoundKit tests; all pass.

Reception address (2026-11-17): the default Reception is now
`wss://beamaudio.onrender.com/reception` (Render service `beamaudio`, created by
cloning `buffee-reception`; render.yaml renamed). The Reception serves the relay
at `/reception` and keeps `/relay/v1`; clients accept either path. Invitations
carry the address they were made with, so links made against buffee-reception
keep using it until that service is deleted. The first deploy of the new
service failed: the clone did not carry the Dockerfile path, and the new route
needs the commits pushed. Tests: Reception ExUnit (both paths), core, frontend
and Swift pass; one intermittent core EUnit failure was seen once and not
reproduced in five further runs.

Reception live (2026-11-17): Render service `beamaudio` (srv-dbu7fih42hec73bpsjv0,
free plan, Frankfurt, auto-deploy off) recreated with the CLI after both old
services were deleted; root directory `src/Services/ReceptionDesk`, which is now
the Docker context. Commit 9dd9f9f is live. `/health` answers, `/reception` and
`/relay/v1` both upgrade to WebSocket, and `session-restart-smoke.py --url
wss://beamaudio.onrender.com/reception` passes (two Devices link, both restart,
relink, chat). `buffee-control-smoke.py` no longer matches the probe's API after
the join-model change and was not run; `public-smoke.py` needs the Windows bundle.

No playback on receivers (2026-11-17): the Mac app broadcast real audio (peak
-28.6 dBFS) and receivers had Speaker allowed, but their offer lists stayed
empty. Commit c42c8d9 had replaced the receiver's 5 s catalogue re-read with
push only (`catalog.changed`, link up), so one lost or early notice/reply left a
receiver unaware of a stream for good. `ba_audio_receiver` re-reads every
linked peer's catalogue every 5 s again, beside the push; each read is
independent and bounded. Likely cause, not yet confirmed on the real Devices.
A local three-Device check (joiner granted on-air) reached active subscriptions
when native libraries were loaded; `device-session-e2e.py` itself predates the
privilege and join model (its second publisher lacks on-air) and is stale.

Disabled-control hints (2026-11-17): every control the web app disables now
says why and what to do in its native hover hint (no Session, Device not
responding, busy, needs a right, hardware missing, auto accept on, nothing to
undo). One helper sets `disabled` and the hint together. 27 frontend tests pass;
checked headless on a fresh Device.

Short links (2026-11-17): new Sessions get `beamaudio://s/<ticket>`, 101
characters with the default Reception (v5 was ~565). Raw bytes instead of hex
and JSON, a 128-bit secret, the Session ID derived instead of carried, the
default Reception left out, and no signature or name (see
BUFFEE_MEMBERSHIP.md). The creator now signs the starting policy at creation so
joiners learn the name. v5 links still parse. Tests: new `short_link_test`,
224 EUnit, Reception, frontend and Swift pass; `session-restart-smoke.py`
passes through the public Reception (101 chars, name learned, restart, chat)
and locally (140 chars with a custom Reception).

Open in web (2026-11-17): the share page has "Open in web", which opens
`INVITE_PAGE#<invitation>` (OpenSound app.js; planned `https://opensound.onrender.com/app`)
in the system browser; native hosts use a new `native_open` bridge method that
opens https addresses only. The static page lives in OpenSound
`src/Apps/InvitePage/` and is not part of the Reception, so the Reception stays
a router. The link stays after `#` and never reaches the web server. Frontend,
Swift and core tests pass; the page checked headless (with and without a link,
no CSP violations). Not deployed yet; the apps do not register `beamaudio://`,
so the page shows Copy plus steps instead of opening the app.
Hosting paused (2026-11-17): Render could not be given access to the private
OpenSound repo, so the page is not deployed. `INVITE_PAGE` is empty and the
"Open in web" button stays hidden until it is set; the page, the button and
`native_open` remain in place.

Create in a new slot (2026-11-17): creating a Session in an empty extra slot
failed with `buffee_start_failed` (the Mac app; the browser created in its
default slot). An empty slot has a random ID, but a created Session's ID is
derived from the creator key and a nonce, so membership's ID check failed.
`ba_sessions` now re-keys an empty slot to the new Session's ID before creating
(as joining already did) and passes the nonce on. Reproduced and fixed on a copy
of the Mac app's state; all suites pass.


## 2026-11-20 — shared request approval cleanup

Rights and resource approvals now enter `ba_device_config:request/2` through
`ba_device_request:approve/2`. Removed the separate rights-policy decision and
resource fast path there. One settings owner evaluates approval on each request;
protected resources still require installed consent, including during stop
barriers. Pending rights remain on the signed board and resource requests in
Device configuration; requester-held signed grants remain unfinished.
Documented audio stream control and the shared backend/memory contract for
CLI, Inspector and web UI. No identity stores were merged.

Validation: 184 core EUnit tests pass, including new coverage for Always/Ask/No
across speaker and both rights categories, automation override separation and
invalid requests. No native app build, deployment or live audio test in this pass.


## 2026-11-20 — Windows all-tests launcher and baseline

Added OpenSound's top-level `Run Tests.cmd`: it invokes the same core Python
catalog as `Run Tests.command`, forwards arguments and preserves exit status.
`OPENSOUND_TEST_NO_PAUSE=1` disables the closing pause. No duplicate test catalog.
Prepared repository-local Reception dependencies and a production release.

Ran all 35 registered suites through the Windows launcher: **17 passed,
8 failed, 10 unavailable (macOS-only)**. Core EUnit: 184 passing; DeviceWeb:
6; Reception ExUnit: 4. Web Node/browser, saved-session rejoin, release boot,
moderation, privileges, restart and both clock variants passed.
Full machine-readable report: `builds/test-results/20261120-133408/summary.json`;
console log: `builds/intermediates/all-tests-windows.log`.

Failures to triage before claiming a clean integration baseline:

| Suite | Observed failure |
| --- | --- |
| Windows shared web | Version stamp caused a false asset mismatch; corrected comparison. Retest passes discovery/chat/restart, then times out waiting for all three Devices after both original endpoints restart. |
| Crash/chat | Test reads removed `sessions` snapshot field. |
| Device label | Wait for policy revision >= 3 times out. |
| Parallel sessions | `create_session` response times out. |
| Session control | Authorized-link/capabilities convergence times out. |
| Membership | Read-after-policy-change result differs from expected `forbidden`. |
| Peer admission | Test expects `/v5?` invitation instead of compact format. |
| Reconnect | Test requires POSIX mode 0600 on Windows. |

Windows smoke retest: `builds/test-results/20261120-134226/summary.json`, log
`builds/intermediates/shared-web-retest.log`. It still fails, so aggregate counts
are unchanged. Failures include stale assertions and unresolved behavior; they
are not all confirmed product defects. Apple tests were not executed here.
