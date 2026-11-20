%% HTTP is only an adapter. Device policy and snapshots stay in ba_device_api.
-module(ba_device_web_handler).
-export([init/2]).
-define(MAX_REQUEST,16384).
-define(MAX_REPLY,2000000).

init(Req,State) ->
    Reply=case local_request(Req) of
        true -> route(cowboy_req:method(Req),cowboy_req:path(Req),Req,State);
        false -> reply(403,#{error => <<"Same-origin local requests only.">>},Req)
    end,
    {ok,Reply,State}.

local_request(Req) ->
    Origin=ba_device_web_sup:origin(),
    Host=binary:part(Origin,7,byte_size(Origin)-7),
    cowboy_req:header(<<"host">>,Req)=:=Host andalso
    cowboy_req:header(<<"origin">>,Req,Origin)=:=Origin andalso
    lists:member(cowboy_req:header(<<"sec-fetch-site">>,Req,<<"same-origin">>),
                 [<<"same-origin">>,<<"none">>]).

route(<<"GET">>,<<"/api/session">>,Req,#{mode := Mode}) ->
    reply(200,#{mode => Mode,device_name => ba_device_label:display(unicode:characters_to_binary(ba_device_label:os_name())),token => ba_device_web_sup:token()},Req);
route(<<"POST">>,<<"/api/command">>,Req,State) ->
    Token=ba_device_web_sup:token(),
    Given=cowboy_req:header(<<"x-beam-audio-token">>,Req,<<>>),
    case byte_size(Given)=:=byte_size(Token) andalso crypto:hash_equals(Token,Given) of
        true -> command_body(Req,State);
        false -> reply(403,#{error => <<"Invalid local session.">>},Req)
    end;
%% Push: each open Session's state, sent only when it changed.
route(<<"GET">>,<<"/api/events">>,Req,#{mode := preview}) -> reply(409,#{error => <<"Preview has no live Device.">>},Req);
route(<<"GET">>,<<"/api/events">>,Req,State) ->
    Token=ba_device_web_sup:token(),
    Given=cowboy_req:header(<<"x-beam-audio-token">>,Req,<<>>),
    case byte_size(Given)=:=byte_size(Token) andalso crypto:hash_equals(Token,Given) of
        true -> events(Req,State);
        false -> reply(403,#{error => <<"Invalid local session.">>},Req)
    end;
route(<<"GET">>,Path,Req,State) -> asset(Path,Req,State);
route(_,_,Req,_) -> reply(404,#{error => <<"Unknown endpoint.">>},Req).

command_body(Req,State) ->
    case cowboy_req:body_length(Req) of
        N when is_integer(N),N > ?MAX_REQUEST -> reply(413,#{error => <<"Invalid request size.">>},Req);
        _ ->
            Type=try cowboy_req:parse_header(<<"content-type">>,Req) catch _:_ -> invalid end,
            case Type of
                {<<"application">>,<<"json">>,_} ->
                    read_command(Req,State,<<>>,erlang:monotonic_time(millisecond)+5000);
                _ -> reply(415,#{error => <<"Use application/json.">>},Req)
            end
    end.

read_command(Req,State,Acc,Deadline) ->
    %% read_body's length is a read threshold, not a hard body-size limit.
    %% Count every chunk as well as checking Content-Length above.
    Remaining=Deadline-erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> reply(408,#{error => <<"Request body timed out.">>},Req);
        true -> read_chunk(Req,State,Acc,Deadline,Remaining)
    end.

read_chunk(Req,State,Acc,Deadline,Remaining) ->
    case cowboy_req:read_body(Req,#{length => ?MAX_REQUEST+1,period => Remaining}) of
        {_,Part,Next} when byte_size(Acc)+byte_size(Part) > ?MAX_REQUEST ->
            reply(413,#{error => <<"Invalid request size.">>},Next);
        {more,Part,Next} -> read_command(Next,State,<<Acc/binary,Part/binary>>,Deadline);
        {ok,Part,Next} ->
            Body = <<Acc/binary,Part/binary>>,
            try json:decode(Body) of
                Command ->
                    case allowed(Command) of
                        true -> dispatch(Command,Next,State);
                        false -> reply(400,#{error => <<"Unsupported command.">>},Next)
                    end
            catch error:_ -> reply(400,#{error => <<"Invalid request or Device response.">>},Next) end
    end.

allowed(#{<<"method">> := Method}=Command) ->
    not maps:is_key(<<"instance">>,Command) andalso lists:member(Method,ba_device_api:client_methods());
allowed(_) -> false.

dispatch(_,Req,#{mode := preview}) ->
    reply(409,#{error => <<"Preview has no live Device.">>},Req);
dispatch(Command,Req,State) ->
    try device_request(Command,State) of
        Result when is_map(Result) ->
            %% Never expose the local socket credential or process metadata.
            Public=case maps:find(<<"managed">>,Result) of
                {ok,Managed} when is_map(Managed) ->
                    Result#{<<"managed">> := maps:with([<<"name">>],Managed)};
                _ -> Result
            end,
            Body=iolist_to_binary(json:encode(Public)),
            case byte_size(Body) =< ?MAX_REPLY of
                true -> respond(200,<<"application/json; charset=utf-8">>,Body,Req);
                false -> reply(503,#{error => <<"Device response too large.">>},Req)
            end
    catch _:_ -> reply(503,#{error => <<"Device unavailable. Check that the selected runtime is running.">>},Req) end.

device_request(Command,#{record := Path}) ->
    {ok,Bytes}=file:read_file(Path),
    Record=json:decode(Bytes),
    %% Reuse the CLI's instance-checked, bounded local socket protocol.
    {ok,Result}=ba_cli_device:call(Record,Command),
    Result;
device_request(Command,_) ->
    %% The service is optional: it never creates a Device or enables audio.
    true=is_pid(whereis(ba_sup)),
    ba_sessions:request(Command).

%% The Device's state is looked at every ?EVENT_MS ms on this side; the window
%% only hears about it when what it shows has changed. A closed connection ends
%% this process (Cowboy stops the stream), so there is nothing to clean up.
-define(EVENT_MS,300).
events(Req0,State) ->
    Req=cowboy_req:stream_reply(200,#{<<"content-type">> => <<"text/event-stream">>,<<"cache-control">> => <<"no-store">>,
        <<"x-content-type-options">> => <<"nosniff">>},Req0),
    events(Req,State,#{},erlang:monotonic_time(millisecond)).
events(Req,State,Sent,Beat) ->
    Next=try
        Listing=public(device_request(#{<<"method">> => <<"list_sessions">>},State)),
        Tabs=maps:get(<<"sessions">>,Listing,[]),
        S1=send_if_changed(Req,sessions,#{<<"type">> => <<"sessions">>,<<"sessions">> => Tabs},Sent),
        lists:foldl(fun(#{<<"id">> := Id},Acc) ->
            Snap=public(device_request(#{<<"method">> => <<"snapshot">>,<<"session">> => Id},State)),
            send_if_changed(Req,{session,Id},#{<<"type">> => <<"session">>,<<"session_id">> => Id,<<"snapshot">> => view(Snap)},Acc)
        end,S1,Tabs)
    catch _:_ -> Sent end,
    Now=erlang:monotonic_time(millisecond),
    %% A comment line now and then keeps idle connections open.
    NextBeat=case Now-Beat > 15000 of true -> cowboy_req:stream_body(<<": keep-alive\n\n">>,nofin,Req),Now;false -> Beat end,
    timer:sleep(?EVENT_MS),
    events(Req,State,Next,NextBeat).
send_if_changed(Req,Key,Event,Sent) ->
    Body=iolist_to_binary(json:encode(Event)),
    case maps:get(Key,Sent,undefined)=:=Body of
        true -> Sent;
        false -> cowboy_req:stream_body([<<"data: ">>,Body,<<"\n\n">>],nofin,Req),Sent#{Key => Body}
    end.
public(Result) -> json:decode(iolist_to_binary(json:encode(Result))).
%% What the window shows, without readings that change on every look.
view(Snap) ->
    Clock=maps:with([<<"state">>,<<"offset_policy">>],maps:get(<<"clock">>,Snap,#{})),
    Handler=#{<<"audio">> => maps:map(fun(_,R) when is_map(R) -> maps:with([<<"state">>,<<"error">>],R);(_,R) -> R end,
                                      maps:get(<<"audio">>,maps:get(<<"handler">>,Snap,#{}),#{}))},
    Audio0=maps:get(<<"audio">>,Snap,#{}),
    Audio=#{<<"offers">> => [maps:with([<<"device">>,<<"source_key">>],O) || O <- maps:get(<<"offers">>,Audio0,[]),is_map(O)],
            <<"subscriptions">> => maps:map(fun(_,I) when is_map(I) -> maps:with([<<"state">>,<<"device">>,<<"playing">>],I);(_,I) -> I end,
                                           maps:get(<<"subscriptions">>,Audio0,#{}))},
    Managed=maps:with([<<"name">>],maps:get(<<"managed">>,Snap,#{})),
    (maps:without([<<"desks">>,<<"diagnostics">>,<<"passport">>,<<"request_id">>],Snap))#{
        <<"clock">> => Clock,<<"handler">> => Handler,<<"audio">> => Audio,<<"managed">> => Managed}.

asset(Path,Req,#{assets := Root}) ->
    %% Only direct children; never serve credentials or arbitrary host files.
    Name=case Path of <<"/">> -> <<"index.html">>;<<"/",Rest/binary>> -> Rest end,
    case byte_size(Name)>0 andalso binary:match(Name,<<"/">>)=:=nomatch andalso
         binary:match(Name,<<"\\">>)=:=nomatch andalso
         Name=/=<<".">> andalso Name=/=<<"..">> andalso
         binary:at(Name,0)=/=$. andalso mime(filename:extension(Name))=/=undefined of
        true ->
            case file:read_file(filename:join(Root,binary_to_list(Name))) of
                {ok,Bytes} -> respond(200,mime(filename:extension(Name)),Bytes,Req);
                _ -> reply(404,#{error => <<"Not found.">>},Req)
            end;
        false -> reply(404,#{error => <<"Not found.">>},Req)
    end;
asset(_,Req,_) -> reply(404,#{error => <<"No frontend configured.">>},Req).

mime(<<".md">>) -> <<"text/plain; charset=utf-8">>;
mime(<<".html">>) -> <<"text/html; charset=utf-8">>;
mime(<<".css">>) -> <<"text/css; charset=utf-8">>;
mime(<<".js">>) -> <<"application/javascript">>;
mime(<<".mjs">>) -> <<"application/javascript">>;
mime(<<".svg">>) -> <<"image/svg+xml">>;
mime(<<".png">>) -> <<"image/png">>;
mime(<<".ico">>) -> <<"image/x-icon">>;
mime(_) -> undefined.

reply(Status,Data,Req) ->
    respond(Status,<<"application/json; charset=utf-8">>,json:encode(Data),Req).
respond(Status,Type,Body,Req) ->
    cowboy_req:reply(Status,#{<<"content-type">> => Type,
        <<"cache-control">> => <<"no-store">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"content-security-policy">> => <<"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'">>},Body,Req).
