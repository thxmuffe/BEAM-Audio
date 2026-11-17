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
logs include target lead in milliseconds. Local output TCP uses NODELAY.
`mixer.output_stop_pending: true` means a failed output has not acknowledged
stop; it cannot be reused as healthy. EOF alone does not confirm native stop.
Rebuild/run the iPhone app to update both sides of the local binding protocol.
Focused hardware-free protocol checks: `rebar3 eunit --module=ba_ios_audio_tests`.

Build commands belong in [BUILDING](../../docs/BUILDING.md). Product permission
and launch instructions are in [macOS](../../../OpenSound/docs/MACOS_APP.md),
[iOS](../../../OpenSound/docs/iOS/README.md) and
[Windows](../../../OpenSound/docs/Windows/README.md).

Current contracts: [streams](../../docs/BUFFEE_STREAMS.md),
[engine interface](../../docs/AUDIO_ENGINE_INTERFACE.md),
[clock](../../docs/BUFFEE_TIME.md), [architecture](../../docs/ARCHITECTURE.md).
User listening confirms audible microphone output; quality and physical speaker
timing remain unqualified. See [current limits](../../docs/PROGRESS.md).
