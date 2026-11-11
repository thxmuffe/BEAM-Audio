%% Ownership is trusted administration, independent of participation and placement.
-module(ba_buffee_roles).
-export([owner/2,chef/2,roles/2,change/4,initial/1,may_publish/2]).

owner(Id,P) -> lists:member(<<"owner">>,permissions(Id,P)).
chef(Id,P) -> lists:member(<<"stream_publish">>,permissions(Id,P)).
roles(Id,P) ->
    Participation=case chef(Id,P) of true -> chef;false -> guest end,
    case owner(Id,P) of true -> [owner,Participation];false -> [Participation] end.
initial(Permissions) -> lists:usort([<<"owner">>,<<"stream_publish">>|Permissions]).
may_publish(_,<<"microphone">>) -> true;
may_publish(Roles,_) -> lists:member(chef,Roles).
permissions(Id,#{<<"members">> := Members}) ->
    maps:get(<<"permissions">>,maps:get(Id,Members,#{}),[]).

change(Actor,Device,Action,#{<<"members">> := Members}=P) ->
    case {owner(Actor,P),maps:find(Device,Members)} of
        {false,_} -> {error,owner_only};
        {_,error} -> {error,unknown_device};
        {true,{ok,M}} ->
            Permissions=maps:get(<<"permissions">>,M),
            case update(Action,Permissions) of
                {error,_}=Error -> Error;
                New -> {ok,P#{<<"members">> := Members#{Device := M#{<<"permissions">> := lists:usort(New)}}}}
            end
    end.
update(chef,P) -> [<<"stream_publish">>|P];
update(guest,P) -> lists:delete(<<"stream_publish">>,P);
update(owner,P) -> [<<"owner">>|P];
update(remove_owner,P) -> lists:delete(<<"owner">>,P);
update(_,_) -> {error,invalid_role}.
