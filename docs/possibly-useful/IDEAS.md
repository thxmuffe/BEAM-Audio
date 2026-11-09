# Ideas for later

These are deferred possibilities, outside the [active architecture plan](../PLAN.md).
They add no prerequisites or implementation commitments.

The repository now uses three buckets for non-active concepts:
- [discarded-ideas/](../discarded-ideas/README.md): intentionally rejected for the
  current architecture and not expected to return without a fresh decision.
- [possibly-useful/](README.md): ideas worth revisiting later,
  but not part of the active implementation path.
- [old-ideas/](../old-ideas/README.md): retained as historical provenance only.
  This is not a planning area and should not be used as guidance for current work.

## Git-backed configuration history — deferred

Requested 2026-11-09 as a possible later enhancement: a Device-local Git
repository for readable configuration versions, meaningful commit names,
comparison, browsing older settings, and selectively applying past settings as a
new authorized change. OTP would remain the configuration/permission owner;
Git would provide storage/history, not runtime rollback or Swarm resurrection.
No remote repository/account would be required. This is explicitly outside the
current simple bounded file-based resume/undo/redo implementation. Revisit only
when richer historical selection is wanted; no Git dependency or integration now.

## Longer-term directions

- Discrete multichannel/home cinema, spatial/object/ambisonic rendering,
  upmixing and video lip-sync: [cinema vision](../discarded-ideas/CINEMA_SYSTEMS.md).
- DSP algorithms, room EQ, crossovers and acoustic feedback/calibration during
  music: [earlier idea record](../discarded-ideas/PLAN-before-swarm-2026-11-08.md#audio-and-calibration-ideas--recorded-2026-10-30).
  The current plan's test Workers and local multi-stream mixer do not require
  implementing these systems.
- Federation, recursive groups, Director failover and large-event routing/time
  distribution: [coordination discussion](audio-system-trust-and-coordination.md).
  Several Desks for one Swarm remain in current step 5.
- Additional native backends, lossless formats, general capability negotiation,
  AES67/PTP interoperability, browser work and new platforms:
  [earlier provider proposal](../discarded-ideas/BEAM_Audio_Codex_Implementation_Spec.md)
  and [historical plan](../discarded-ideas/PLAN-before-swarm-2026-11-08.md).
- Accounts, paid tiers, turnkey hardware and managed services:
  [business ideas](../discarded-ideas/BUSINESS_MODEL.md). Prices, capacities and feature
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

## Publish/default-output wording and icon — UI follow-up

User feedback during 2026-11-09 testing: “broadcast” and its antenna icon do not
communicate the default-system-output Source well. Revisit wording and symbol
consistently across platforms/CLI when doing the next UI pass. Do not rename wire
fields or introduce competing capability names in the monitoring increment.
