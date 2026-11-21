# Current architecture

BEAM Audio owns reusable control, audio processing, native adapters, services and
DSP code. OpenSound owns commercial UI and packaging. Core builds independently.

## Shared Device model

CLI, Inspector and web UI submit commands to the shared Device API. DeviceWeb
and the CLI route Session commands through `ba_sessions`; Device configuration
and persistent settings belong to the backend, not each client. Clients attached
to the same running Device share that memory. An explicitly created observer is
another ordinary Device with its own identity and memory.

Control and rights requests use one pipeline: authenticate, authorize, approve,
execute. `ba_device_request` delegates all approval decisions to the serialized
`ba_device_config` owner. Rights requests currently wait on the signed Session
board; resource requests wait in Device configuration. Unifying pending state
and replacing replicated permission policy with requester-held signed grants
remain planned work. Local execution tokens enforce approved resource use.

**Audio stream control** is Erlang's configuration and supervision of native
streams. Native code owns capture, codecs, media transport and playback.

Use local OTP supervision, messaging, monitors and process groups. Cross-device
operations use authenticated, scoped Session messages. Reception authenticates
connections and routes opaque envelopes. Session policy and privileges live
with the Devices. A join certificate proves admission, and signed policy
records `grant`, `on_air` and `end_session` privileges. Saved Device identity
and policy survive ordinary Leave and shutdown. See [Session admission and policy](SESSION_MEMBERSHIP.md).

Each Device derives its own UTC mapping. Erlang owns Session presentation
policy and stream lifecycle. Native code uses sample-position timestamps to
schedule playback and owns FLAC, SRTP, buffering and output. Only control,
signalling, timing metadata and bounded diagnostics cross the BEAM boundary.
See [Session time](SESSION_TIME.md), the [audio engine](AUDIO_ENGINE.md) and
[Session streams](SESSION_STREAMS.md).

Routine work targets relevant peers and active streams. A CLI Inspector can
explicitly collect wider Session diagnostics. Relaying across neighbours at
large Session sizes remains planned work. Swift hosts keep OS permission and
identity handling and reuse the web UI and the shared BEAM APIs.

## Parallel local Sessions

`ba_sessions` owns the web tab manifest. The existing default Session keeps its
registered names and saved files. Additional Sessions use `ba_session_sup` OTP
trees; `ba_session_scope` resolves local worker names, ETS tables and saved
state under `sessions/<SessionId>/`. OTP ancestor metadata supplies the scope
to supervised children; explicitly spawned helpers inherit it. Term names use
OTP `global` registration in the unnamed VM, without enabling Distributed Erlang.

Identity and contacts belong to the Device. `ba_desk_connections_sup` shares one
`ba_relay` connection per URL, dispatching mailboxes to the owning Session and
combining presence watches. Closing a Session detaches only its mailboxes and
sends a scoped signed offline announcement. It never closes another Session’s
connection or revokes ownership. The web shell keeps independent same-origin
Session documents alive; UI navigation does not own audio process lifetime.

## Device consent (implementation in progress)

Permission settings belong to one Device-owned `ba_device_config`, not Session
supervision trees. Every Session resolves that shared owner. Session broadcast
intent stays in its own `ba_session` process. Session leave/rejoin has no authority
to copy or grant Device permissions. The current-profile permission owner starts
with all grants OFF and refuses history changes that would grant a permission.
Final resource enforcement and acknowledged revocation are planned, not complete;
see PLAN.md and the latest security entry in PROGRESS.md.
