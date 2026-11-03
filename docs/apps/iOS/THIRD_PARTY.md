# Embedded runtime provenance

## Native transport source builds (2026-10-29)

The native profile adds static NIFs built from the pinned dependencies in
`src/control/transport/mix.lock`: ExDTLS, ExLibSRTP, ExSCTP, CRC and their
Unifex/Shmex/Bunch C support. `prepare-transport.py` reads their source/generated
interfaces without modifying dependency trees. Compiler macros namespace C NIF
globals for static linking.

- [OpenSSL 3.5.9](https://openssl-library.org/source/): target-built SSL and
  crypto libraries; published SHA-256
  `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`.
  The native profile links this crypto archive instead of the runtime archive's
  crypto library. The OTP crypto NIF remains upstream-provided; the explicit
  relay build retains the original crypto archive.
- [Cisco libsrtp 2.7.0](https://github.com/cisco/libsrtp/tree/v2.7.0): compiled
  from the upstream tag using CMake and the target OpenSSL build.
- [Rustler 0.37.0](https://github.com/rusterlium/rustler/releases/tag/rustler-0.37.0):
  upstream prefixed static NIF entry points. `src/Apps/iOS/transport/Cargo.toml`
  and its lockfile build the unmodified ExSCTP source with sctp-proto 0.3.0.
  The desktop Rustler version is unchanged.
- Elixir 1.19 support and portable transport BEAM modules come from the existing
  Mix build. Mac `.so`/`.dylib` binaries are excluded.

Available source licenses/notices are staged with the runtime. Device native
archives and host linkage are checked; this is not on-device execution, App Store
distribution or a complete license-audit claim. Simulator native compilation
remains unverified for this increment.

## Base OTP runtime

Parvi uses the prebuilt interpreted OTP 29.1.2 / ERTS 17.1.1 archives from
[GenericJam/mob release otp-d199a49a](https://github.com/GenericJam/mob/releases/tag/otp-d199a49a).
The release identifies OTP source commit `d199a49a` (OTP-29.1.2). The downloader
checks these GitHub-published SHA-256 digests before extraction:

| Artifact | SHA-256 |
| --- | --- |
| `otp-ios-device-d199a49a.tar.gz` | `437475e8abb721f3ffbbfe6f17ddb495e8bddd13503eaee87aea5e2c14e5dd1d` |
| `otp-ios-sim-d199a49a.tar.gz` | `a6066a1cce2391f78e1cbf45f89f758f78e42cf8f8fda7363660940f4a7b6755` |

Build/packaging reference:
[GenericJam/mob_dev](https://github.com/GenericJam/mob_dev) commit
`0f67685cf65ff7a3987d541c8842dfbc40047855`, including the iOS runtime cross-build
patches. Upstream documents limitations around subprocess/fork support on iOS.

The native startup argument layout and static driver/NIF ABI table were adapted
from [GenericJam/mob](https://github.com/GenericJam/mob), commit
`66fe71ca818c68b101875ba9cb4f4949a2f0bc9e` (`ios/mob_beam.m`,
`ios/driver_tab_ios.zig`). The errno compatibility helper follows mob_dev's
`generate_erl_errno_compat_stub`. The Mob sources are MIT licensed; their license
is preserved in `MOB-LICENSE` and copied into the application resources. Parvi
does not use Mob's UI, Elixir framework, remote code updates or deployment tooling.

Erlang/OTP is Apache-2.0 licensed; its source and third-party components retain
upstream copyrights and licenses. The runtime archive also includes static
OpenSSL 3.5.9 and ASN.1 components, linked through the OTP NIF table. These
artifacts are upstream-provided binaries, not a locally reproduced OTP build.
Before public distribution, reproduce/audit the build and assemble all upstream
component notices for the chosen shipping artifact. This is a local feasibility
prototype, not an App Store distribution or compatibility claim.
