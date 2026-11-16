# Current plan

## Priority: Device-owned consent before playback repair

The Web/Mac/iOS UI is shared and has concurrent Session tabs. The user confirmed
iOS Session creation now works. Finish permission enforcement before changing
choppy playback paths.

Model change (2026-11-15): Session replaces Buffee and privileges replace roles
(see TERMINOLOGY.md). The web UI now uses privileges, policies and a Session
selector (PROGRESS.md, 2026-11-16). Existing `buffee`/`chef` identifiers leave
only where they get in the way.

### Direction set by the user on 2026-11-16: rights gate, requests act

The Always / Ask / No choices are access gates only. They never start or stop a
Device action. Actions start from requests:

1. A Device presses ON AIR. That tells the Session's Manager "I am playing".
2. The Manager posts a request on the Session's request board: every Device
   with a speaker should open it and subscribe to the Session's audio.
3. Each Device answers for itself. Its gate for that use and device pair
   ("speaker for audio") decides: Always accepts, No declines, Ask prompts the
   user ("Allow speaker use for audio?").

Every right, and all Device-specific configuration, should go through this one
mechanism, built from standard OTP blocks. OTP has no rights framework, so the
model stays ours; the mechanics should be plain `gen_statem`, supervisors, `pg`
and ETS. Today's code differs: an `always` policy still sets the old consent
flag, which starts capture or playback directly, and nothing posts requests.

Vocabulary: a **request** is what gets posted; the **request board** is the
Manager's list of open requests; a **Worker** is the local process that carries
out an accepted one. "Job" and `job_offer` are the older names for the same
idea and leave gradually.

### In progress (2026-11-16): the top switch and answering requests

User decisions: "Auto accept all requests" is its own switch. It never changes
the choices under it; they are ignored while it is on. A Device that can give
rights sees requests in three places: a chat line when a request is made, a red
balloon on the requesting Device's row menu, and a banner it can answer. The
row menu spells each request out in words with its answer.

Core DONE, not committed (65 focused EUnit tests and the three-Device
`session-privileges-smoke.py` pass):

- `ba_device_config:auto_accept/2`, Device API `auto_accept {enabled}`,
  snapshot `configuration.auto_accept`. Stored `policies` are unchanged by it;
  `ba_device_config:policy/1` returns the answer in force.
- Chat info lines "asks to go on air" (and the two other rights), on both the
  asking Device and each Device that can answer.
- `ba_buffee_membership:decline_privilege/2`, Device API `decline_privilege
  {device, privilege}`: clears the reminder only; the requester is not told.
- Web and native command allowlists include both new commands.

Web UI DONE, not committed (20 frontend tests pass; checked in headless Chrome
in preview mode at 900 and 390 px, no page errors):

- The top switch sends one `auto_accept` command and reads
  `configuration.auto_accept`; the rows keep their stored values, greyed, with
  "Ignored while auto accept is on".
- `openRequests` (state.mjs) lists what this Device can answer: grant holders
  only, Devices still connected, rights not already held.
- Device rows: red balloon with the count on the row menu; each request spelled
  out at the top of the menu with Allow and Decline. The inline Allow is gone.
- Banner under the top bar for the target Session (oldest request, "+N more"),
  answered through the `opensound-answer-request` window event.

Then (same day) the page became **Automation** with two top switches, each
over its own choices: "Auto accept all requests" (calibration, audio, and new
`location` for GPS) and "Auto grant full rights" (`auto_grant`) over
`on_air_requests` and new `moderator_requests` (requests for `grant` or
`end_session`). Neither switch changes the choices under it. `location` is a
recorded choice only: nothing asks for location yet. Auto grant applies to
requests that arrive after it is turned on.

Not yet checked against a real Device runtime or the Mac/iOS hosts.

Known gap until step 2 of the ordered plan below: an effective Always still
sets the old consent flag, so turning the top switch on starts the microphone.

### In progress (2026-11-16): one settings pipeline, then Sessions memory

User decisions: a Device starts from one plain-text user settings file, saved
right away on every change (throttled), shared by CLI, web, Mac, iOS and
Windows. Secrets stay separate. Every configuration value travels through it.
A Session exists once its invitation link exists; the file remembers every
link (with its name) and the Devices seen in each Session. That memory only
grows: Devices are never removed, only given a new status (kicked); absent ones
show grey. Saved Sessions load only when expanded. "End Session" becomes "Kick
everyone (including me) and leave". Undo/redo is set aside (in memory only);
Git-managed settings may come later.

