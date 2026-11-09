# BEAM Audio terminology

These are the canonical component names for the core and the OpenSound App.
Names describe responsibilities, not a promise that every component has a
separate module/process or that every platform implementation is complete.

| Component | Meaning | Current implementation / boundary |
| --- | --- | --- |
| Swarm | Logical community of cooperating Devices. | Stable Swarm identity and membership; independent of live processes. |
| Device | Autonomous participant with its own Erlang runtime and resources. | Local supervision and resource ownership; membership grants no arbitrary remote execution. |
| Desk | Authentication, introduction and message routing. | Phoenix/WebSockets, `ba_reception_sessions`, `ba_swarm_desks`, `ba_relay`. A Desk is not the Swarm authority and does not carry audio. |
| Device Identity | Permanent cryptographic identity. | Ed25519; platform secure storage and `ba_device_store:identity/0`. Not an OTP node name or a Passport. |
| Passport | Persistent Swarm membership credential. | `ba_swarm_passport`, `ba_swarm_membership`; fresh authorization and revocation checks are still required. |
| Contract | Permissions, responsibilities and resource boundaries. | Locally checked grants, consent and resource limits; not connection liveness. |
| Director | Coordinates Swarm activity and offers Jobs. | OTP control/job ownership in `ba_swarm_control` and `ba_swarm_job`; cannot remotely spawn another Device's Workers. |
| Device Handler | Manages local consent, Capabilities and Workers. | `ba_device_handler` (`gen_server`), `ba_device_sup`, `ba_device_worker_sup`. |
| Worker | Supervised process performing a local task. | Local OTP processes, using native engines/bindings where appropriate. Not a separate Erlang node. |
| Capability | Description of available resources and their limits. | Device Handler advertisements, including local consent and implementation limits. |
| Job | Voluntarily accepted task with a defined lifecycle. | `ba_swarm_job`, Director offers and Device Handler acceptance, completion, cancellation and expiry. |
| Source | Producer of audio with a persistent identity. | Device identity plus stable `source_key`; `ba_audio_source`. Recreating its process/publication does not change that logical identity. |
| Stream | Audio publication carrying payloads and playback targets. | Source publication incarnation/descriptor and packets; `ba_audio_stream_protocol`, PCM or Opus. Pause need not end a publication. |
| Subscription | Persistent intent to receive a Source. | `ba_subscription` declarative records, owned at runtime by `ba_audio_receiver`. Not a transport connection or permission to play. |
| Media Session | Temporary connection transporting audio. | `ba_media_session`; WebRTC data channel for PCM or RTP audio track for Opus. Bound to a fresh authorized attempt/lease. |
| Mixer | Combines independently scheduled audio locally. | `ba_audio_mixer` process and `ba_audio_mix` pure Erlang operations. |
| Stream Handler | Replaceable media protocol and transport implementation. | `ba_stream_handler`, `ba_stream_handler_pcm`, `ba_stream_handler_opus`. |
| Audio Engine | Decoding, buffering, scheduling and playback. | GStreamer/native APIs and `ba_audio_engine` bindings. Erlang owns shared timing/correction policy; engines execute approved targets and report timing. |
| Swarm Clock | Shared timeline and local clock synchronization. | `ba_swarm_clock`, its OTP supervisor and existing filter/mapping/sync helpers, `ba_sntp`. No automatic authority succession. |
| Presentation Target | Publisher-assigned playback time for each packet. | Existing `playback_time` / `target_output_time_ns` fields and `ba_audio_rtp_time`; never inferred from neighbouring packets. |
| Playback Offset | Swarm-wide configurable delay before presentation. | Revisioned authorized policy owned by the Swarm Clock; existing `offset_ms` API. The planned audio UI may label it “Swarm Offset.” |
| OpenSound App | Cross-platform user interface. | SwiftUI/wxErlang in the separate OpenSound repository; submits commands and displays core state. |

Use **Device** for a participant. Use **OTP node**, **Distributed Erlang** or
**trusted cluster** only when discussing those actual mechanisms. Historical
trusted-cluster code is not a synonym for the current Swarm architecture.
“Active Player,” “broadcaster” and “publisher” may describe a Source's activity;
they do not introduce additional component types. Use **Playback Offset**, rather
than “sync delay,” for the current shared policy. Protocol field spellings remain
versioned interfaces and need not reproduce display capitalization.

[Naming and migration](NAMING.md), [current roadmap](PLAN.md).
