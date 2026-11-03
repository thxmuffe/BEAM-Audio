%% One supervised endpoint per side; control requests never carry audio bodies.
-module(parvi_audio_subscription).
-behaviour(gen_statem).
-export([start_link/1, callback_mode/0, init/1, handle_event/4, terminate/3]).
-define(SETUP_TIMEOUT, 5000).

start_link(Args) -> gen_statem:start_link(?MODULE, Args, []).
callback_mode() -> handle_event_function.

init(receiver) ->
    receiver(#{});
init({receiver, Owner}) when is_pid(Owner), node(Owner) =:= node() ->
    receiver(#{owner_monitor => monitor(process, Owner)});
init({provider, Source, Receiver, Request, Descriptor}) ->
    {ok, waiting_ready, #{role => provider, handler => parvi_audio_stream_handler:default(), source => Source,
        source_monitor => monitor(process, Source), peer => Receiver,
        peer_monitor => monitor(process, Receiver), request => Request,
        descriptor => Descriptor, sequence => 0, sent => 0}, [setup_timeout()]}.

receiver(Extra) ->
    {ok, idle, Extra#{role => receiver, handler => parvi_audio_stream_handler:default(), received => 0, received_bytes => 0,
        invalid_packets => 0, sequence_gaps => 0, reordered => 0}, [setup_timeout()]}.

handle_event({call, From}, {open, Source, Request}, idle, #{role := receiver} = D) ->
    Ref = monitor(process, Source),
    Id = gen_server:send_request(Source, {subscribe, Request}),
    {next_state, opening, D#{source => Source, source_monitor => Ref,
        request => Request, pending => Id, caller => From}, [setup_timeout()]};
