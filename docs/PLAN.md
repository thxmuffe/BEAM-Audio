# Current plan

## Current increment

Web UI cleanup and real parallel Session tabs are implemented. Each tab has
independent membership, chat, audio consent/history and clock workers. Device
identity, saved contacts and Reception connections are shared. Native Mac/iOS
WebViews now load the same outer Session-tab shell and route its tab operations
through the existing runtime bridge. The user will inspect the layout and test
actual concurrent audio manually. App packaging/installation and Reception
deployment are not part of this increment.

## Devices layout

Audio contains local switches; Session participants and approval actions are in
Devices, above saved Devices and inline expandable groups. Automatic invitation
delivery/drag-to-invite was explicitly deferred until after this layout. Saved
contacts currently have identity/name only; there is no device invitation inbox.
The existing Invite flow generates a link for manual sharing, not automatic delivery.

## Next increments

1. Clarify desktop Device slot reuse and visible Owner/Chef identity. Revisit
   physical/MAC-address identity requirements without assuming a redesign.
2. Investigate iPhone capture block limits, overlapping packets, missed packet
   targets and output closure/recovery. Qualify actual listening and timing.
3. Connect the standalone Windows Web Device to existing native audio adapters.
   It currently starts control but does not configure a native audio Worker.
4. Add useful bounded timestamped diagnostics; current counters are cumulative
   and cannot reconstruct an overnight event timeline.

Keep Reception's versioned transport contract stable. No Reception deployment
is needed for client role/approval changes. Rebuild/restart the affected Web
Device to load backend changes; refresh assets for frontend changes. Native app
builds and installations are outside this UI increment.

Use [current progress and limits](PROGRESS.md), [architecture](ARCHITECTURE.md)
and [networking research](AUDIO_NETWORKING.md). No replacement audio SDK or
multicast/relay topology has been selected.

Web UI increment: Devices is the default first tab, My Device second, Chat last
with an unread count. Offline row menus remain accessible. Kick removes admission
and invalidates the old passport but permits a fresh invitation-based join; Ban
is not implemented. Playback/Record use the existing local audio controls; Calibrate
and DSP are unavailable placeholders. System audio moves to the Session header.
My Device shows participation and provides Chef requests and self-demotion (an
online Owner must apply a non-Owner Chef’s signed demotion request). Internal
names are unchanged. Security architecture and choppy playback remain next steps.
No native app build or visual acceptance is included.
