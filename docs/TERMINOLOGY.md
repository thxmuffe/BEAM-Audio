# BEAM Audio terminology

## Devices and roles

**Buffee** is the intentional name for a gathering of Devices sharing audio and
voluntarily offered resources. Product UI calls a Buffee a **Session**. Device
lists and counts always refer to Devices, with roles displayed separately.

A Device participates as a **Chef** or **Guest** and can additionally be an
**Owner**. These are not three mutually exclusive levels:

| Role | Meaning |
| --- | --- |
| Guest | Receives audio and may offer consented microphone input and computing capacity. |
| Chef | Has Guest capabilities and may publish music/system audio. |
| Owner | Trusted administrator who may promote/demote Chef/Guest, share or remove ownership, remove a Device, and destroy the Buffee. Ownership does not imply Chef participation. |

Creation explicitly gives the creating Device Owner and Chef roles. Sharing
ownership preserves the recipient's existing participation role. Making an Owner
a Guest preserves ownership; removing ownership preserves Chef/Guest participation.
Local speaker, microphone and capture consent remains independently required.

**Manager** and **Inspector** are predefined processes, not Device roles. They
usually run on an Owner's VM, but their placement grants no administrative rights.
Owners are deliberately trusted; there is no quorum, external ownership registry,
or special procedure for an absent Owner. Normal signed state exchange applies
when Devices reconnect. Do not add speculative offline-owner mechanisms.

## Lifetime

**Leave** disconnects this Device. Ownership survives leaving and application
shutdown, including shutdown of every Device. A remembered Owner can reopen the
same Buffee using the same Device identity and saved ownership record. A live
Owner may remove another Owner or remove a troublesome Device.

**Destroy** ends the Buffee for all reachable participants and clears their saved
return intent. It is separate from Leave and requires ownership. An absent Owner
does not end a Buffee: already admitted Chefs and Guests may continue. No Owners
and no Chefs is idle participation, not an automatic destructive action.

## Technical components

| Term | Meaning |
| --- | --- |
| Reception | Authenticates Devices, introduces them and routes control messages; does not own the Buffee or carry audio. |
| Device Handler | Local OTP service controlling this Device's resources and Workers. |
| Worker | A supervised local process executing a predefined operation. |
| Computing capacity | Resources voluntarily offered by a Device. |
| Source | Stable identity of a local capture or other audio producer. |
| Stream | A Source publication/incarnation and its audio packets. |
| Subscription | Persistent intent to receive a Source, independent of a live connection. |
| Media Session | A temporary authorized transport connection. |
| Stream Handler | Erlang boundary for packet format and transport. |
| Audio Engine | Established backend executing approved audio operations. |
| Buffee Clock | Shared timeline and local monotonic mappings; its provider need not be an Owner. |
| Presentation Target | Independent broadcaster-assigned playback target carried by every packet. |
| Response time | Buffee-wide delay before scheduled playback; existing technical APIs use Playback Offset and `offset_ms`. |

The OTP application is `ba_core`; the facade is `ba_runtime`; core modules use
`ba_` and environment variables use `BA_*`. The shared runtime profile is
`buffee_control`. `native_cluster` refers only to the older trusted Distributed
Erlang compatibility path, not to the secure Buffee boundary.

See [membership and ownership](BUFFEE_MEMBERSHIP.md), [clock](BUFFEE_TIME.md),
[names and migration](NAMING.md) and [current plan](PLAN.md).
