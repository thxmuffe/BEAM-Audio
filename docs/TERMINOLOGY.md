# BEAM Audio terminology

## Buffee vocabulary — review draft, 2026-11-11

The following product vocabulary is ready for user review. Documentation changes
only: app, runtime, protocol and service implementation must wait for the user's
explicit “go.” This draft supersedes older product wording below; the technical
table records existing implementation names, not completed migration.

| Previous term / concept | Proposed product term | Meaning |
| --- | --- | --- |
| Swarm | **Buffee** | An active pool of voluntarily participating Devices and offered work. Devices come and go; remembering an invitation should make returning easy. The spelling connects buffet with audio buffer. |
| Ordinary participating Device | **Guest** | May provide speaker output, consented microphone access and computing capacity. Cannot broadcast music as a Chef. |
| Broadcasting permission / active player | **Chef** | A Device with Guest capabilities plus permission to broadcast music. Guest and Chef are the two proposed Device statuses. |
| Director / coordinator | **Manager** | Coordinates work and offers Jobs. A coordination role, separate from Guest/Chef status; it grants no ownership or override of Device consent. |
| Available computing capacity | **Hunger** | The buffet metaphor for voluntarily offered computing capacity. Keep “computing capacity” available as the precise description; no new scheduler is implied. |
| Swarm Offset / Playback Offset | **Response time** | The configured shared delay before scheduled playback. Renaming does not change timing, units, packet targets or scheduling policy. |
| Former `Desk` / `Reception desk` | **Reception** | Authenticates Devices, introduces participants and routes control messages. It does not own the Buffee, choose its Manager or carry audio. |

Use **Reception** throughout prose and future UI. Do not introduce “Maître d’” as
another role. Existing module names, directories, URLs, commands, environment
variables and signed/wire fields remain unchanged until an explicit migration.

Chef permission extends what that Device may contribute; it cannot enable another
Device's microphone, speaker or computing resources without local consent. An
enabled microphone is available for consented requests, not unconditional remote
access. Guest microphone contribution must remain distinct from Chef music
broadcasting; the exact permission mapping is not implemented by this draft.

Unresolved before behavior implementation: who may elevate a Guest to Chef,
who may coordinate/publish which Jobs, Manager startup/replacement, whether shared
kick/ban authority is needed beyond local exclusions, and how all Devices return
after a complete shutdown. Existing Captain authority has no automatic new name
or replacement in this proposal. Do not silently equate Captain with Chef or Manager.

The web app is the primary app and must be updated first after approval. Windows
remains wxErlang and should match the web app's appearance and behavior as closely
as platform requirements allow. Current authorized platform scope is web app,
Windows app and Reception; Apple app implementation is not included.

## Existing technical components

These are the existing technical component names for the core and OpenSound App.
Names describe responsibilities, not a promise that every component has a
separate module/process or that every platform implementation is complete.

| Component | Meaning | Current implementation / boundary |
| --- | --- | --- |
| Swarm | Temporary gathering of cooperating Devices. | Fresh ID per creation; creator is Captain/authority/Director for its lifetime. End removes its state; no election or restoration. |
| Device | Autonomous participant with its own Erlang runtime and resources. | Local supervision and resource ownership; membership grants no arbitrary remote execution. |
| Reception | Authentication, introduction and message routing. | Phoenix/WebSockets, `ba_reception_sessions`, `ba_swarm_desks`, `ba_relay`. A Reception is not the Swarm authority and does not carry audio. |
| Device Identity | Permanent cryptographic identity. | Ed25519; platform secure storage and `ba_device_store:identity/0`. Not an OTP node name or a Passport. |
| Passport | Membership credential for a live Swarm. | `ba_swarm_passport`, `ba_swarm_membership`; memory-only, with fresh authorization/revocation checks. |
| Contract | Permissions, responsibilities and resource boundaries. | Locally checked grants, consent and resource limits; not connection liveness. |
| Director | Coordinates Swarm activity and offers Jobs. | OTP control/job ownership in `ba_swarm_control` and `ba_swarm_job`; cannot remotely spawn another Device's Workers. |
| Device Handler | Manages local consent, Capabilities and Workers. | `ba_device_handler` (`gen_server`), `ba_device_sup`, `ba_device_worker_sup`. |
| Worker | Supervised process performing a local task. | Local OTP processes, using native engines/bindings where appropriate. Not a separate Erlang node. |
| Capability | Description of available resources and their limits. | Device Handler advertisements, including local consent and implementation limits. |
| Job | Voluntarily accepted task with a defined lifecycle. | `ba_swarm_job`, Director offers and Device Handler acceptance, completion, cancellation and expiry. |
| Source | Producer of audio with a persistent identity. | Device identity plus stable `source_key`; `ba_audio_source`. Recreating its process/publication does not change that logical identity. |
| Stream | Audio publication carrying payloads and playback targets. | Source publication incarnation/descriptor and packets; `ba_audio_stream_protocol`, PCM or Opus. Pause need not end a publication. |
| Subscription | Intent to receive a Source within a live Swarm. | `ba_subscription` declarative records, owned at runtime by `ba_audio_receiver`. Not a transport connection or permission to play. |
| Media Session | Temporary connection transporting audio. | `ba_media_session`; WebRTC data channel for PCM or RTP audio track for Opus. Bound to a fresh authorized attempt/lease. |
| Mixer | Combines independently scheduled audio locally. | `ba_audio_mixer` process and `ba_audio_mix` pure Erlang operations. |
| Stream Handler | Replaceable media protocol and transport implementation. | `ba_stream_handler`, `ba_stream_handler_pcm`, `ba_stream_handler_opus`. |
| Audio Engine | Decoding, buffering, scheduling and playback. | GStreamer/native APIs and `ba_audio_engine` bindings. Erlang owns shared timing/correction policy; engines execute approved targets and report timing. |
| Swarm Clock | Shared timeline and local clock synchronization. | `ba_swarm_clock`, its OTP supervisor and existing filter/mapping/sync helpers, `ba_sntp`. No automatic authority succession. |
| Presentation Target | Publisher-assigned playback time for each packet. | Existing `playback_time` / `target_output_time_ns` fields and `ba_audio_rtp_time`; never inferred from neighbouring packets. |
| Playback Offset | Swarm-wide configurable delay before presentation. | Revisioned authorized policy owned by the Swarm Clock; existing `offset_ms` API. The planned audio UI may label it “Swarm Offset.” |
| OpenSound App | Cross-platform user interface. | SwiftUI/wxErlang in the separate OpenSound repository; submits commands and displays core state. |

Contacts and named groups belong to the Device and survive gathering end. Saving
a contact never grants permission. Subscription intent survives receiver recovery
within the gathering, but is forgotten when the gathering ends.

Use **Device** for a participant. Use **OTP node**, **Distributed Erlang** or
**trusted cluster** only when discussing those actual mechanisms. Historical
trusted-cluster code is not a synonym for the current Swarm architecture.
“Active Player,” “broadcaster” and “publisher” may describe a Source's activity;
they do not introduce additional component types. Use **Playback Offset**, rather
than “sync delay,” for the current shared policy. Protocol field spellings remain
versioned interfaces and need not reproduce display capitalization.

[Naming and migration](NAMING.md), [current roadmap](PLAN.md).
