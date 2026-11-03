# 0001: Chat first; investigate embedded full OTP on iOS

Date: 2026-10-26. Status: Mac baseline implemented; iOS recommendation provisional.

## Scope and decision

The newer [handover](../notes%2020261026.md) explicitly defers audio and starts
with Erlang chat on Mac and iPhone. Follow that scope before the older audio
milestones in [PLAN.md](../PLAN.md). Keep the original audio plans as future
research, rather than presenting chat as a synchronization experiment.

Use standard OTP on the Mac: one chat `gen_server`, a supervised `pg` scope,
manual node connections, and a terminal API. No dependencies or media engine.
This validates the actor core while the phone runtime is unresolved. Distributed
Erlang is a trusted prototype transport, not a decision about the public protocol.

## Environment actually inspected

- Apple Silicon `arm64`; macOS 27.0.1, build 26A434.
- Active developer path: `/Library/Developer/CommandLineTools`.
- No Xcode application in `/Applications`; `devicectl` unavailable.
- No valid code-signing identities reported by `security find-identity`.
- Erlang and rebar3 initially absent; installed OTP 29.1.2 / ERTS 17.1.1 and
  rebar3 3.27.3 with Homebrew to build and test the Mac application.
- iPhone connectivity, iOS versions, Developer Mode, Apple ID and provisioning
  cannot be established with the available Apple tooling. The handover's phone
  models and Xcode availability are planning assumptions, not verified inventory.

## iOS options reviewed

These are upstream claims and source-level starting points, not locally verified
phone results. Search results and versioned documentation differ in freshness;
pin and inspect an exact runtime revision before adopting it.

| Option | Evidence and suitability | Decision |
| --- | --- | --- |
| Mob embedded full BEAM | Its [architecture](https://mob.hexdocs.pm/architecture.html) describes on-device OTP, a native UI bridge, and development connections through Erlang distribution. The [project](https://mobframework.com/) reports physical iOS support and active pre-1.0 development. It is Elixir-oriented, but embeds the Erlang runtime rather than substituting one. | First candidate for the physical-device runtime spike. Keep Parvi logic in Erlang; avoid adopting its entire UI framework before runtime validation. |
| Elixir Desktop runtime + Xcode wrapper | The [runtime builder](https://github.com/elixir-desktop/runtimes) packages iOS arm64 and simulator BEAM as an XCFramework. The [iOS example](https://github.com/elixir-desktop/ios-example-app) includes native startup/Swift bridge code, but its instructions still target OTP 25.0.4 and an older OpenSSL dependency. | Credible fallback and embedding reference. Old example instructions need a new compatibility/build check; do not assume the bundled runtime matches current OTP. |
| AtomVM | [Upstream](https://github.com/atomvm/AtomVM) implements a different VM with a subset of OTP. Its [release notes](https://github.com/atomvm/AtomVM/releases) describe experimental distribution support in the 0.7 release cycle. | Does not establish full Erlang/OTP-on-iPhone feasibility. No substitution without an explicit architecture decision; iOS integration also remains unverified. |
| Build a fresh OTP iOS port | OTP documents [cross-platform build options](https://www.erlang.org/doc/system/install.html), including disabling JIT. These are not a turnkey iOS app or signing workflow. | Avoid initially: native runtime patches, static linking, packaging and platform lifecycle would become our responsibility. |

Recommendation: first reproduce a pinned Mob **development** runtime on a real
iPhone, then load the same Parvi Erlang modules into it. This is an investigation
path, not yet a selected dependency. If its tooling forces too much framework
adoption, evaluate the Elixir Desktop XCFramework build and a minimal Swift host.
No third-party runtime binaries or source have been added to this repository.
Review licenses and build provenance before vendoring or linking them.

An important limitation: the reviewed [Mob release task](https://hexdocs.pm/mob_dev/Mix.Tasks.Mob.Release.html)
documents disabling distribution in its release build. Development-time
distribution support therefore does not establish shipping Mac–iPhone LAN chat.
The exact pinned runtime must demonstrate `kernel`, `stdlib`, `gen_server`,
`supervisor`, `pg`, and Wi-Fi networking. USB development tunneling alone does not
meet the same-Wi-Fi milestone. If distribution cannot be used, document the gap
before implementing an alternative transport; preserve Erlang actors on-device.

## Physical-device gate and next experiment

1. Install full Xcode, select its developer tools and install the relevant iOS SDK.
   Connect/unlock an iPhone, enable Developer Mode as required, and inspect its
   actual OS and architecture. Configure development signing with an Apple ID.
2. Inspect and pin a candidate runtime's source/build scripts, runtime version,
   license, device arm64 support and native bridge. Match the host compiler to
   the embedded OTP version; OTP 29-built modules are not assumed to run on OTP 25.
3. Build the smallest native host, bundle runtime resources and compiled `.beam`
   and `.app` files, and start Parvi locally. Display the device's `node()`, OTP
   version and a chat-worker response. Verify supervisor restart on the device.
4. Add iOS local-network permission metadata and a minimal SwiftUI view separated
   from the Erlang worker. Confirm foreground operation first; app suspension
   means continuous background execution cannot be assumed.
5. On the trusted Wi-Fi LAN, connect Mac and phone and prove bidirectional chat,
   join/leave, reconnect and worker recovery. Record device logs and versions.
   Then repeat with the second phone.

No iOS target or simulated Swift-to-Mac proxy is presented as a phone prototype.
Without Xcode, an SDK, signing and device access, this session cannot build,
install or verify that part of the system.

[Apple's guidelines](https://developer.apple.com/app-store/review/guidelines/)
describe free installation through Xcode and restrictions on downloaded executable
code (2.5.2). Local development does not establish App Store eligibility. Use
bundled application code for the spike; assess store distribution, runtime
permissions and any hot-code-loading features separately before shipping.
