# Current architecture

BEAM Audio owns reusable control, audio processing, native adapters, services and
DSP code. OpenSound owns commercial UI and packaging. Core builds independently.

Use local OTP supervision, messaging, monitors and process groups. Cross-device
operations use authenticated, scoped protocol messages; ordinary Buffee Devices
never obtain Distributed Erlang access. Reception authenticates connections and
routes opaque envelopes. It does not administer membership or interpret audio.

Owner is trusted administration; Chef/Guest are participation roles. Process
placement confers no ownership. Saved identity and policy survive ordinary Leave
and shutdown. Destroy is explicit. See [membership](BUFFEE_MEMBERSHIP.md).

Erlang owns the shared clock reference, every packet's broadcaster-assigned
presentation target and correction/buffering policy. Native adapters supply
sample blocks, source format, monotonic capture timestamps and device timing.
Approved isolated third-party media engines execute operations under Erlang
control. Replace the default path only after playback, recovery and timing
measurements. Never reconstruct missing targets or silently reschedule packets.

DSP interfaces and reference implementations remain in BEAM Audio. Keep optional
backends isolated and avoid speculative abstractions. Swift hosts retain OS
permissions and identity storage while reusing the web UI and shared BEAM APIs.

Current contracts: [clock](BUFFEE_TIME.md), [audio engines](AUDIO_ENGINE_INTERFACE.md),
[streams](BUFFEE_STREAMS.md), [jobs](BUFFEE_JOBS.md), [builds](BUILDING.md).

## Parallel local Sessions

`ba_sessions` owns the web tab manifest. The existing default Session keeps its
registered names and saved files. Additional Sessions use `ba_session_sup` OTP
trees; `ba_session_scope` resolves local worker names, ETS tables and saved
state under `sessions/<BuffeeId>/`. OTP ancestor metadata supplies the scope
to supervised children; explicitly spawned helpers inherit it. Term names use
OTP `global` registration in the unnamed VM, without enabling Distributed Erlang.

Identity and contacts belong to the Device. `ba_desk_connections_sup` shares one
`ba_relay` connection per URL, dispatching mailboxes to the owning Session and
combining presence watches. Closing a Session detaches only its mailboxes and
sends a scoped signed offline announcement. It never closes another Session’s
connection or revokes ownership. The web shell keeps independent same-origin
Session documents alive; UI navigation does not own audio process lifetime.
