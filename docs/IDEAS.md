# Ideas for later

These are deferred possibilities, outside the [active nine-step Swarm
plan](PLAN.md). They add no prerequisites or implementation commitments.
Original discussions are preserved in [old-ideas/](old-ideas/README.md).

## Longer-term directions

- Discrete multichannel/home cinema, spatial/object/ambisonic rendering,
  upmixing and video lip-sync: [cinema vision](old-ideas/CINEMA_SYSTEMS.md).
- DSP algorithms, room EQ, crossovers and acoustic feedback/calibration during
  music: [earlier idea record](old-ideas/PLAN-before-swarm-2026-11-08.md#audio-and-calibration-ideas--recorded-2026-10-30).
  The current plan's test Workers and local multi-stream mixer do not require
  implementing these systems.
- Federation, recursive groups, Director failover and large-event routing/time
  distribution: [coordination discussion](old-ideas/audio-system-trust-and-coordination.md).
  Several Desks for one Swarm remain in current step 5.
- Additional native backends, lossless formats, general capability negotiation,
  AES67/PTP interoperability, browser work and new platforms:
  [earlier provider proposal](old-ideas/BEAM_Audio_Codex_Implementation_Spec.md)
  and [historical plan](old-ideas/PLAN-before-swarm-2026-11-08.md).
- Accounts, paid tiers, turnkey hardware and managed services:
  [business ideas](old-ideas/BUSINESS_MODEL.md). Prices, capacities and feature
  claims there are proposals, not a product specification.

## Receiver accountability and periodic contract reports

Requested 2026-11-04. Not part of the current implementation increment.

Each node bears the burden of demonstrating that it followed the broadcaster's
per-packet playback contract. Once per hour, report all lost packets, missed
playback targets and other contract violations, with evidence and explicit
measurement limits. No silent retiming, concealed failure or claims of compliance
based only on successful packet reception. Preserve enough packet/target identity
to account for outcomes. Define what can actually be proved at the software output
boundary separately from physical speaker timing. Periodic collection, retention,
report delivery and enforcement policy remain future design work; implement none
of that periodic vetting now.

## Lossless diagnostic audio

Requested 2026-11-04. Add a lossless/PCM option for listening comparisons under
the same per-packet target contract, so lossy codec artifacts cannot be mistaken
for scheduling distortion. Codec choice is separate from SRTP encryption, which
does not alter decoded audio samples. Format negotiation, bandwidth limits and
cross-platform support need a separate increment; the current wire audio remains
Opus. Do not remove transport encryption for this experiment.

## Work already promoted to implementation

Subscription restoration is no longer a future idea: the single-slot baseline
is implemented and has user-reported iPhone evidence in [PROGRESS.md](PROGRESS.md).
Current step 6 expands it into independent subscriptions; fresh sessions and
current permission checks remain required. See the [iPhone guide](apps/iOS/README.md)
for usage and platform limitations.
