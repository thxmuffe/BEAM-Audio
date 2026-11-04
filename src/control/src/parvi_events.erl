%% Local runtime invalidations. Observers read state through existing APIs.
-module(parvi_events).
-export([subscribe/0, notify/1]).
-define(GROUP, {parvi, local_observers}).

subscribe() ->
    try
        Pg = whereis(parvi_pg), true = is_pid(Pg),
        ok = pg:join(parvi_pg, ?GROUP, self()), {ok, Pg}
    catch _:_ -> {error, not_started} end.

notify(Topic) ->
    try
        [Pid ! {parvi_changed, Topic} || Pid <- pg:get_local_members(parvi_pg, ?GROUP)]
    catch _:_ -> ok end,
    ok.
