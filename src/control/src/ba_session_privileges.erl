%% A Device holds privileges; there are no roles. A holder of `grant` gives and
%% takes back privileges, including its own. Signed wire constants keep their
%% established spelling; Device-facing names are grant, on_air and end_session.
-module(ba_session_privileges).
-export([wire/1,parse/1,names/1,held/2,has/2,has/3,holders/2,creator/1,change/5,may_publish/2,may_edit_settings/1]).

wire(grant) -> <<"owner">>;
wire(on_air) -> <<"stream_publish">>;
wire(end_session) -> <<"end_session">>.

%% Device-API name to wire constant. The two retired spellings are not names.
parse(<<"grant">>) -> wire(grant);
parse(<<"on_air">>) -> wire(on_air);
parse(Name) when Name=/= <<"owner">>,Name=/= <<"stream_publish">> ->
    ok=ba_session_passport:permissions([Name]),Name.
names(Permissions) -> lists:sort([name(P) || P <- Permissions]).
name(<<"owner">>) -> <<"grant">>;
name(<<"stream_publish">>) -> <<"on_air">>;
name(P) -> P.

held(Id,#{<<"members">> := Members}) -> maps:get(<<"permissions">>,maps:get(Id,Members,#{}),[]).
has(Privilege,Permissions) -> lists:member(wire(Privilege),Permissions).
has(Privilege,Id,Policy) -> has(Privilege,held(Id,Policy)).
holders(Privilege,#{<<"members">> := Members}=P) -> [Id || Id <- maps:keys(Members),has(Privilege,Id,P)].

%% Creating a Session is the one grant nobody else approves.
creator(Defaults) -> lists:usort([wire(grant),wire(on_air),wire(end_session)|Defaults]).

%% A microphone may always contribute; any other Source needs on_air.
may_publish(_,<<"microphone">>) -> true;
may_publish(Permissions,_) -> has(on_air,Permissions).
may_edit_settings(Permissions) -> has(grant,Permissions) orelse has(on_air,Permissions).

change(Actor,Device,Op,Wire,#{<<"members">> := Members}=P) when Op=:=grant;Op=:=take ->
    case {has(grant,Actor,P),maps:find(Device,Members)} of
        {false,_} -> {error,grant_required};
        {_,error} -> {error,unknown_device};
        {true,{ok,M}} ->
            Old=maps:get(<<"permissions">>,M),
            New=case Op of grant -> lists:usort([Wire|Old]);take -> lists:delete(Wire,Old) end,
            {ok,P#{<<"members">> := Members#{Device := M#{<<"permissions">> := New}}}}
    end.
