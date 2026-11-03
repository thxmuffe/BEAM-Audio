# 0002: Share native app code; isolate Erlang runtime hosting

Date: 2026-10-26. Status: shared package and iPhone project implemented; iOS
runtime integration pending.

The native Mac proof put UI, model and runtime startup in one Swift source file.
Before creating a second implementation, extract a local `ParviKit` package.
Both platforms use its SwiftUI chat screen, message types, UI state and runtime
interface. Keep the working Mac runtime launcher in the macOS app, and leave
the iOS runtime adapter explicitly unavailable until a real embedded VM works.

The Erlang application remains the single implementation of messaging,
supervision and group membership. Extract `parvi_bridge:request/1` so a native
embedded host can use the same JSON contract without terminal pipes. The Mac
stdio loop is only a transport adapter. Connection policy remains Mac-only until
the phone networking experiment establishes a safe private-LAN configuration.

Use source sharing and platform-specific builds, rather than trying to link a
Mac binary into an iOS application. Avoid choosing or vendoring an unverified
third-party runtime just to make the UI project look complete. No iOS chat
success is claimed from an unsigned arm64 compilation.

Xcode 27.1 (27A9275) and the iOS 27.1 SDK are now installed. Validation uses
`DEVELOPER_DIR` for individual commands, leaving the user's global developer
directory setting unchanged. Device signing and physical-device testing remain
separate from the project creation and shared-code refactor.
