# Old ideas and superseded plans

Archived/reconciled 2026-11-08. Preserve these documents as design history and
possible future inspiration. Their original instructions, priorities, dates,
product promises and performance claims are not current requirements or proof
of implementation. Nothing here overrides the [active nine-step plan](../PLAN.md).
The [future ideas list](../IDEAS.md) identifies possibilities worth revisiting.

## Archive contents

| Document | Why it is here |
| --- | --- |
| [Previous PLAN.md body](PLAN-before-swarm-2026-11-08.md) | Competing “current” increments, earlier implementation orders, research milestones and calibration ideas. |
| [Simultaneous playback subplan](SIMULTANEOUS_PLAYBACK_PLAN.md) | Earlier five-step sequence and timing checkpoints; useful evidence/history, no longer the active roadmap. |
| [Media-provider specification](BEAM_Audio_Codex_Implementation_Spec.md) | Proposed provider, three backends and general negotiation that the current incremental architecture does not require. |
| [Trust and coordination discussion](audio-system-trust-and-coordination.md) | Exploratory recursive groups, RabbitMQ and assignment/reconnect alternatives; no broker was selected. |
| [Risk/security proposal](RISK_MANAGEMENT.md) | Conflicting VIP/Crowd trust model, mDNS-first roadmap and mandatory native policy; threat concerns remain useful input, proposed solutions are not adopted. Legal assertions need independent review if revisited. |
| [Cinema vision](CINEMA_SYSTEMS.md) | Spatial rendering, multichannel cinema, DSP and calibration ambitions beyond the nine steps. |
| [Business/product ideas](BUSINESS_MODEL.md) | Speculative tiers, pricing, hardware and capacity claims; not current capabilities or commitments. |
| [Original handover](notes%2020261026.md) | Early Finnish vision/chat-first instructions and future scaling concepts. |

## Conflicts found and resolution

| Conflicting or ambiguous ideas | Resolution in the active plan |
| --- | --- |
| Trusted cross-device OTP, unrestricted RPC/remote workers, and VIP/Crowd tiers versus independent untrusted Devices | OTP supervision stays local; device boundaries use authenticated, allowlisted operations. Existing trusted code is a migration baseline, never a guest security boundary. |
| “Cluster” preferred over “Swarm” in older product guidance | Use Swarm/Desk/Offset for new design; preserve internal names, identity storage and protocols until deliberate migration. |
| Several “current/next” steps: Windows styling, volume, timing, cinema, repository extraction and DSP | One active nine-step sequence. Preserve completed work and validation limits in PROGRESS.md; older resume instructions stay here. |
| RTP anchors/adaptive retiming versus independent packet targets | Every packet retains its broadcaster-assigned target; unsupported execution fails explicitly. Physical speaker timing still requires measurement. |
| GStreamer deferred, NetEq-only default, and later GStreamer integration | Preserve current handler/engine boundaries and the working baseline; no backend replacement is scheduled by an old proposal. AUDIO_ENGINE_INTERFACE.md describes the packet executor and platform limits. |
| A new provider/negotiation framework or three backends required first | Reuse existing owners and supervisors. The next integrated proof is one authorized non-audio job after secure messaging. |
| Durable identity seems deferred until after secure messaging | Step 1 defines minimum identity/session permissions; step 2 reuses existing identity and fresh authentication. Full Passport/rejoin/multi-Desk behavior follows in step 5. |
| Multiple audio streams precede the clock-control migration | Step 6 can exercise the trusted baseline; unrestricted-device migration is incomplete until all required cross-device control has moved off OTP distribution. |
| Several Desks confused with federation | Step 5 introduces devices to one Swarm through several Desks. Cross-Swarm federation remains deferred. |
| Persisted subscriptions treated as unconditional playback authority; restoration listed as a future idea despite later implementation | Retain logical intent separately from sessions; check current permissions on restoration. Baseline restoration already has implementation/user evidence; step 6 expands the single slot. |
| Large-scale clock trees, brokers, native limiters, mic workflows and spatial/DSP infrastructure presented as immediate requirements | Retain relevant security goals and local resource consent in the current contract. Specific future mechanisms and scale targets require their own later decisions. Step 6 still includes its explicitly approved bounded mixing/limiting. |

## How to use historical records

Date-stamped PROGRESS.md entries remain intact apart from repaired links.
Architecture decisions and interface/usage documents stay at their established
paths because they explain existing code. Their older cross-device OTP and
anchor-based timing assumptions do not authorize new Swarm behavior; the active
plan and current per-packet timing rule take precedence. Step 1 must map those
dependencies and settle concrete message, authority and lifecycle contracts.
This cleanup does not claim that step 1 or the security migration is complete.
