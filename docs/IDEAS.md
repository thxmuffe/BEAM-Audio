# Ideas for later

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

## Restore audio subscriptions after iPhone resume/relaunch

Requested 2026-11-04 as a feasibility question; not implemented yet. Save the
user's intended source/profile and playback-enabled state in the core runtime's
persistent settings. Use stable source identity rather than process/session IDs
or a publication ID that changes when broadcasting restarts. On resume/relaunch,
reconnect to the saved cluster, reacquire the shared clock, rediscover the source
and negotiate a fresh subscription before restoring playback. Invalidate old
native buffers and expired targets; only fresh packets may play at their own
authoritative targets. Unsubscribe/Stop/Forget must update or clear saved intent.
If the source is absent, show waiting/unavailable rather than fabricate success.
Use existing OTP supervision/discovery; iOS supplies lifecycle notifications only.
Apple's UI snapshot is an image, not a saved network/media session. This work is
separate from background-audio entitlement/session policy.
