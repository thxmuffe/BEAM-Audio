%% Feasibility probe for OTP 29.1.2's existing wx force-graph component.
%% Synthetic topology only; does not join or modify the running Parvi nodes.
-module(parvi_graph_probe).
-export([main/0]).
-include_lib("reltool/src/reltool_fgraph.hrl").
-include_lib("wx/include/wx.hrl").

main() ->
    wx:new(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "Parvi - isolated Reltool graph probe",
                        [{size, {900, 650}}]),
    Panel = wxPanel:new(Frame),
    %% Despite the variable names in Reltool, new/2 returns a SIZER, not a panel.
    {Graph, Sizer} = reltool_fgraph_win:new(Panel, []),
    wxPanel:setSizer(Panel, Sizer),
    wxFrame:show(Frame),
    Green = {152,248,152}, Yellow = {255,255,123}, Grey = {221,221,221},
    Red = {255,122,122},
    reltool_fgraph_win:add_node(Graph, node_a, Green),
    reltool_fgraph_win:add_node(Graph, node_b, Green),
    reltool_fgraph_win:add_node(Graph, node_c, Grey),
    reltool_fgraph_win:add_link(Graph, {node_a, node_b}),
    reltool_fgraph_win:add_link(Graph, {node_a, node_c}),
    await(fun() -> is_record(value(Graph, node_c), fg_v) andalso
                   is_record(value(Graph, {node_a,node_b}), fg_e) end),
    reltool_fgraph_win:change_node(Graph, node_b, Yellow),
    await(fun() -> (value(Graph, node_b))#fg_v.color =:= Yellow end),
    reltool_fgraph_win:del_link(Graph, {node_a, node_b}),
    reltool_fgraph_win:change_node(Graph, node_b, Red),
    await(fun() -> value(Graph, {node_a,node_b}) =:= undefined end),
    reltool_fgraph_win:del_node(Graph, node_c),
    await(fun() -> value(Graph, node_c) =:= undefined andalso
                   value(Graph, {node_a,node_c}) =:= undefined end),
    %% Reltool's force layout redraws around 25 Hz even when nothing changes.
    timer:sleep(250),
    true = is_process_alive(Graph),
    {links, Links} = process_info(Graph, links),
    Tickers = Links -- [self()],
    %% shutdown also terminates the linked ticker; normal would leave it waiting.
    ok = reltool_fgraph_win:stop(Graph, shutdown),
    await(fun() -> lists:all(fun(P) -> not is_process_alive(P) end, Tickers) end),
    wxFrame:destroy(Frame), wx:destroy(),
    io:format("PASS: embedded native Reltool graph, live node/link updates, four colours, shutdown cleanup~n"),
    halt().

value(Graph, Key) ->
    {dictionary, Pairs} = process_info(Graph, dictionary),
    case proplists:get_value(Key, Pairs) of
        {Key, Value} -> Value;
        undefined -> undefined
    end.
await(Fun) -> await(Fun, 100).
await(_, 0) -> error(graph_probe_timeout);
await(Fun, N) ->
    case Fun() of true -> ok; false -> timer:sleep(20), await(Fun, N-1) end.
