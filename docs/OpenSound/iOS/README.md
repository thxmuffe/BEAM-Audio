# OpenSound for iPhone

The product app is in the sibling OpenSound checkout. It uses the same
OpenSoundKit Chat / Graph / Audio hierarchy as macOS, with Swarms and contacts
in a collapsible sidebar on compact screens. The embedded Erlang VM is an
unnamed `swarm_control` Device; the app never enables Distributed Erlang.

## Build and run yourself

From the product checkout:

```sh
bash src/Apps/iOS/build.sh device native
```

This produces **unsigned** `builds/iOS/Debug-iphoneos/OpenSound.app` without
installation or launch. To run on your iPhone, open
`src/Apps/OpenSound.xcworkspace`, select the OpenSound iOS scheme and your signing
team/device, then Run. Prepare runtime resources with the command above first.
Stable bundle/Keychain identifiers are preserved for Device Identity.

At startup, old Swarm/subscription snapshots are removed; contacts/groups and
Device Identity remain. Each launch starts idle. Create a Swarm or paste a fresh
invitation from an updated Mac. Old trusted-cluster invitations are incompatible.

## Audio permission/action switches

Speaker defaults on; Microphone and Send default output to Swarm default off.
Enabling advertises local consent; the Device Handler starts eligible work once
membership, Contracts, clock and resources permit. No Subscribe or Play buttons
are required. Waiting/errors are distinct from actual capture/playback. Device
exclusions and Swarm Offset are in Audio; public Passport information is in Chat;
Graph exposes clock/Director/Device Handler state.

Microphone asks for iOS permission on enabling. Native input supplies actual
Float32 format and capture-time host timestamps. Erlang owns Source identity,
metering, publication, presentation targets and the current reference Mixer.
The microphone and speaker share an OS audio session. Use headphones when checking
simultaneous mic and speaker to avoid physical acoustic feedback.

System/default-output broadcast requires **iOS 27+** and the system
ScreenCaptureKit sharing picker. Cancelling or an unsupported OS reports an error
and leaves broadcast off. Selection authorizes capture but does not open it until
the Device Handler accepts work. Current-app audio is excluded to prevent
rebroadcasting received Swarm audio. Protected content may be unavailable under
OS policy. Microphone and speaker remain available on older supported iOS versions.
See [Apple ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit).

Capture queues are bounded and report dropped callbacks. Playback consumes
Erlang-approved local targets and rejects late/invalid/unbounded scheduling;
it does not reconstruct targets from packet arrival. Route changes/interruptions
close affected bindings and surface failures; toggle the affected capability to
retry. Seamless route recovery is not yet established.

Ordinary backgrounding suspends audio work and discards old receive buffers;
foreground resume waits for fresh clock state. While system broadcast is enabled,
this explicit suspension is omitted so switching to a source app can work. iOS
still controls background execution and sharing; continuity is unverified.
Network path changes notify the existing receiver/clock recovery path. There is
no promise of gapless Wi-Fi/cellular transitions or restored Swarms after launch.

## Validation and remaining acceptance

The unsigned physical-device target compiles. Four shared Swift model tests and
four core app-session tests pass, including iPhone naming/typed capability commands
and old-snapshot removal without deleting contacts/identity files. No app, live
Swarm, microphone, speaker or system picker was launched by the agent.

User checks remain: Mac/iPhone join/chat; all three switches and permissions;
simultaneous mic/speaker and supported formats; system capture exclusion and
OS stop/cancel; phone layout/text selection; clock/Offset, deadlines, real sound
and source mixing; interruptions, lock/background, and Wi-Fi/cellular recovery.
The earlier maximum-Offset continuity issue and native mixing/RTP evaluations
remain open. Compilation is not on-device acceptance.

[Historical prototype notes](../../old-ideas/ios-legacy-app.md) are archived and
are not current setup or architecture instructions.
