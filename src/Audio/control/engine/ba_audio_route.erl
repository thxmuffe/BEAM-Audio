%% How audio reaches another Device: the connectivity configuration handed to
%% the engine's ICE connections (libjuice) and noticing local network changes.
%% ICE itself (candidates, checks, path choice, STUN, TURN) runs in libjuice;
%% Erlang decides when to connect and carries the descriptions in signed
%% Session messages (ba_engine_media_session).
-module(ba_audio_route).
-export([ice_config/0,interfaces/0]).

%% STUN for public addresses, TURN relays for networks hole punching cannot
%% cross (symmetric carrier NAT). TURN servers come from configuration:
%% audio_turn_servers = [#{host,port,username,password}]. Pass hostnames through:
%% libjuice resolves them on its resolver thread and probes the STUN addresses
%% returned by the system. Resolving here and taking only the first address
%% discards other address families before ICE can check them.
ice_config() ->
    Stun=case ba_settings:app(direct_stun_urls,[]) of
        [First|_] -> {Host,Port}=stun(First),[list_to_binary(Host),Port];
        [] -> undefined
    end,
    Turn=[[unicode:characters_to_binary(H),P,U,W] || #{host := H,port := P,username := U,password := W}
        <- ba_settings:app(audio_turn_servers,[])],
    #{stun => Stun,turn => Turn}.
stun(Url) ->
    ["stun",Host|Rest]=string:split(binary_to_list(Url),":",all),
    {Host,case Rest of [P] -> list_to_integer(P);[] -> 3478 end}.

%% This Device's usable addresses; a change means its network changed and its
%% connections must be set up again (ICE restart).
interfaces() ->
    {ok,Interfaces}=inet:getifaddrs(),
    lists:usort([A || {_,Options} <- Interfaces,
        lists:member(up,proplists:get_value(flags,Options,[])),
        lists:member(running,proplists:get_value(flags,Options,[])),
        {addr,A} <- Options,usable(A)]).
usable({127,_,_,_}) -> false;
usable({169,254,_,_}) -> false;
usable({_,_,_,_}) -> true;
usable({16#fe80,_,_,_,_,_,_,_}) -> false;
usable({0,0,0,0,0,0,0,1}) -> false;
usable({_,_,_,_,_,_,_,_}) -> true.
