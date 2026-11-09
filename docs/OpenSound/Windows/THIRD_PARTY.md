# Windows dependencies

Windows code-reload notifications use the Erlang `fs` package **11.4.1**
(https://github.com/synrc/fs), with its bundled `inotifywait.exe` Windows backend
(https://github.com/thekid/inotify-win). The package's actual `LICENSE` is the
DHARMA License and is copied beside its modules under `relay_lib/fs/`.
It is a Windows-profile dependency; there is no custom directory-watcher C code.

The relay client bundles Gun 2.7.0 and Cowlib at upstream commit
`4401b858f2229abb3ea115c60924f6c77e5f8aa3` (ISC license), under `relay_lib/`.
Their license files accompany their compiled modules. These are pure Erlang
transport libraries, not another UI runtime. Dependency locks record provenance.

Optional native builds use the exact WebRTC/SCTP dependency versions locked in
`src/control/transport/mix.lock`, plus Elixir support applications. They are loaded
from `native_lib/`. Supply Windows-built DLLs and dependency licenses together;
the build copies each application's license/notice files. The repository does
not yet produce a complete Windows native dependency bundle. Mac/iPhone native
artifacts are not compatible with Windows.
