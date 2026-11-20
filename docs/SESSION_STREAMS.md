# Audio Sources, Streams and Subscriptions

A Source describes published audio, its format and incarnation. A Subscription
is a receiver's current intent; a Media Session is a temporary transport attempt.
Keep their lifetimes separate. The shared runtime negotiates formats, permissions,
local Contracts/consent and authenticated session context before starting media.

Microphone contribution is available to Guests with local consent. Other Sources
require Chef permission. Ownership itself does not enable capture. The shared
receiver validates both local publication and remote source catalogues.

The current path carries PCM over isolated WebRTC transports, with each packet
independently carrying its broadcaster-assigned shared playback target. Erlang
owns target calculation, clock conversion, eligibility, buffering and correction.
The reference Mixer requires compatible source rate and clock. It renders at the
approved target, or records explicit missed/invalid/overlapping/output failures.
No adaptive backend may silently select replacement targets.

Pause, unsubscribe, consent withdrawal, Contract revocation and source incarnation
changes fence affected media. Recovery negotiates a fresh eligible attempt instead
of replaying stale buffers. Subscription intent is scoped to the live Buffee.
No PID, socket, device deadline or live buffer is durable membership evidence.

The app Device Handler starts eligible audio Workers from desired settings.
Speaker receive, microphone capture and system capture are separate actions.
The Web UI submits commands; the browser itself does not carry audio.

See [engine interface](AUDIO_ENGINE_INTERFACE.md), [clock](BUFFEE_TIME.md),
[ownership](BUFFEE_MEMBERSHIP.md) and [current validation](PROGRESS.md).