Phase 1 DONE (not committed): `ba_settings` owns `settings.config` (text,
`file:consult`, writes within 200 ms, atomic rename, unreadable file kept as
`.broken`). All 99 `os:getenv("BA_…")` / `application:get_env(ba_core,…)` reads
in the core go through `ba_settings:env/app`, which the file can override.
`ba_device_config` (grants incl. ON AIR, automation) and `ba_contacts` (saved
Devices and groups) keep their state there; the `device_configuration`,
`device_gates` and `contacts` files are no longer used; on the first start
without `settings.config` their content is imported once. 74 focused tests,
`cli-config-smoke.py` (text file, restart, hand edit) and the three-Device
smoke pass. The Reception service is not part of this pipeline.

Phase 2 DONE (not committed): Sessions memory lives in the settings under
`contacts`: `sessions => #{SessionId => #{name, link, devices => #{DeviceId =>
member | kicked}}}`. It only grows: `ba_contacts:observe` adds Devices,
`kicked/2` changes a status, a Device seen again as a member is a member again.
The first known link is kept (join, the Share page, and right after creating a
Session, which now makes its link at once). Earlier per-Session groups
(`buffee_groups`) became Session entries; custom groups stay groups. The open
Sessions (`web_sessions`) are `open_sessions` in the settings. Passports and
grant-holder signing state stay in each Session's private `buffee_connection`.
New command `rename_saved_session {entry, name}` (the word `session` is the
UI's routing field). UI: past Sessions under Saved sessions (Devices grey unless
present, "Kicked" shown), menu Rename session / Invitation link (copy, share);
"End Session" is "Kick everyone and leave"; custom groups' menu says "Invite
group"; groups no longer collapse when clicking elsewhere. 76 focused tests
(2 new memory tests), the three-Device and CLI settings smoke tests pass;
preview headless check. Not verified: link recording and kick status against
a real two-Device run; Mac/iOS/Windows hosts. Saved Sessions do not connect when
expanded (memory only); joining a saved Session from its menu is not built.

### Ordered plan (agreed order pending the user's confirmation)

1. **Request board and the on-air request (core).** The Manager keeps open
   requests as static data (kind, parameters, selector, expiry), announces new
   ones and gives the list to a joining Device, like the stream catalogue.
   ON AIR posts "open your speaker and subscribe". Devices select themselves.
2. **Gates stop acting (core, same increment as 1).** Policies decide answers
   only. Playback and capture start when a request is accepted and stop when it
   ends or the gate turns to No. These two steps must land together: removing
   the direct start without the request flow would leave no way to play.
3. **One grant state machine.** Each asked-and-answered grant is a `gen_statem`
   under a supervisor: asking, granted (with a state timeout for "3 minutes" or
   "until 17:00"), ended. It replaces the hand-written bookkeeping for `ask`
   and feeds the existing acknowledged-stop barrier on revocation.
4. **The approval prompt (UI).** "Allow <device> use for <use>?" with the
   duration choice, shown where the user is; pending prompts are visible state.
5. **"Auto accept all requests"** is its own switch (see In progress above).
6. **One machinery for rights.** Entrance and the passport (direct re-entry)
   become privileges; Ban is taking entrance so an invitation no longer
   re-admits. Session privileges, Device gates and Device settings share one
   data shape: who, which device or resource, which use, until when, granted by
   whom. This changes security-sensitive admission code; design it first.
7. **The Session page lists every right** with Request and Relinquish.
8. **Scope of gates.** They are Device-wide. Rule from the user (2026-11-16):
   every Device property persists and is restored at restart (automation,
   rights, on air, current Session); Session properties (response time, name,
   invitation link, chat) stay with the Session. Done for the configuration
   owner. The user also expects different trust per Session; decide, then build.
