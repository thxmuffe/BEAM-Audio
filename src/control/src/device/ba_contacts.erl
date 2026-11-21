%% Device-local memory of Sessions. Individual Devices are not kept as a list:
%% this Device remembers Sessions (and their invitation links), and only the
%% last name seen for each Device so its rows stay readable while it is away.
-module(ba_contacts).
-behaviour(gen_server).
-export([start_link/0,list/0,observe/3,observe_name/2]).
%% Sessions memory: every Session this Device has known, by Session id, with its
%% name, its original invitation link and the Devices seen there. It only grows:
%% a Device is never removed, a kicked one keeps its place with status kicked.
-export([link/1,kicked/2,rename_session/2,forget_session/1,forgotten/1]).
%% Only the person removes an entry; nothing is forgotten automatically.
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
observe(Session,Name,Ids) -> gen_server:cast(?MODULE,{observe,Session,Name,Ids}).
observe_name(Id,Name) -> gen_server:cast(?MODULE,{observe_name,Id,Name}).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
list() -> gen_server:call(?MODULE,list).
link(Link) -> gen_server:cast(?MODULE,{link,Link}).
kicked(Session,Device) -> gen_server:cast(?MODULE,{kicked,Session,Device}).
rename_session(Session,Name) -> gen_server:call(?MODULE,{rename_session,Session,Name}).
forget_session(Session) -> gen_server:call(?MODULE,{forget_session,Session}).
%% Keep only the ID of a forgotten Session, so background observations and
%% saved return records cannot recreate it. An explicit link remembers it again.
forgotten(Session) -> forgotten(Session,ba_settings:get(contacts,#{})).
forgotten(Session,S) -> maps:is_key(Session,maps:get(forgotten_sessions,S,#{})).
init([]) ->
    S=prune(migrate(ba_settings:get(contacts,#{}))),
    ok=ba_settings:put(contacts,S),{ok,S}.
%% Earlier versions kept saved Devices and groups (once also each Session as a
%% group named after it). Session groups become Session entries and saved
%% Device names become the name cache; the lists themselves are dropped.
migrate(S0) ->
    Groups=maps:get(groups,S0,#{}),Links=maps:get(session_groups,S0,#{}),
    Sessions=maps:fold(fun(Session,Group,Acc) ->
        case maps:is_key(Session,Acc) of
            true -> Acc;
            false -> Acc#{Session => #{name => Group,link => null,devices => maps:from_keys(maps:get(Group,Groups,[]),member)}}
        end end,maps:get(sessions,S0,#{}),Links),
    Names=maps:merge(maps:get(contacts,S0,#{}),maps:get(names,S0,#{})),
    (maps:without([contacts,groups,session_groups,auto_names],S0))#{sessions => Sessions,names => Names}.
handle_call(list,_,S) -> {reply,maps:with([sessions,names],S),S};
handle_call({forget_session,Session},_,S) ->
    Sessions=maps:get(sessions,S,#{}),
    case maps:is_key(Session,Sessions) of
        true -> Forgotten=maps:get(forgotten_sessions,S,#{}),
            Next=prune(S#{sessions := maps:remove(Session,Sessions),forgotten_sessions => Forgotten#{Session => true}}),
            ok=ba_settings:put(contacts,Next),{reply,ok,Next};
        false -> {reply,{error,unknown_session},S}
    end;
handle_call({rename_session,Session,Name},_,S) ->
    Sessions=maps:get(sessions,S,#{}),
    case maps:find(Session,Sessions) of
        {ok,E} -> case label(Name) of
            true -> Next=S#{sessions := Sessions#{Session => E#{name := Name}}},ok=ba_settings:put(contacts,Next),{reply,ok,Next};
            false -> {reply,{error,invalid_session_name},S}
        end;
        error -> {reply,{error,unknown_session},S}
    end;
handle_call(_,_,S) -> {reply,{error,unsupported},S}.
label(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<128 -> is_list(unicode:characters_to_list(B));
label(_) -> false.
handle_cast({observe,Session,Name,Ids},S) ->
    try
        true=ba_hex:valid(Session,32),true=label(Name),
        true=not forgotten(Session,S),
        true=is_list(Ids) andalso length(Ids)=<32,
        true=lists:all(fun(Id) -> ba_hex:valid(Id,64) end,Ids),
        persist(seen(Session,Name,Ids,S),S)
    catch error:{badmatch,false} -> {noreply,S} end;
%% The first link known for a Session is kept: it is the Session's permanent invitation.
handle_cast({link,Link},S) ->
    try
        {_,I}=ba_session_passport:parse_invitation(Link),
        Session=maps:get(<<"session">>,I),Sessions=maps:get(sessions,S,#{}),
        E=maps:get(Session,Sessions,#{name => maps:get(<<"name">>,I),link => null,devices => #{}}),
        Linked=case maps:get(link,E) of null -> E#{link := Link};_ -> E end,
        persist(S#{sessions => Sessions#{Session => Linked#{last => now_s()}},
                   forgotten_sessions => maps:remove(Session,maps:get(forgotten_sessions,S,#{}))},S)
    catch _:_ -> {noreply,S} end;
handle_cast({kicked,Session,Device},S) ->
    Sessions=maps:get(sessions,S,#{}),
    case maps:find(Session,Sessions) of
        {ok,#{devices := D}=E} -> persist(S#{sessions => Sessions#{Session => E#{devices := D#{Device => kicked}}}},S);
        error -> {noreply,S}
    end;
handle_cast({observe_name,Id,Name},S) ->
    case ba_hex:valid(Id,64) andalso name_label(Name) of
        true -> persist(S#{names := (maps:get(names,S))#{Id => Name}},S);
        false -> {noreply,S}
    end;
handle_cast(_,S) -> {noreply,S}.
persist(S,S) -> {noreply,S};
persist(Next,_) -> ok=ba_settings:put(contacts,Next),{noreply,Next}.
%% Devices are added, never removed; one seen again as a member is a member again.
seen(Session,Name,Ids,S) ->
    Sessions=maps:get(sessions,S,#{}),
    E=maps:get(Session,Sessions,#{name => Name,link => null,devices => #{}}),
    D=lists:foldl(fun(Id,Acc) -> Acc#{Id => member} end,maps:get(devices,E),Ids),
    S#{sessions => Sessions#{Session => E#{devices := D,last => now_s()}}}.
%% When this Device last took part, for listing Sessions most recent first.
now_s() -> erlang:system_time(second).
name_label(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<256 -> is_list(unicode:characters_to_list(B));
name_label(_) -> false.
%% A name is kept only while some remembered Session lists that Device.
prune(#{sessions := Sessions,names := Names}=S) ->
    Seen=lists:foldl(fun(#{devices := D},Acc) -> maps:merge(Acc,D) end,#{},maps:values(Sessions)),
    S#{names := maps:with(maps:keys(Seen),Names)}.
handle_info(_,S) -> {noreply,S}.
