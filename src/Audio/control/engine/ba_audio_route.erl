%% How audio reaches another Device: the connectivity configuration handed to
%% the engine's ICE connections (libjuice) and noticing local network changes.
%% ICE itself (candidates, checks, path choice, STUN, TURN) runs in libjuice;
%% Erlang decides when to connect and carries the descriptions in signed
%% Session messages (ba_engine_media_session).
-module(ba_audio_route).
-export([ice_config/0,interfaces/0]).

%% STUN for public addresses, TURN relays for networks hole punching cannot
%% cross (symmetric carrier NAT). TURN servers come from configuration:
%% audio_turn_servers = [#{host,port,username,password}]. Names are resolved
%% here, in the calling process, so the engine never waits on DNS (libjuice
%% would resolve synchronously); on an IPv6-only network the system resolver
%% returns the translated (NAT64) addresses iOS needs.
ice_config() ->
    Stun=case [Address || Url <- ba_settings:app(direct_stun_urls,[]),Address <- [resolve(stun(Url))],Address=/=none] of
        [First|_] -> First;
        [] -> undefined
    end,
    Turn=[[H,P,U,W] || #{host := Host,port := Port,username := U,password := W} <- ba_settings:app(audio_turn_servers,[]),
        [H,P] <- [resolve({Host,Port})]],
    #{stun => Stun,turn => Turn}.
resolve({Host,Port}) ->
    case net:getaddrinfo(unicode:characters_to_list(Host)) of
        {ok,Found} ->
            case [Ip || #{socktype := dgram,addr := #{addr := Ip}} <- Found] of
                [Ip|_] -> [list_to_binary(inet:ntoa(Ip)),Port];
                [] -> none
            end;
        _ -> none
    end.
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
