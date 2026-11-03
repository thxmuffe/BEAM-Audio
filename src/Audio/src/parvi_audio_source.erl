%% A publication is a supervised process; pg owns discovery membership.
-module(parvi_audio_source).
-behaviour(gen_server).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Offer) -> gen_server:start_link(?MODULE, Offer, []).

init(Offer) when is_map(Offer) -> init({Offer, undefined});
init({Offer, Owner}) ->
    ok = parvi_audio:validate_offer(Offer),
    ok = pg:join(parvi_pg, {parvi, audio, sources}, self()),
    Ref = case Owner of undefined -> undefined; _ -> monitor(process, Owner) end,
    {ok, #{offer => Offer, handler => parvi_audio_stream_handler:default(),
           sessions => #{}, owner => Owner, owner_monitor => Ref}}.

handle_call(describe, _, #{offer := Offer} = S) ->
    %% Fixed request shapes, not a generic schema/query language.
    Requirements = #{required => [profile, selector],
        channel => #{selectors => [all, channels]},
        point => #{selectors => [all, sphere], sphere => [x, y, z, radius]}},
    {reply, Offer#{source => self(), node => node(), request => Requirements}, S};
handle_call({subscribe, Request}, {Receiver, _}, #{offer := Offer, sessions := Sessions} = S) ->
    case parvi_audio:validate_request(Request, Offer) of
        {ok, Descriptor} ->
            case parvi_audio_sup:start_session({provider, self(), Receiver, Request, Descriptor}) of
                {ok, Provider} ->
                    Ref = monitor(process, Provider),
                    {reply, {ok, Provider, Descriptor}, S#{sessions := Sessions#{Ref => Provider}}};
                Error -> {reply, Error, S}
            end;
        Error -> {reply, Error, S}
    end;
handle_call({push_encoded, Timing, Packet}, {Owner,_},
    #{owner := Owner, offer := #{profiles := #{channel := #{stream_handler := webrtc_audio_opus}}},
      sessions := Sessions} = S) when is_map(Timing), is_binary(Packet), byte_size(Packet) =< 1275 ->
    [gen_statem:cast(Pid,{encoded,self(),Timing,Packet}) || Pid <- maps:values(Sessions)],
    {reply,ok,S};
handle_call({push, Profile, Header, PCM}, {Producer, _},
            #{offer := #{profiles := Profiles}, sessions := Sessions, handler := Handler} = S)
        when is_map(Header), node(Producer) =:= node() ->
    case maps:find(Profile, Profiles) of
        {ok, Descriptor} ->
            case Handler:validate_block(Profile, Descriptor, Header#{sequence => 0}, PCM) of
                ok ->
                    Results = [{Pid, deliver(Pid, Profile, Header, PCM)} || Pid <- maps:values(Sessions)],
                    {reply, {ok, Results}, S};
                Error -> {reply, Error, S}
            end;
        error -> {reply, {error, unsupported_profile}, S}
    end;
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.

deliver(Pid, Profile, Header, PCM) ->
    try gen_statem:call(Pid, {push, Profile, Header, PCM})
    catch exit:Reason -> {error, {session_unavailable, Reason}} end.

handle_cast(_, S) -> {noreply, S}.
handle_info({'DOWN', Ref, process, _, _}, #{owner_monitor := Ref} = S) ->
    {stop, normal, S};
handle_info({'DOWN', Ref, process, _, _}, #{sessions := Sessions} = S) ->
    {noreply, S#{sessions := maps:remove(Ref, Sessions)}};
handle_info(_, S) -> {noreply, S}.
