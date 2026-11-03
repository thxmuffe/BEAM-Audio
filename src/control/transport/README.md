# BEAM direct transport prototype

The [native OTP carrier](experiments/otp_dist/README.md) now lives in
`src/control/src/` and is integrated into the Mac app sources and build. The Mac
native bridge reuses the shared OTP chat worker and the global Render desk for
introductions. See [Mac usage and limitations](../../Apps/macOS/README.md).
Probe drivers remain experimental. The older application transport below is
retained for the current iPhone/Windows path and existing regression helpers.

Parvi reuses **ex_webrtc 0.17.0** and **ex_sctp 0.1.3**, pinned in `mix.lock`.
These third-party libraries implement WebRTC and SCTP. All Parvi transport
logic is Erlang: `parvi_direct` owns peer routing and
`src/control/src/parvi_peer_connection.erl` owns each connection's signalling and
lifecycle, calling the library's public BEAM API directly. There is no custom
Elixir peer module or language-interoperability adapter.

Elixir is still needed to build the upstream libraries, and their compiled
Elixir support modules must be packaged alongside them. `mix.exs` is the build
manifest for those dependencies; this project contains no Elixir application
modules. Eliminating that dependency too would require replacing `ex_webrtc`.
The existing Phoenix Reception Desk is a separate Elixir application and has
not been rewritten or redeployed as part of this transport change.

All networking, signalling, connection selection and payload handling run in
BEAM. Swift receives status snapshots and submits user commands. There is no
Swift WebRTC engine or network-event command interface.

Direct links are preferred. The existing Reception Desk introduces admitted
nodes and provides relay fallback when direct links are unavailable. SDP and
ICE candidates travel through authenticated, swarm-scoped mailbox messages.
The remote DTLS certificate fingerprint comes from that authenticated signalling.
The desk remains a trusted introducer, as it is in the existing relay design.

## Verified experiment

On 2026-10-28, `tests/transport/smoke.py` passed using two independent BEAM VMs and the
third-party WebRTC library. After admission and direct-channel establishment,
the test killed its disposable local Reception Desk. Bidirectional chat,
independent swarm histories and leaving one of two shared swarms continued over
the direct channel. It then restarted the desk and admitted a relay-only peer,
verifying interoperability without forcing that peer to implement WebRTC.
The public Render service was not stopped or changed.

This proves the BEAM transport on the development Mac, not native iPhone
compatibility or NAT traversal across separate internet access networks.

## Build and test

Requirements: compatible OTP, Elixir 1.19, Rust, pkg-config and OpenSSL development
files. Local development here uses the repository's ignored Elixir/Rust caches.

```sh
cd src/control/transport
mix deps.get
mix compile
cd ../../..
# Build the isolated Phoenix desk used by the test:
bash src/Services/ReceptionDesk/build.sh
cd src/control
rebar3 compile
cd ../..
python3 tests/transport/smoke.py
```

The current smoke helper is a Mac development check. It starts the native BEAM
launcher with the compiled transport and Elixir library paths. The upstream
precompiled SRTP dependency expects OpenSSL 3; the helper supplies its Homebrew
library search path without changing OS trust or system library locations.

## Platform packaging

Mac and iPhone sources now package the native carrier and dependencies. Neither
new app path has been verified running. iPhone uses target-built static NIFs;
see [its preparation guide](../../Apps/iOS/README.md). Device compilation/linkage
passes; simulator native compilation and on-device connection remain unverified.
In the older runtime profile, `parvi_direct` remains optional and the existing
relay continues to work without those libraries.

Although most protocol code is Elixir, this is not a 100% pure-language stack:
DTLS/SRTP use native libraries and SCTP uses a Rust NIF. Those belong inside the
BEAM runtime boundary, not in the UI. Their iOS cross-build/static registration
must be verified before updating the working phone app. No native Swift WebRTC
package is required.