9. **Native hosts (started 2026-11-16, ahead of 1–4 at the user's request).**
   Done: one command list in the core (`ba_device_api:client_methods/0`), used
   by the web server and by `ba_bridge` for the Mac/iOS apps (plus the host's
   own `network_changed` and `audio_lifecycle`); the Swift copy is gone. The
   bridge asks the OS for microphone access on the mic button
   (`microphone_live`) as well. OpenSoundKit WebKit tests rewritten for the
   current window (fresh Device opens on Devices; saved page restored and saved;
   ON AIR/mic/speaker reach the Session page; bridge forwards commands); 6 Swift
   tests pass with full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   swift test`; the command-line tools alone lack XCTest). TO DO by the user:
   Mac/iOS builds and manual checks (settings.config in the app's folder and
   the one-time import, mic permission prompt, share sheet, on-air sound,
   iOS kill-and-reopen keeps settings). Earlier wording follows:
   **After the above:** verify the web shell against a real Device runtime and
   in the Mac/iOS hosts, and rewrite the OpenSoundKit WebKit tests for the final
   markup. The user asked for the tests to wait until the changes are complete.
10. Pre-existing failures unrelated to this work: one device-label unit test,
    one consent-undo test in DeviceWeb, and the membership, parallel-sessions
    and reconnect smoke tests.

### Increment 1 — essential local enforcement

Current implementation: shared Device consent, execution gates and an acknowledged
revocation barrier for default macOS/iOS PCM playback and microphone capture are
implemented. Old permission generations fence queued work after OFF/ON. See
CONSENT_ENFORCEMENT.md for coverage and limits. Not deployed or hardware-verified.

Next, resume with per-Session system-audio OFF/role-loss acknowledgements and
native crash/restart recovery. Audit remaining local grant callers and optional
backend lifecycles before claiming completed consent enforcement. Autonomous native
playback backends are blocked in the current profile until they implement the
stop protocol. Preserve the release tasks below; audio-quality tuning follows
this essential enforcement work.

1. One Device-wide local permission owner for Playback, Record, Calibrate and
   delegated DSP. All Sessions observe the same ceiling. Defaults are OFF;
   restored Sessions, configuration replay/history and worker restarts cannot
   grant permission. System-audio broadcast intent remains per Session.
2. Trace local UI/CLI, authenticated remote commands, media/data channels, native
   adapters/helpers and optional backends. Only the trusted local settings path
   can grant permissions; no Session role or network message grants local access.
3. Enforce current permission at every protected execution boundary, including
   native output/capture and delegated job execution. A network authorization or
   old buffered packet is not current Device permission. Gate failures deny work.
4. OFF must prevent new work, fence queued work and stop/flush active operations
   across every Session before acknowledging completion. Identify and measure
   unavoidable already-submitted hardware buffering; never promise to undo sound
   already emitted. Polling/reconciliation is recovery, not the security gate.
5. Calibration is an explicit purpose-specific grant to use microphone and
   speaker on remote request without another prompt. It does not grant general
   recording, arbitrary playback, remote code loading or unrelated DSP jobs.
   OS microphone authorization still applies. DSP OFF blocks delegated processing,
   not ordinary computation needed to operate the application.
6. Verify denied/allowed paths, revocation during work, stale/queued requests,
   concurrent Sessions, leave/rejoin, shutdown and worker failure. Use focused
   security regression checks; avoid broad UI testing or incidental refactoring.

Keep this increment's claim scoped to an uncompromised local runtime/app:
remote participants cannot override the user's current Device consent. An OTP
actor or local token alone does not isolate against arbitrary local VM compromise.
The UI is a client of policy; merely having it running proves no user action.

### Increment 2 — OS isolation feasibility (separate investigation)

Investigate sandboxed macOS XPC and iOS ExtensionFoundation suitability for BEAM,
networking, media transport, background/foreground lifecycle and resource access.
Prove which hardware interfaces are actually inaccessible from the restricted
process; separate processes alone are insufficient. Keep the trusted resource
component small. Do not move DSP/timing policy out of Erlang or adopt a new
architecture before evidence. Android mechanisms are research only for now.
Biometrics/attestation are not prerequisites for local permission enforcement.
A malicious app/OS update is outside the first increment's guarantee.

## Then repair audio playback

Investigate iPhone capture block limits, overlapping packets, missed presentation
targets, output closure/recovery and actual listening quality through the protected
paths. Distinguish software scheduling from physical speaker timing. Do not make
all playback repair wait for an unproven iOS isolation design.

## Other deferred work

- Automatic approval, time-limited grants and a Manager request board for
  privilege and consent requests (designed in discussion, not built).
- Automatic invitation delivery/drag-to-invite requires a real invitation inbox.
- Windows Web/native audio integration and platform-specific validation.
- Device launch-slot reuse and bounded timestamped diagnostics.

Keep Reception's opaque transport stable; this work requires no Reception update.
No routine native rebuild, deployment or commit unless requested/needed to verify
this increment. Keep completed work and limits in PROGRESS.md.







### OpenSound iOS — App Store release tasks

1. **Privacy manifest:** Create and bundle `PrivacyInfo.xcprivacy`. Declare actual data collection and required-reason APIs.
2. **GStreamer:** Remove completely from Release builds if WebRTC can replace it; otherwise implement LGPL static-linking compliance.
3. **Erlang/OTP:** Complete and bundle upstream copyright, license and third-party notices for the embedded runtime.
4. **WebRTC:** Audit the exact framework build and include all transitive dependency notices.
5. **Other dependencies:** Verify OpenSSL, libsrtp, Rust/SCTP and remaining bundled component licenses.
6. **Attribution:** Make complete third-party notices accessible within the app.
7. **Verification:** Build a Release archive, inspect actual binaries/resources, generate Xcode's privacy report and verify compliance.

Reference: `OpenSound/docs/iOS/RELEASE_LICENSE_AUDIT.md`.