# Local Device Handler and Workers

`ba_device_handler` describes local capabilities and starts only predefined
Workers under `ba_device_sup` / `ba_device_worker_sup`. Remote commands cannot
choose arbitrary modules or arguments. Consent, local Contracts, capacity and
membership permissions gate work independently.

A Manager offers scoped work through the authenticated control protocol. The
Handler validates it locally and reports accepted/running/completed/rejected or
failed outcomes. Worker monitors, deadlines, cancellation and bounded history
provide lifecycle control without cross-device supervision links.

Audio Workers retain desired Device-local settings, but start actual capture or
playback only when permissions, timing, resources and local consent are ready.
Chef permission is required for system/music publication. Guest microphones are
permitted with consent. An Owner cannot remotely enable a Device microphone.

An unsupported capability or unavailable native adapter is reported explicitly.
A configuration acknowledgement does not prove running audio. Native timing and
physical listening must be qualified on the target platform.

See [jobs](BUFFEE_JOBS.md), [streams](BUFFEE_STREAMS.md) and [builds](BUILDING.md).
