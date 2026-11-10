%% Best-effort crash summaries, using the existing chat worker. Logger calls
%% log/2 on the reporting process: never wait for chat, a peer, or a timeout here.
-module(ba_swarm_log_h).
-behaviour(logger_handler).
-export([log/2]).

log(Event,#{config := #{recipient := Pid}}) ->
    case notice(Event) of
        none -> ok;
        Text ->
            case process_info(Pid,message_queue_len) of
                {message_queue_len,N} when N<16 -> Pid ! {ba_crash_notice,Text};
                _ -> ok
            end
    end,
    ok.

notice(#{msg := {report,#{label := {supervisor,child_terminated},report := Report}}}) ->
    Supervisor=proplists:get_value(supervisor,Report),
    Reason=proplists:get_value(reason,Report),
    Offender=proplists:get_value(offender,Report,[]),
    Module=case proplists:get_value(mfargs,Offender) of
        {M,_,_} when is_atom(M) -> M;
        _ -> proplists:get_value(id,Offender)
    end,
    case own_supervisor(Supervisor) andalso own_name(Module) andalso abnormal(Reason) of
        true ->
            %% Never include exception terms, process state, arguments or IDs.
            Tag=reason_tag(Reason),
            <<"System: ",(atom_to_binary(Module))/binary," stopped (",
              (atom_to_binary(Tag))/binary,").">>;
        false -> none
    end;
notice(_) -> none.

own_supervisor({_,Name}) -> own_name(Name);
own_supervisor(Name) -> own_name(Name).
own_name(Name) when is_atom(Name) -> lists:prefix("ba_",atom_to_list(Name));
own_name(_) -> false.
abnormal(normal) -> false;
abnormal(shutdown) -> false;
abnormal({shutdown,_}) -> false;
abnormal(_) -> true.
reason_tag({{Tag,_},_}) -> reason_tag(Tag);
reason_tag({Tag,_}) -> reason_tag(Tag);
reason_tag(Tag) ->
    case lists:member(Tag,[badarg,badmatch,badkey,badmap,function_clause,case_clause,
                          if_clause,undef,noproc,timeout,killed,system_limit]) of
        true -> Tag;
        false -> error
    end.
