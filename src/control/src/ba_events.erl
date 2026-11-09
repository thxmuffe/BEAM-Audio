%% Local runtime invalidations. Observers read state through existing APIs.
-module(ba_events).
-export([subscribe/0, notify/1]).
-define(GROUP, {ba_core, local_observers}).

subscribe() ->
    try
        Pg = whereis(ba_pg), true = is_pid(Pg),
        ok = pg:join(ba_pg, ?GROUP, self()), {ok, Pg}
    catch _:_ -> {error, not_started} end.

notify(Topic) ->
    try
        [Pid ! {ba_changed, Topic} || Pid <- pg:get_local_members(ba_pg, ?GROUP)]
    catch _:_ -> ok end,
    ok.
