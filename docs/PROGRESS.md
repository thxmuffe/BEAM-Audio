# Current implementation and validation

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
