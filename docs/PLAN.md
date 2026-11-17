# Current plan

## iPhone output rejection and stalled recovery — 2026-11-17

Public-CLI inspection through the existing Web Device reproduced brief iPhone
output followed by silence. The native log identified a presentation-target
rejection; closing TCP on that rejection left an unconfirmed stop and a dead
handle which the Mixer repeatedly reused. Details are in PROGRESS.md.

Implemented: native buffer rejections are reported individually to Erlang;
later targets continue on the same output, without retiming. Local audio TCP
uses NODELAY. Genuine closures with unconfirmed stop block handle reuse and
expose `mixer.output_stop_pending`. Consent/stop acknowledgements stay intact.

Next: user rebuilds/runs the iPhone in Xcode, keeps Mac broadcast on and Web
playback off, waits for clock acquisition, then listens. Component tests and
Swift typechecking pass; the repair is not installed or proven audible. If
drops continue, inspect the precise native counters and logged target lead
before changing handoff policy. Clock-filter resets and Web overlap remain open.

## Generic public Device API through CLI — 2026-11-17

Implemented: `get methods` discovers the declared Device command API; `call
device --devicename NAME --request JSON` (or stdin) forwards those commands
through the existing owner-local socket, Session router and API validation.
New public commands need no per-method CLI wrapper. Existing convenience and
process-lifecycle commands remain. This exposes the Device API, not arbitrary
Erlang functions. Public-CLI idle-Device regression passes with audio OFF.
Use this path for the outstanding audio diagnosis/tests where applicable.

## Live audio diagnosis and Inspector identification — 2026-11-17

Inspected the user-supplied Session through an audio-disabled CLI observer, then
stopped that observer. No playback, consent or response-time settings were
changed by the agent. The user adjusted playback and response time during the
inspection. Findings and measurement limits are in PROGRESS.md.

The iPhone output repair above follows this initial inspection. Further audio
work: trace the clock-resync trigger and publisher's block target spans behind the web
receiver's overlap drops. Also isolate same-Mac capture/playback feedback and
source clipping using playback on another physical Device. Do not equate overlap
rejections with demonstrated network loss or change the clock policy on a guess.

Inspector labels now begin `Inspector Mac` (Inspector + platform) so the compact
UI preserves their purpose. Developer instructions now introduce the existing
CLI join/inspection path, private observer state and cleanup from the outset.
This initial inspection did not itself change audio behavior.

## Session response-time controls — 2026-11-17

Implemented: new Sessions default to 150 ms; the shared frontend has native
radio choices Automatic / 50ms / 150ms / 300ms / 800ms / 2s. Automatic is always
disabled with "Not implemented". Existing values and editing privileges stay
intact. The CLI monitor prints the shared response time and its readiness.
The displayed Settings profile Tight is now Strict; the saved `tight` key stays.
Next: user-led UI/listening checks after rebuilding/restarting the relevant host.
This increment does not establish the cause of the reported audio timing issue.

## Device identity and forgetting Sessions — 2026-11-17

Implemented: the Mac Web shortcut reopens its named Device instead of allocating
another identity on every launch. A standalone local Web Device requires a
persistent identity/state pair instead of silently generating temporary ones.
Forget removes local Session memory, return links and cached privilege policies;
an ID-only marker blocks background observations and automatic restoration until
the person explicitly uses the link again. Leave still preserves privileges.

Next: user-led restart/manual acceptance with the rebuilt Mac app and Web
launcher. Existing independent Devices have separate keys and may hold different
privileges; they have not been merged, stopped or deleted. Native windows and the
Web launcher still have separate identities. No Reception deployment is needed.

The public CLI now exposes the same Forget operation and scriptable meter
diagnostics (`monitor --metrics --once --json`), covered by a high-level CLI
regression. Keep manual UI/listening checks user-led. The next useful audio
scenario is a known tone started/stopped by a test: assert fresh nonzero meters
and receive/render progress, then verify stop/disable clears work. Counter-only
`audio-flowing` can pass for silence. This playback scenario is not yet written.

## Agreed direction — 2026-11-17: boards as a replicated log

