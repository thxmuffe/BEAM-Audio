# 0003: Minimal full-OTP iOS host

Date: 2026-10-26. Status: builds and simulator execution verified; physical-device
verification pending.

Use the existing prebuilt Mob runtime rather than adopting Mob's Elixir/UI stack
or writing an OTP port. Pin OTP 29.1.2 artifacts and their published SHA-256
digests. This matches the Mac's compiler and includes OTP's JSON module. Native
libraries remain ignored build dependencies with a preparation script, not large
checked-in binaries. See `src/Apps/iOS/THIRD_PARTY.md` for exact source references.

The iOS host statically links interpreted BEAM and starts it on a background
thread. It starts the same Parvi OTP app, then connects to an ephemeral loopback
socket opened by its Swift host. This private same-device socket carries the same
JSON requests and snapshots as the Mac pipes. It is not a proxy to the Mac and
does not require an external server. No custom messaging NIF is needed.

The first feasibility build deliberately avoids distribution, EPMD, DNS, public
listeners and background keepalive. BEAM and the native app share a process, so
the host never calls `init:stop` or starts a second VM in-process. OS suspension
and termination apply to both. Failed startup requires stopping/relaunching.

Each launch runs a bounded Erlang self-test before exposing the UI bridge:
message handling, worker termination, supervisor restart, empty restarted history
and successful handling by the replacement worker. An Erlang-generated receipt
in the app Documents directory makes the result independently inspectable.

Simulator execution verifies the runtime ABI table, packaging, boot path,
native/BEAM bridge, shared UI messages and supervisor recovery. A simulator is
not a physical-device substitute: developer signing and real iPhone execution
are the next gate. Peer discovery, authentication and Mac–iPhone traffic remain
a separate implementation step after that gate.
