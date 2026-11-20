# Local Device Handler and Workers

`ba_device_handler` describes this Device's capabilities (name, instance,
revision and the speaker/microphone/broadcast audio states) and owns its audio
Worker under `ba_device_sup` / `ba_device_worker_sup`. Remote Devices can read
capabilities with the `capabilities_read` grant; they cannot start Workers or
choose modules or arguments. The test-job capability was removed on 2026-11-20.

The audio Worker keeps desired Device-local settings, but starts actual capture or
playback only when permissions, timing, resources and local consent are ready.
The on_air privilege is required for system/music publication; microphones are
permitted with consent. No other Device can remotely enable a Device microphone.

An unsupported capability or unavailable native adapter is reported explicitly.
A configuration acknowledgement does not prove running audio. Native timing and
physical listening must be qualified on the target platform.

See [streams](BUFFEE_STREAMS.md) and [builds](BUILDING.md).