User's model: every request and message goes to the Session's boards (request
board, message board); the chat shows both without distinction and nothing
writes to the chat separately; a Manager nudges Devices to look at the boards;
an admin returning later still sees and answers requests made while offline.

Mechanism (anti-entropy gossip, as in Cassandra gossip / Secure Scuttlebutt):

- Each Device keeps one append-only log per Session (owner process + ETS, saved
  to disk). Entry: author Device, author's own sequence number, time, kind
  (`message`, `request`, `answer`), body, author's signature. Never edited.
- Writing appends locally and pushes the entry to currently linked peers.
- On every link, peers swap "highest sequence seen per author" and send what
  the other lacks. Merge is union: no conflicts, no leader.
- Boards are filters over the log: messages; requests without an answer. The
  chat renders the whole log in time order (no locally derived lines; presence
  and on-air state stay in the Devices list).
- Each Device reacts to arriving entries itself under its own Always/Ask/No
  choices; answers to privilege requests are entries plus the signed change.
- No Device may become a bottleneck (user, 2026-11-17). Audio needs no board
  and no Manager: the on-air Device's catalogue is its standing request.
  `ba_audio_receiver` pushes `catalog.changed` to linked peers, every Device
  reads a peer's catalogue when their link comes up and re-reads it every ~5 s,
  then subscribes under its own speaker choice. New joiners and returning
  Devices therefore find an ongoing broadcast without anyone coordinating; the
  offer exists exactly while its source is online. (Source-read, not yet a
  multi-Device audio test.)
