# macOS OpenSound app — step 10

The product lives in the sibling OpenSound repository. Build with
`bash src/Apps/macOS/build.sh` there; the result is `builds/macOS/OpenSound.app`.
The new entry point uses OpenSoundKit and the unnamed `swarm_control` profile.
It preserves the existing Keychain Device Identity and local address book. It
never restores a gathering. Migration removes obsolete authority/policy/Desk,
Swarm, subscription and clock-status snapshots; it never removes contacts or keys.

## User-led check

Open the new app yourself. Create a named Swarm or accept an invitation. Contacts
and groups stay on your Device; invitations are private URI/QR-shareable values.
The creator is Captain/Director for this gathering. Captain end ends it;
participants may leave. Old iOS/Windows app builds have not been migrated.

Audio has exactly three permission/action toggles: speaker, microphone, and send
default output to Swarm. Speaker starts enabled; microphone and broadcast start
disabled on each app launch. You may enable them before joining. The Device
Handler enlists capabilities and starts its fixed local audio Worker after join;
eligible work starts automatically once authorization/clock/resources are ready.
No separate Subscribe or Playback button is required. OS microphone permission is
requested on enabling; system capture reports macOS System Audio Recording errors.
Off stops the corresponding work. Waiting/starting/error states are not successful
capture or playback. The existing production clock acquisition policy is retained;
initial synchronization can take its normal sampling window.

The Worker maintains per-source publication/receive Contracts and eligible scoped
Subscriptions using the existing Stream negotiation. Those are the audio task
lifecycles; remote peers still cannot select arbitrary Worker modules or enable
local capture. App-created gatherings grant authenticated members the operation
permissions needed for this interaction, while local consent/Contracts/exclusions
still gate actual work. Primitive headless membership defaults are unchanged.

Use a second updated Device to check receiving and mixing. Speaker plays eligible
remote Sources; it does not monitor the local microphone into itself. Source
formats/rates remain explicit; the reference Mixer currently requires a common
rate and clock. Incompatible input and output failures remain visible. The native
system tap excludes this Device's playback processes to prevent rebroadcasting
received audio, including helpers created after capture starts. Physical acoustic
feedback through a microphone is a separate hardware phenomenon.

Graph shows the clock/time, Director tasks and Device Handlers with audio children.
Inspect requests only an authenticated capability report, never arbitrary OTP
inspection. Exclusions are available in Graph and Audio and fence affected
sessions/jobs/Streams. They survive local worker recovery within this gathering,
then disappear with it. Excluding a needed Captain/clock can remove availability
and eventually end local membership at its existing authorization bound.

Chat remains selectable text with a composer, sender/time and bounded gathering
history. Passport details are in Chat, including public membership ID, status,
Captain and policy epoch/revision. Private keys and invitation secrets are absent
from inspection/status reports. Ending/VM restart forgets this history/membership.

## Native boundary and evaluation

Core Audio supplies raw microphone/default-output buffers, source format and host
timestamps. Erlang retains metering, shared-clock policy, packet targets, bounded
queues and the reference multi-source Mixer. AVAudioEngine executes approved
planar-output host times through a local port helper. Its clock mapping begins
after engine startup; reported device latency is used, not calibrated DAC timing.
No neighboring packet or arrival time replaces a missing Presentation Target.

An isolated AVAudioEngine two-player mixing candidate is in
`src/Audio/experiments/native-mixing/evaluate.swift`. It compiles; it has not been
run or selected as the default. A separate RTP experiment in
`src/Audio/experiments/rtp/` keeps standard sample-counter timestamps and carries
each full nanosecond target in a header extension. Its ExRTP encode/decode test
passes independent-target precision, reordering and wrap checks. Actual SDP
negotiation, WebRTC/native-decoder preservation, recovery and listening remain
unverified, so the production wire format is unchanged. This is an initial bounded
evaluation, not evidence for switching production mixing or RTP semantics.

Validation in this change: macOS bundle/native-helper compilation, static runtime
imports, backend unit/protocol checks, three pure Swift model tests and the
isolated RTP codec proof. Run the model tests with full Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path src/Apps/Shared/OpenSoundKit --scratch-path builds/intermediates/OpenSoundKit-tests
```

Run that command from the product repository. The app,
Swarm services and hardware were not launched for acceptance; the user requested
to perform live testing. UI appearance, OS prompts, real capture/output, exclusions
across two app Devices and sustained timing therefore remain acceptance work.
The earlier 8d maximum-Offset deadline misses are still open. No iOS/Windows build
or deployment was performed; their product names/shared-package references were
updated mechanically, without migrating their runtime/UI behavior.

The CLI hardware Device Handler command is approved in PLAN.md as a follow-up;
it is not implemented by this macOS change.
