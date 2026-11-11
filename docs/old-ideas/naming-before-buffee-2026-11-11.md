# Core names and migration

The user approved the [Buffee product vocabulary](TERMINOLOGY.md) on 2026-11-11.
Reception is now the display/documentation name
for the introduction/routing service. Existing identifiers such as
`ba_swarm_desks`, `BA_DESK_PORT`, `ReceptionDesk` and hosted URLs stay unchanged.
The migration history below does not authorize a new code/protocol migration.

Core-owned Erlang modules, registered processes, test modules and native exported
functions use `ba_` (BEAM Audio). The OTP application is `ba_core`, the public
runtime facade is `ba_runtime`, and the transport dependency application is
`ba_transport`. Configuration uses `BA_*`. Do not add old-name forwarding modules
or a second set of environment-variable aliases.

Most module/file names change mechanically from `parvi_*` to `ba_*`. These names
also clarify the component responsibility:

| Previous name | Current name | Responsibility |
| --- | --- | --- |
| `parvi` / `parvi.app.src` | `ba_runtime` / `ba_core.app.src` | Runtime facade / OTP application. |
| `parvi_clock*` | `ba_swarm_clock*` | Swarm Clock and its existing helpers/tests. |
| `parvi_cluster_store` | `ba_device_store` | Local identity access and checkpoints. |
| `parvi_audio_subscription` | `ba_media_session` | Temporary WebRTC media connection. |
| `parvi_audio_subscription_intent` | `ba_subscription` | Persistent intent to receive a Source. |
| `parvi_audio_stream_handler` | `ba_stream_handler` | Stream Handler behaviour/selection. |
| `parvi_audio_stream_handler_legacy` | `ba_stream_handler_pcm` | Current PCM handler, under `handlers/pcm/`. |
| `parvi_audio_stream_handler_webrtc` | `ba_stream_handler_opus` | Opus handler; PCM also uses WebRTC. |
| `parvi_cluster_auth/authority/desk/trust` | `ba_legacy_cluster_auth/authority/desk/trust` | Historical trusted Distributed Erlang stack. |
| `parvi_connection` | `ba_legacy_connection` | Historical OTP-node/cookie connection string. |
| `parvi_broker*` / `parvi_directory` | `ba_desk*` / `ba_desk_directory` | Historical HTTP Reception directory, separate from the Phoenix service. |
| `parvi_beam.c/.h`, `parvi_bridge_*` | `ba_beam.c/.h`, `ba_bridge_*` | Native runtime/UI bindings. |

Use the [canonical terminology](TERMINOLOGY.md). A Source's stable key, its Stream
incarnation, a Subscription's saved intent and a Media Session's live attempt
remain separate identities/lifecycles. This cleanup changes names, not the clock
algorithm, packet target calculation, Passport policy or checkpoint format.

## Consumers and configuration

Recompile core modules; renamed entry points are not available in existing app
bundles. Consumers must use `ba_runtime:start(swarm_control)`, application/config
atom `ba_core`, the renamed modules/native symbols and the matching rebuilt core
artifacts. Old generated builds are not rewritten by source renaming.

Change `PARVI_*` configuration to `BA_*`, retaining existing values. For example,
`BA_IDENTITY_SEED` and `BA_STATE_DIR` must point to the same identity/state as
before. A missing seed on an ephemeral profile creates an ephemeral identity,
just as before; renaming the variable does not migrate a launcher automatically.
Reception host configuration is `BA_DESK_BIND` and `BA_DESK_PORT` (formerly
`PARVI_BROKER_BIND` / `PARVI_BROKER_PORT`); conventional `PORT` remains supported.
Native GStreamer configuration is `BA_GSTREAMER_*`. Check the component READMEs
and scripts for the complete configuration each consumer uses.

The OpenSound repository is intentionally untouched. Step 9 must update its
runtime calls, launch environment, C/Objective-C bridge symbols, resource paths,
and packaging to these names before building/launching apps. Product-owned
`ParviKit`, bundle names and `parvi_windows*` references in product integration
tests still describe that unmigrated repository. Core Windows capture now belongs
to `ba_audio_sup`, with no dependency on the product window supervisor.

## Deliberately retained spellings

- Existing `parvi://...` invitation schemes, cryptographic signature domains,
  media channel labels and the PCM wire-profile identifier. These identify
  versioned formats, not Erlang modules; changing them would be a protocol migration.
- `org.opensound.parvi...` secure identity/state locations. Changing those would
  risk generating a new Device Identity instead of reusing the current one.
- The existing `parvi-reception-desk.onrender.com` address/Render service identity.
  Local source renaming does not rename or deploy the hosted service.
- Dated progress, archived ideas, product documentation and historical decisions.
  They may mention previous names; current source/API names are defined here.

Checkpoints retain their existing names, version and data. No identity or saved
membership is erased by this cleanup. The prior deliberate version-1 relationship
reset is unchanged. Apps, physical audio and deployed-service validation remain
separate from core compilation and headless checks.
