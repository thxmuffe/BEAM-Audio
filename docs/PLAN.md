# Current plan

## Current increment

Web UI cleanup and real parallel Session tabs are implemented. Each tab has
independent membership, chat, audio consent/history and clock workers. Device
identity, saved contacts and Reception connections are shared. The user will
inspect the layout and test actual concurrent audio manually. No native app
rebuild or Reception deployment is part of this increment.

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