handle_event({call, From}, ready, accepted, #{role := receiver, peer := Peer} = D) ->
    Token = crypto:strong_rand_bytes(16),
    case bind(expect, Token, D) of
        {ok, Next} ->
            Id = gen_statem:send_request(Peer, {ready, Token}),
            {next_state, activating, Next#{pending => Id, caller => From,
                peer_ready => false, media_open => false}, [setup_timeout()]};
        {error, Reason} -> stop(Reason, D#{caller => From})
    end;
handle_event({call, {Owner, _} = From}, {ready, Token}, waiting_ready,
             #{role := provider, peer := Owner} = D) ->
    case bind(open, Token, D) of
        {ok, Next} ->
            {next_state, activating, Next#{caller => From}, [setup_timeout()]};
        {error, Reason} -> stop(Reason, D#{caller => From})
    end;
handle_event({call, From}, ready, active, #{role := receiver}) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {listen, Consumer}, _, #{role := receiver} = D)
        when is_pid(Consumer), node(Consumer) =:= node() ->
    case maps:find(consumer_monitor, D) of {ok, Old} -> demonitor(Old, [flush]); error -> ok end,
    {keep_state, D#{consumer => Consumer, consumer_monitor => monitor(process, Consumer)},
        [{reply, From, ok}]};
handle_event({call, {Source, _} = From}, {push, Profile, H, PCM}, active,
             #{role := provider, source := Source} = D) ->
    {Reply, Next} = send_packet(Profile, H, PCM, D),
    {keep_state, Next, [{reply, From, Reply}]};
handle_event({call, From}, status, State, D) ->
    Public = maps:with([role, source, peer, request, descriptor, sent, received,
        received_bytes, invalid_packets, sequence_gaps, reordered, last_header], D),
    Media = case State of active -> open; activating -> opening; _ -> closed end,
    Handler = maps:get(handler, D),
    {keep_state_and_data, [{reply, From, Public#{state => State, media => Media, backend => Handler:info()}}]};
handle_event({call, From}, _, _, _) ->
    {keep_state_and_data, [{reply, From, {error, invalid_state_or_owner}}]};
handle_event(info, {media, Ctrl, Token, open}, activating,
             #{controller := Ctrl, token := Token, role := provider} = D) ->
    {next_state, active, clear_pending(D), [{reply, maps:get(caller, D), ok}]};
handle_event(info, {media, Ctrl, Token, open}, activating,
             #{controller := Ctrl, token := Token, role := receiver} = D) ->
    activate(D#{media_open := true});
handle_event(info, {media, Ctrl, Token, closed}, _, #{controller := Ctrl, token := Token} = D) ->
    stop(media_closed, D);
handle_event(info, {media, Ctrl, Token, {packet, Packet}}, State,
             #{controller := Ctrl, token := Token, role := receiver} = D)
        when State =:= active; State =:= activating ->
    %% Media can overtake the ready reply on the independent control channel.
    {keep_state, receive_packet(Packet, D)};
handle_event(info, {'DOWN', Ref, process, _, Reason}, _, D) ->
    case lists:member(Ref, [maps:get(source_monitor, D, undefined),
                          maps:get(peer_monitor, D, undefined),
                          maps:get(owner_monitor, D, undefined),
                          maps:get(controller_monitor, D, undefined)]) of
        true -> stop({dependency_down, Reason}, D);
        false ->
            case maps:get(consumer_monitor, D, undefined) of
                Ref -> {keep_state, maps:without([consumer, consumer_monitor], D)};
                _ -> keep_state_and_data
            end
    end;
handle_event(info, Message, opening, #{pending := Id} = D) ->
    response(gen_server:check_response(Message, Id), opening, D);
handle_event(info, Message, activating, #{pending := Id} = D) ->
    response(gen_statem:check_response(Message, Id), activating, D);
handle_event(state_timeout, setup_timeout, _, D) -> stop(setup_timeout, D);
handle_event(_, _, _, _) -> keep_state_and_data.

bind(Action, Token, #{peer := Peer, handler := Handler} = D) ->
    case Handler:bind(Action, Token, node(Peer)) of
        {ok, Ctrl} ->
            {ok, D#{controller => Ctrl, controller_monitor => monitor(process, Ctrl), token => Token}};
        Error -> Error
    end.

response({reply, {ok, Peer, Descriptor}}, opening, D) when is_pid(Peer), is_map(Descriptor) ->
    From = maps:get(caller, D),
    Next = clear_pending(D),
    {next_state, accepted, Next#{peer => Peer, peer_monitor => monitor(process, Peer),
        descriptor => Descriptor},
        [{reply, From, {ok, self(), Descriptor}}, setup_timeout()]};
response({reply, ok}, activating, D) -> activate(D#{peer_ready := true});
response({reply, {error, Reason}}, _, D) -> stop(Reason, D);
response({error, Reason}, _, D) -> stop(Reason, D);
response(no_reply, _, _) -> keep_state_and_data;
response({reply, _}, _, D) -> stop(invalid_reply, D).

activate(#{peer_ready := true, media_open := true} = D) ->
    {next_state, active, clear_pending(D), [{reply, maps:get(caller, D), ok}]};
activate(D) -> {keep_state, D}.

send_packet(Profile, H, PCM, #{request := #{profile := Profile, selector := Selector},
                             descriptor := Descriptor, sequence := Seq, handler := Handler} = D) ->
    case Handler:encode(Profile, Descriptor, Selector, H#{sequence => Seq}, PCM) of
        filtered -> {filtered, D};
        {ok, Packet} ->
            Result = Handler:send(maps:get(controller, D), maps:get(token, D), Packet),
            Next = D#{sequence := (Seq + 1) band 16#ffffffff},
            case Result of
                ok -> {ok, Next#{sent := maps:get(sent, D) + 1}};
                _ -> {Result, Next}
            end;
        {error, _} = Error -> {Error, D}
    end;
send_packet(_, _, _, D) -> {filtered, D}.

receive_packet(Packet, #{request := #{profile := Profile}, descriptor := Descriptor, handler := Handler} = D) ->
    case Handler:decode(Profile, Descriptor, Packet) of
        {ok, Header, PCM} ->
            case maps:find(consumer, D) of
                {ok, Consumer} -> Consumer ! {parvi_audio, self(), Header, PCM};
                error -> ok
            end,
            Next = track_sequence(maps:get(sequence, Header), D),
            Next#{received := maps:get(received, D) + 1,
                  received_bytes := maps:get(received_bytes, D) + byte_size(PCM), last_header => Header};
        {error, _} -> D#{invalid_packets := maps:get(invalid_packets, D) + 1}
    end.

track_sequence(Seq, #{last_sequence := Last} = D) ->
    Delta = (Seq - Last) band 16#ffffffff,
    case Delta > 0 andalso Delta < 16#80000000 of
        true -> D#{last_sequence := Seq, sequence_gaps := maps:get(sequence_gaps, D) + Delta - 1};
        false -> D#{reordered := maps:get(reordered, D) + 1}
    end;
track_sequence(Seq, D) -> D#{last_sequence => Seq}.

setup_timeout() -> {state_timeout, ?SETUP_TIMEOUT, setup_timeout}.
clear_pending(D) -> maps:without([pending, caller], D).
stop(Reason, D) ->
    Actions = case maps:find(caller, D) of
        {ok, From} -> [{reply, From, {error, Reason}}];
        error -> []
    end,
    {stop_and_reply, normal, Actions, clear_pending(D)}.

terminate(_, _, D) ->
    %% The controller also monitors us, including when this callback cannot run.
    case maps:find(controller, D) of
        {ok, Ctrl} ->
            Handler = maps:get(handler, D),
            Handler:close(Ctrl, maps:get(token, D));
        error -> ok
    end,
    case maps:find(caller, D) of
        {ok, From} -> gen_statem:reply(From, {error, closed});
        error -> ok
    end.
