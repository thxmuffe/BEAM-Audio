# Native node-graph investigation

2026-10-27. Investigated and exercised locally with Windows OTP 29.1.2,
Reltool 1.1 and wxErlang 2.7. No Parvi application UI or running node was changed.

## Result

OTP already includes a working wx force-directed graph in
`reltool_fgraph_win.erl`, backed by `reltool_fgraph.erl` and its record header.
All three source files and their BEAM modules are present in the private Windows
runtime. Their source license is Apache-2.0. Both modules are explicitly marked
`-moduledoc false`: this is an internal implementation, not a supported public
embedding API.

The official [Reltool usage guide](https://www.erlang.org/doc/apps/reltool/reltool_usage.html)
describes dragging, selection, locking, freezing and force-layout controls.

## Verified interface

`reltool_fgraph_win:new(ParentWindow, Options)` shares the caller's wx environment
and returns `{GraphPid, Sizer}`. The second value is a **sizer**, not a panel.
It can be attached to a panel inside a larger Parvi window.

The graph accepts asynchronous `add_node`, `del_node`, `change_node`, `add_link`
and `del_link` calls. Node colours can be RGB tuples or separate outline/fill
colours, so the existing RabbitMQ-derived Parvi status palette works directly.
Deleting a vertex removes its incident edges. Labels are generated from node keys.

`tests/Windows/parvi_graph_probe.erl` compiled with warnings as errors and passed
native embedding, synthetic node/link addition and deletion, colour updates,
continued force-layout execution, and cleanup. These were synthetic vertices,
not observations of live Parvi connections.

## Necessary adaptations

* The built-in Reset/Freeze/Lock/Unlock/Delete buttons, three force sliders,
  fixed control IDs and dark drawing style are constructed unconditionally.
  A compact viewer would need a small source adaptation.
* `set_dbl_click/2` is exported but its message is not handled in the receive
  loop. Clicking a node to copy a connection string needs an actual event hook.
* The linked ticker redraws roughly every 40 ms while unfrozen. Repulsion loops
  over vertex pairs; suitability for large swarms has not been benchmarked.
* The Windows probe logged an unhandled `wxMove` event, although graph updates
  and drawing continued. The component subscribes to that event without handling
  it; an adapted viewer should fix this.
* UI teardown must stop the graph with `shutdown`, not `normal`, so its linked
  ticker also exits. The probe verifies that cleanup.

## Recommendation

Reuse the pinned OTP graph/layout implementation through a small Parvi-specific
adapter or an attributed source adaptation. Avoid a browser UI and avoid writing
a new force-layout algorithm. Keep topology state outside the disposable viewer.

The existing status worker knows this node's connections. A complete swarm view
requires gathering each connected node's own adjacency list, with observation
times and unknown/unreachable states. It must not assume every visible pair is
connected, or describe a disconnected peer as definitely dead. Transport links
and future audio subscriptions should be distinct edge types.

`digraph` is an optional OTP graph data structure, not a renderer. An adjacency
list or plain-text diagnostic view can be generated from the same topology model.
