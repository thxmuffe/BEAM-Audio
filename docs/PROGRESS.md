# Current implementation and validation

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
