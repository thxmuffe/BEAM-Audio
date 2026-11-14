---
title: OpenSound Privacy Policy
permalink: /privacy/
---

# OpenSound Privacy Policy

**Last updated: 14 November 2026**

**Controller and developer:** Paavo Penttilä (individual developer, Finland)  
**Privacy contact:** [thxmuffe@hotmail.com](mailto:thxmuffe@hotmail.com)

OpenSound is an application for connecting devices in audio-sharing sessions (called Buffees). This policy describes the personal information processed when you use the app and its associated Reception service.

## Information used

- **Device identity and settings:** OpenSound generates a cryptographic device identity and stores locally the information needed to recognize your device, your permissions, configuration and contacts.
- **Session information:** To connect participants, OpenSound handles device identifiers, device display names, invitations, participant roles, connection information and other session-control messages.
- **Audio:** When enabled by the device user, OpenSound processes microphone or selected audio for transmission to other authorized participants. Other participants can hear or otherwise handle audio they receive. Audio transmission can depend on device permissions and operating-system restrictions.
- **Chat:** Messages you send are delivered to session participants and may be held in bounded local history on participating devices.
- **Connection metadata:** Devices and the Reception service handle information needed to establish and route connections, which may include IP addresses, connection times and technical diagnostics.

## How it is used

This information is used to provide device discovery, authenticated connections, audio sharing, synchronization, messaging, security and troubleshooting. Microphone and audio sharing are controlled by local device permissions and applicable operating-system permissions.

The app is not designed to use personal data for advertising or behavioral profiling.

## Where information goes

OpenSound uses a Reception service to introduce devices and relay some control messages. The Reception can process routing information and the control messages it forwards. **Control messages are not necessarily end-to-end encrypted from the Reception operator.** Network transport uses encryption for public Reception connections.

Audio uses device-to-device transport where supported. Depending on transport and network conditions, connection paths may vary. Other session participants necessarily receive the information you choose to share with them.

The Reception is currently hosted by an external hosting provider. Its provider may process infrastructure and security logs under its own service arrangements. Hosting and diagnostic retention settings must be confirmed before the first public release.

## Storage and retention

Device identity and selected application data are retained locally until removed, the app's data is erased or the relevant settings are reset. Session chat is maintained as bounded local history rather than a central chat-history database. Other participants may keep information they receive independently.

The application does not currently offer a central user-account database. Reception is intended to route active connections rather than store offline chat. Temporary service logs and hosting-provider retention may still apply.

## Legal basis and your rights

Processing necessary to provide a session you initiate or join is generally based on providing the requested service. Where required, separate permission or consent is obtained for protected device capabilities, including microphone access. Essential security and operational processing may rely on legitimate interests, subject to applicable law.

If EU/EEA data-protection law applies, you may have rights to access, correct or erase personal data, object to certain processing, restrict processing, or lodge a complaint with a supervisory authority. Contact **thxmuffe@hotmail.com** about these rights. Because some data is held solely on participants' devices, the developer may not have access to all data exchanged in a session.

## Children

OpenSound is not designed to solicit personal information from children. Users should only share audio and messages they are authorized to share.

## Changes

This policy may be updated as OpenSound evolves. Updates will be published at this location with a revised date.

---

**Release verification note:** This policy describes the currently documented architecture. Before public App Store distribution, the developer must verify the exact shipped application's third-party SDK behavior, Reception hosting logs and retention, and the final App Store privacy declarations.
