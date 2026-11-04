#!/usr/bin/env escript
%% Pure Erlang policy for the standalone proof; no application/cluster startup.
main(_) ->
    Path = filename:join(filename:dirname(escript:script_name()),"../../src/parvi_audio_gstreamer_schedule.erl"),
    {ok,Module,Binary} = compile:file(Path,[binary]),
    {module,Module} = code:load_binary(Module,Path,Binary),
    io:put_chars("ready\n"),
    loop(Module).
loop(Module) ->
    case io:get_line("") of
        eof -> ok;
        Line -> request(Module,Line), loop(Module)
    end.
request(Module,Line) ->
    Request = json:decode(iolist_to_binary(Line)),
    Result = case maps:get(<<"operation">>,Request,<<"schedule">>) of
        <<"rate">> ->
            Module:rate_plan(fields(maps:get(<<"correction">>,Request),[correction_ppm,max_absolute_ppm]),
                fields(maps:get(<<"clock">>,Request),[internal_ns,calibration_internal_ns,
                    calibration_external_ns,rate_numerator,rate_denominator]));
        <<"schedule">> ->
            Target = fields(maps:get(<<"target">>,Request),
                [local_handoff_time_ns,revision,stream_id,clock_timeline]),
            Bridge = fields(maps:get(<<"bridge">>,Request),[offset_ns]),
            Pipeline = fields(maps:get(<<"pipeline">>,Request),
                [host_ns,pipeline_clock_ns,base_time_ns,running_time_ns,pipeline_latency_ns,
                 render_delay_ns,observation_uncertainty_ns]),
            Module:plan(Target,Bridge,Pipeline)
    end,
    Reply = case Result of
        {ok,Plan} -> #{ok => true,plan => Plan};
        {error,Reason} -> #{ok => false,error => Reason}
    end,
    io:put_chars([json:encode(Reply),"\n"]).
fields(Map,Keys) -> maps:from_list([{K,maps:get(atom_to_binary(K),Map)} || K <- Keys]).
