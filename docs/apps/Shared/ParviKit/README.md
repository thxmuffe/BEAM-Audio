# ParviKit

Repository split (2026-11-03): see [current build paths](../../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

A local Swift package under `src/Apps/Shared/`, used by the macOS app and iPhone project.
This is shared application code; the Erlang layer remains in `src/control/`. It contains the
shared native chat UI, observable UI model, JSON snapshot types and `ChatRuntime`
interface. It has no third-party Swift dependencies and owns no chat history or
membership rules: those remain in the shared Erlang application under `src/control/`.

```text
macOS app -- MacErlangRuntime -- bundled BEAM subprocess
           \                 /
            ParviKit + shared Erlang application
           /                 \
iPhone app -- IOSErlangRuntime -- embedded BEAM
```

Both adapters return actual Erlang snapshots to the same model. The iOS adapter
now starts interpreted BEAM in-process and uses a device-local socket to the
same shared OTP application. Startup, supervisor recovery and UI messaging have
been verified on the physical iPhone. The rebuilt Mac and iPhone connect to the
shared default Reception Desk, and the model displays actual relay status and
connection errors. Swarm/chat rules stay in Erlang; the Swift layer forwards
commands and renders snapshots.

Xcode consumes the package directly through a relative local package reference.
The command-line Mac build compiles the same package sources as a static module.
Each platform compiles its own native library; compiled macOS binaries cannot
be reused as iOS libraries. Erlang sources are also shared, but their bytecode
must be compatible with the runtime shipped on each platform.

UI layout adapts to the device: a sidebar on Mac and a compact screen on iPhone.
Runtime hosting, permissions, audio hardware and lifecycle behavior remain
platform boundaries. No speculative audio interfaces are introduced yet.

## System-message filter

The shared Mac/iOS chat view has a minimum system-message level: Trace, Info,
Warning or Error. It starts at Info for each app session. Levels include higher
severities; normal user messages stay visible at every setting. Filtering happens
only in the UI and does not change broadcast delivery or the runtime's bounded
history. Existing events without a level default to Info; older `clock_adjusted`
events default to Trace. Routine clock messages are short Trace events, with
reference/correction details retained in Erlang event metadata. Existing audio
failure events are Error; ordinary start/stop notices remain Info.

These are application message-board levels, not a replacement for OTP Logger
configuration. Rebuild both apps to apply the UI and bridge changes.

## Node audio diagnostics

Selecting a node in the native-cluster graph submits `node_diagnostics` with its
existing node name to Erlang. Selection and manual Refresh fetch one snapshot;
there is no metrics broadcast or timer. The model handles request identity and
selection state; the BEAM validates membership/liveness and performs OTP erpc.
`AudioStatisticsView` presents the same fields on iPhone Audio and remote node
details, including an explicit reason for unavailable capture-to-track timing.
Snapshots contain audio status and summary statistics, with no PCM or chat data.
