# Audio Sources, Streams and Subscriptions

A Source describes published audio, its format and incarnation. A Subscription
is a receiver's current intent; a Media Session is a temporary transport attempt.
Keep their lifetimes separate. The shared runtime negotiates formats, permissions,
local Contracts/consent and authenticated session context before starting media.

Microphone capture follows the local Device's consent. System audio publication
also requires the Session's `on_air` privilege. Both use the same signed
publication note. It contains the source descriptor and incarnation that a
listener uses to start an addressed subscription. A newer withdrawal removes
the source and prevents delayed notes from reviving it. Active sources refresh
their publications every 10 seconds, and a receiver expires a source after
30 seconds without an update. The first local publication also requests a
meter refresh through that same note.

The native engine sends FLAC over SRTP on ICE connections. Stream offers name
`engine_flac_srtp_v2`. Stream setup includes the sender's packet index and a
Session time anchor for the RTP sample positions. Erlang owns eligibility,
stream lifetime and timing policy. The engine buffers, recovers and decodes
packets, then schedules playback from the sample position and the Session's
Response time. The speaker mixer averages contributions from enabled inputs
to keep the final mixed signal in full-scale range. The speaker meter measures
that final signal.

Pause, unsubscribe, consent withdrawal, Contract revocation and source incarnation
changes fence affected media. Recovery negotiates a fresh eligible attempt instead
of replaying stale buffers. The sender accepts a new attempt for the same
authenticated Subscription and current Contract without waiting for the old ICE
connection to fail. A failed signaling send can retry on the next audio tick
when Reception reconnects. Subscription intent is scoped to the live Session.
No PID, socket, device deadline or live buffer is durable membership evidence.

The app Device Handler starts eligible audio Workers from desired settings.
Speaker receive, microphone capture and system capture are separate actions.
The Web UI submits commands; the browser itself does not carry audio.

See [audio engine](AUDIO_ENGINE.md), [clock](SESSION_TIME.md),
[Session policy](SESSION_MEMBERSHIP.md) and [current validation](PROGRESS.md).
