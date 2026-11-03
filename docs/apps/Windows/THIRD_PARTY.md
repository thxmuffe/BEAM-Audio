# Windows graph-view provenance

`src/parvi_fgraph_win.erl` is adapted from Erlang/OTP **29.1.2**, Reltool **1.1**:

https://github.com/erlang/otp/blob/OTP-29.1.2/lib/reltool/src/reltool_fgraph_win.erl

Copyright Ericsson AB 2009–2025. Licensed under **Apache-2.0**. The original
copyright and license header are retained in the adapted source. The project's
root `LICENSE` contains the Apache-2.0 license text.

Parvi adaptations: module name, light background, bidirectional connection
arrows, bounded initial layout for a small viewport, centered labels, node-click
notifications, hidden-tab pause/resume, and ignoring irrelevant move events.
The original editing controls are hidden by the adapter. Force calculations
remain in the unmodified `reltool_fgraph` module from the bundled OTP runtime.
Compilation uses that same pinned runtime's `reltool_fgraph.hrl` header.

The native graph component is an internal OTP implementation, not a public
stable API. Keep the runtime version pinned when building or changing it.


The relay client bundles Gun 2.7.0 and Cowlib at upstream commit
`4401b858f2229abb3ea115c60924f6c77e5f8aa3` (ISC license), under `relay_lib/`.
Their license files accompany their compiled modules. These are pure Erlang
transport libraries, not another UI runtime. Dependency locks record provenance.
The graph adapter also accepts binary relay identities and shortens long display
labels; full identities remain visible in node details.

Optional native builds use the exact WebRTC/SCTP dependency versions locked in
`src/control/transport/mix.lock`, plus Elixir support applications. They are loaded
from `native_lib/`. Supply Windows-built DLLs and dependency licenses together;
the build copies each application's license/notice files. The repository does
not yet produce a complete Windows native dependency bundle. Mac/iPhone native
artifacts are not compatible with Windows.
