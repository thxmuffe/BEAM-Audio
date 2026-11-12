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
manual UI acceptance remain unverified. Native hosts retain their existing single
Session bridge; this tab shell is web-only.

Invite toolbox fix: any authorized participant may display and forward its
existing reusable invitation; ownership is not required to share an existing
link. Newly saved memberships preserve that link across rejoining. Old saved
Guest memberships without a link need an invitation-based rejoin to recover it.
Owner-only administration and targeted readmission remain unchanged.
