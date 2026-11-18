# Shared audio runtime

Shared Erlang modules in `src/` own publication, metering, interpretation,
subscription/Contract lifetimes, timing policy and backend lifecycle. Adapters
under `adapters/macOS`, `adapters/iOS` and `adapters/Windows` bind platform APIs,
provide buffers/formats/monotonic timestamps and execute approved output work.
Platform-specific Erlang adapters live alongside their native bindings.

Handlers under `handlers/` supply isolated media transport. The current PCM path
uses WebRTC; optional native engines remain isolated experiments until justified
by timing, playback and recovery evidence. No library may silently replace a
broadcaster's independently assigned target on any packet.

Sources retain explicit formats. The reference Mixer currently needs compatible
rate and clock; unsupported formats and missed/overlapping/output failures remain
visible in diagnostics. Local consent is mandatory. Guest microphones are
permitted; other publication requires Chef authorization.

iOS output reports an individual rejected buffer to Erlang without closing the
engine or changing later targets. `monitor --metrics` exposes
`mixer.failure.<reason>` for `native_late_packet`, `native_target_out_of_bounds`
and `native_output_queue_full`. Native
analysis reports target-lead bounds; per-buffer rejection logging is avoided. Local output TCP uses NODELAY.
`mixer.output_stop_pending: true` means a failed output has not acknowledged
stop; it cannot be reused as healthy. EOF alone does not confirm native stop.
Rebuild/run the iPhone app to update both sides of the local binding protocol.
Focused hardware-free protocol checks: `rebar3 eunit --module=ba_ios_audio_tests`.

For bursts followed by silence, inspect `clock.filter_reset_reason` and
`clock.filter_reset_count` alongside `clock.filter_ready` and clock state.
Reasons distinguish `resume`, `network_changed`, `sample_gap`,
`reference_changed`, `scope_changed` and `permission_unavailable`.
`receiver.suspended`, `receiver.active_subscriptions`,
`receiver.mix_ready_subscriptions`, `transport.sessions` and `transport.open`
distinguish saved intent from live media work. Speaker `ready` means capability
availability; receive/render counters alone do not prove physical output.
Network-path hints refresh discovery without discarding clock samples or closing
healthy media. Connection, lease and clock-freshness checks handle actual failures.

Build commands belong in [BUILDING](../../docs/BUILDING.md). Product permission
and launch instructions are in [macOS](../../../OpenSound/docs/MACOS_APP.md),
[iOS](../../../OpenSound/docs/iOS/README.md) and
[Windows](../../../OpenSound/docs/Windows/README.md).

Current contracts: [streams](../../docs/BUFFEE_STREAMS.md),
[engine interface](../../docs/AUDIO_ENGINE_INTERFACE.md),
[clock](../../docs/BUFFEE_TIME.md), [architecture](../../docs/ARCHITECTURE.md).
User listening confirms audible microphone output; quality and physical speaker
timing remain unqualified. See [current limits](../../docs/PROGRESS.md).

Optional output diagnostics use `diagnostics(Handle, Options)` on an adapter.
It returns `{ok, Summary}`, `pending` for an asynchronous local response, or
`unsupported`. The Mixer polls every 500 ms; a binding must not synchronously
wait for native playback or run DSP here. iOS protocol v1 advertises readiness
`<<1,1>>`, accepts `<<6,Enabled>>` for analysis and `<<7>>` for a fixed-size
summary; old `<<1>>` bindings remain usable without this extension. Completion
callbacks only update locked bounded native counters; socket replies stay on
the binding's serial queue. Erlang retains all sample interpretation and policy.

The Device's supervised `ba_audio_observer` samples existing audio/clock state
without starting capture/playback. Its cache feeds both local UI and signed
remote monitoring. Meter/analysis options are separate saved Device settings.
See the CLI README for controls, field meanings and privacy/validation limits.