- The log above is only for messages and rights requests, where a returning
  admin must see requests made while it was away. History is shared by whoever
  holds it; never wait for it. A Manager, if ever added, only nudges ("sync /
  look"); two at once just nudge more often; it holds no state.

Replaces: `ask_holders` direct live-only requests, the in-memory request list,
and `ba_buffee_chat`'s separate history.

Open: the log's size bound, and whether a removed Device keeps receiving
entries (proposed: no).

## Agreed next work / Mac handoff — 2026-11-17

This is the user's accepted model and supersedes earlier admission proposals
below. Status 2026-11-17: discovery and admission are implemented (pairwise,
link-based, no passport; see PROGRESS.md). Still open below: Manager lifecycle,
Manager notification -> Device-local decision -> subscription, and UI state for
reachability. Also open from the design review: whether the creator's `grant`
should be irrevocable, and replacing End with "remove everyone and leave",
since a permanent link can always reopen a Session.

### Required behavior

1. A Device contacts Reception using the invitation to discover/access the
   Devices participating in that Session. Discovery must not require the
   original creator, an online administrator or an administrator-only mailbox.
   Reception stays an opaque authentication/introduction/routing service; it
   does not decide privileges or interpret Session application policy.
2. When other Devices are present, one of them hosts the Session's Manager.
   Find that Manager through the available peers. Manager is a coordination
   process, separate from administrative privilege: hosting or replacing it
   never grants Admin. Its lifecycle must not recreate the old creator gate.
3. Join itself always establishes ordinary (the user's word: "guest")
   participation, with no administrative privilege. An empty Session does not
   promote the first arrival, turn a joiner into a creator, or justify creating
   a replacement Session with new rights. Preserve the invitation's Session ID.
4. Admin is an explicit privilege rooted in the original creator and given
   through legitimate explicit delegation. Possessing an invitation, finding
   no peers, hosting Manager or being first online supplies no such delegation.
   Use the existing `grant` privilege vocabulary in implementation; "guest"
   here means an ordinary Device, not a newly introduced role system.
5. Local participation, discovery, individual peer authentication, Manager
   coordination and privilege grants are distinct concerns. Each connection
   proceeds independently; an absent, incompatible or failing Device/Session
   must not stall other available peers or Sessions. If no peers are online,
   retain the joined Session and react when peers appear.
6. Use messages/change notifications for discovery and work announcements,
   following established patterns/libraries. The request board describes
   application work (e.g. subscribe/play), not a new prerequisite for joining.
   Devices create their own subscriptions under local consent. Manager
   placement and Session privileges never override that consent.

### Scope and order on Mac

Done 2026-11-17: Session-scoped Reception discovery and pairwise, link-based
admission replaced the grant-holder passport chain; Reception was not changed
(see BUFFEE_MEMBERSHIP.md and PROGRESS.md).

Then connect peer discovery to the Manager lifecycle and independent per-peer
connections. Make UI state report actual participation/reachability and the
Device's actual privileges. Do not solve persistent-admin storage, recovery,
revocation history or ownership succession in this increment; that design was
explicitly deferred. No automatic Admin bootstrap is an acceptable workaround.

After discovery/admission works, finish the planned Manager notification ->
Device-local decision -> subscription flow. Catalogue change notifications are
already implemented; the general Manager playback-request board is not.

### Acceptance checks

- Done (`session-peer-admission-smoke.py`): original creator and every Admin
  offline, two unprivileged Devices join the same link and discover one another;
  neither gains `grant`, `on_air` or `end_session`. Chat between them is not
  yet asserted there.
- Done (same smoke): the first Device in an empty Session keeps the exact
  Session ID and later discovers another joiner without administrative rights.
- Available peers expose the Manager; hosting or moving Manager does not
  change privileges. Its discovery/recovery does not block ordinary Join.
- One peer is unavailable/incompatible: other peer connections and a second
  concurrent Session continue. Returning peers are handled through events.
- Explicit administrative grants remain distinct and require legitimate
  authority rooted in the original creator. No persistent-admin redesign is
  claimed or required for these basic guest-participation checks.

### Earlier live reproduction (resolved)

BESTSESSION2 (`94275F980055429F7368BCCCE0DA59BE`) showed two Windows Devices
waiting forever on an invitation admission mailbox with no advertiser. That gate
is gone; its v4 link no longer parses, so recreate that Session to retest on
Windows. Windows native audio remains unintegrated.

## Latest frontend repair — 2026-11-17

Device status SVGs no longer recreate their stylesheet/DOM on refresh. Stable
row patching preserves Device custom elements, menus/focus and disclosure state;
explicit SVG dimensions/strokes prevent oversized black fallback graphics.
The opening dialog treats pasted `beamaudio://` links as Join, not a new Session
name, and accepts full invitations. Read-only local inspection established that
the user's two self-only Admin views were distinct Sessions named after the
invitation. No automatic dead-Session recreation was observed; do not infer it.
Keep admin persistence out of this repair, as explicitly requested. Existing
running Sessions and Device identities are unchanged. 26 frontend tests and
three headless Chromium regression scenarios pass; Web/Windows assets rebuilt.


## Latest implementation: notification-driven audio catalogue and one-click Windows build — 2026-11-17

Supersedes the catalogue-polling findings in the audit below. Shared audio sources
now send a signed `catalog.changed` notification when registered, removed, paused
or rebound. Receivers read the catalogue on that event, on authenticated peer
connection/reconnection, or once at receiver startup. Pending reads coalesce
changes into one follow-up read. The five-second all-peer catalogue polling is
removed; idle reconciliation ticks issue no catalogue reads. Existing source
formats and signing domains remain unchanged; updated publishers are required
to emit the new notification. General Manager playback requests/board are still
not implemented. Local audio reconciliation, UI snapshot sampling and protocol
lease/clock timers remain separate pending work, not claimed removed here.

The user wants no typed build command. Double-click OpenSound/Build.cmd.
`build.py` is the single Windows build implementation; cmd/Bash/optional
PowerShell wrappers call it. Real Build.cmd and Git Bash builds, fresh MSVC
launcher/identity-helper compilation, six HTTP/API tests, 25 frontend tests,
32 audio/control tests and the packaged Windows local integration check pass.
This does not establish physical audio or complete visual acceptance.


## Windows unification and Session concurrency audit — 2026-11-17

Windows now packages the shared Web frontend and DeviceWeb API in a Chrome/Edge
app window. wxErlang UI/model/chart sources are removed. Existing Windows native
identity keys/state are retained. Compilation, 25 frontend tests, six applicable
DeviceWeb tests, 35 control/clock protocol tests and the local packaged Windows
integration pass. Native Windows PCM capture/output remain unintegrated.

A concrete mesh defect is repaired: the control owner now initiates missing
admitted peer connections, independently of the optional monitor. The clock and
monitor no longer initiate competing handshakes. Three Devices discover each
other, both endpoints restart, original invitations still admit a fresh Device,
and a second Session/repeated Join retain the original peers.

The user asks for an architecture analysis before changing admission: joining
locally must work offline; each peer pair must proceed independently; one broken
Device or Session must not block the others. Local Join currently returns success
and opens a Session before remote admission; the supplied BESTSESSION2 test
stalled waiting for authorized connectivity, not in the Join command itself.
Do not describe that timeout as a proven Join-command failure or blame an old
version without evidence.

Audit findings still to address (fresh admission no longer needs a `grant`
holder, 2026-11-17): a policy/routes change resets all peer links;
Session list/start/stop preparation can block in the shared coordinator; Web SSE
and native polling collect Session snapshots sequentially. The request board is
still planned, not implemented as a general board. Existing rights requests are
not that board. Separate local participation, pairwise identity verification,
privilege grants and transport. A request to introduce a new Device must be
processed independently per pair, with no all-Device acknowledgement barrier.
Manager announcements must not become a prerequisite for local Join.

User direction during this audit: a new Device enters through Reception, then
introduces itself to the other Devices directly or through a Manager's request.
Evaluate the traffic model against OTP's peer mesh before implementing it. A
mesh supplies independent addressed links, not automatic broadcast of all data;
the request board remains application data (open requests and independent
answers), separate from transport and privileges. Keep one transport per Device
pair, multiplex Sessions, send membership/request changes to relevant peers and
media only to subscribers. This is a proposed direction, not yet implemented.

Further design challenge from the user: B can tell C its observation of A;
all-to-all direct probing is not a requirement merely to maintain a Session's
presence list. Evaluate established membership/failure-detection and dissemination
patterns before adding a custom board. SWIM separates detection from gossip and
uses indirect probes/piggybacked changes; Partisan offers BEAM overlay backends
including HyParView. Neither gossip nor a forwarded observation establishes a
working direct A-C media path. Individually authenticated identity/privilege
proofs remain separate: memberlist's shared-key fully-trusted membership is not
our mutually untrusted Device boundary. A request board may remain application
requests/pub-sub, but must not become a new discovery or admission framework.
Full-mesh connection establishment repaired above is a bounded fix to the
existing topology, not evidence that mandatory full mesh is the final design.
References: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf,
https://github.com/lasp-lang/partisan,
https://github.com/hashicorp/memberlist/blob/master/SECURITY.md.

Audio request-flow audit requested by the user (2026-11-17): desired flow is
ON AIR -> Manager announces/requests playback -> each Device independently
accepts under its local gates and creates its own subscription -> UI learns
changes. The current code only partially implements this. `ba_device_audio`
reconciles locally every 250 ms, starts capture from local consent/live switches,
creates its own deterministic publication/receive contracts and automatically
subscribes to every available remote offer while speaker consent permits it.
`ba_audio_receiver` polls all authenticated peer catalogues every 5 seconds;
source registration does not publish a Manager announcement. A subscriber sends
`subscribe`, the publisher admits it and starts the provider Media Session,
then the receiver creates its endpoint; the publisher generates the WebRTC offer.
No general Manager playback-request dispatch is in this path. UI delivery is
change-filtered, but DeviceWeb gathers snapshots every 300 ms and native hosts
poll every 1500 ms; an optional CLI monitor also queries peer capabilities.
The Windows shared profile still does not configure this native audio worker.
This was a source audit, not a new physical audio test or a protocol change.

Current shared-profile control packets still route via Reception (`send/3` in
`ba_buffee_control`); pairwise authenticated protocol sessions are not physical
direct sockets. Direct control transport is a separate unfinished change. Borrow
OTP's targeted messaging and pg-style eventual membership/scopes, not `global`'s
full-partition coupling or trusted Distributed Erlang. Keep the existing signed
wire/credential boundaries until an explicit admission migration is designed.


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
6. **One machinery for rights.** Entrance is now holding the link, and Ban is
   the signed policy's `removed` list (2026-11-17); there is no passport. Session privileges, Device gates and Device settings share one
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
