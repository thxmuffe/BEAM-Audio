%% Device-local address book. Saving a key never grants Swarm permissions.
-module(ba_contacts).
-behaviour(gen_server).
-export([start_link/0,list/0,put/2,delete/1,group/2,delete_group/1,resolve/1,observe/3,observe_name/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
observe(Swarm,Name,Ids) -> gen_server:cast(?MODULE,{observe,Swarm,Name,Ids}).
observe_name(Id,Name) -> gen_server:cast(?MODULE,{observe_name,Id,Name}).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
list() -> gen_server:call(?MODULE,list).
put(Id,Name) -> gen_server:call(?MODULE,{put,Id,Name}).
delete(Id) -> gen_server:call(?MODULE,{delete,Id}).
group(Name,Ids) -> gen_server:call(?MODULE,{group,Name,Ids}).
delete_group(Name) -> gen_server:call(?MODULE,{delete_group,Name}).
resolve(Selection) -> gen_server:call(?MODULE,{resolve,Selection}).
init([]) -> {ok,ba_device_store:load(contacts,#{contacts => #{},groups => #{}})}.
handle_call(list,_,S) -> {reply,maps:with([contacts,groups],S),S};
handle_call({resolve,Selection},_,#{contacts := Contacts,groups := Groups}=S) ->
    Result = try
        Ids = case Selection of {group,Name} -> maps:get(Name,Groups);L when is_list(L) -> L end,
        true = length(Ids)>0 andalso length(Ids)=<15,
        true = lists:usort(Ids)=:=lists:sort(Ids),
        true = lists:all(fun(Id) -> maps:is_key(Id,Contacts) end,Ids),{ok,Ids}
    catch _:_ -> {error,invalid_contact_selection} end,
    {reply,Result,S};
handle_call(Command,_,S) ->
    try update(Command,S) of
        Next -> ok = ba_device_store:save(contacts,Next),{reply,ok,Next}
    catch error:{badmatch,false} -> {reply,{error,invalid_contact_or_group},S};
          error:{badkey,_} -> {reply,{error,unknown_contact},S};
          error:function_clause -> {reply,{error,invalid_contact_or_group},S}
    end.
update({put,Id,Name},#{contacts := Contacts}=S) ->
    true = ba_swarm_job:hex(Id,64),true = contact_label(Name),
    (manual_name(Id,S))#{contacts := Contacts#{Id => Name}};
update({delete,Id},#{contacts := Contacts,groups := Groups}=S) ->
    S#{contacts := maps:remove(Id,Contacts),groups := maps:map(fun(_,Ids) -> lists:delete(Id,Ids) end,Groups)};
update({group,Name,Ids},#{contacts := Contacts,groups := Groups}=S) ->
    true = label(Name),true = is_list(Ids) andalso length(Ids)=<15,
    true = lists:usort(Ids)=:=lists:sort(Ids),
    true = lists:all(fun(Id) -> maps:is_key(Id,Contacts) end,Ids),S#{groups := Groups#{Name => Ids}};
update({delete_group,Name},#{groups := Groups}=S) -> S#{groups := maps:remove(Name,Groups)}.
label(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<128 -> is_list(unicode:characters_to_list(B));
label(_) -> false.
handle_cast({observe,Swarm,Name,Ids},S) ->
    try
        true=ba_swarm_job:hex(Swarm,32),true=label(Name),
        true=is_list(Ids) andalso length(Ids)=<32,
        true=lists:all(fun(Id) -> ba_swarm_job:hex(Id,64) end,Ids),
        Collected=lists:foldl(fun(Id,Acc) -> observed_name(Id,binary:part(Id,0,12),Acc) end,S,lists:usort(Ids)),
        Links=maps:get(swarm_groups,Collected,#{}),Groups=maps:get(groups,Collected),
        Group=case maps:find(Swarm,Links) of
            {ok,Existing} -> Existing;
            error -> case lists:member(Name,maps:values(Links)) of
                false -> Name;
                true -> <<(unicode:characters_to_binary(lists:sublist(unicode:characters_to_list(Name),24)))/binary," | ",(binary:part(Swarm,0,8))/binary>>
            end
        end,
        Members=lists:usort(Ids++maps:get(Group,Groups,[])),
        persist(Collected#{groups := Groups#{Group => Members},swarm_groups => Links#{Swarm => Group}},S)
    catch error:{badmatch,false} -> {noreply,S} end;
handle_cast({observe_name,Id,Name},S) ->
    case ba_swarm_job:hex(Id,64) andalso contact_label(Name) of
        true -> persist(observed_name(Id,Name,S),S);
        false -> {noreply,S}
    end;
handle_cast(_,S) -> {noreply,S}.
persist(S,S) -> {noreply,S};
persist(Next,_) -> ok=ba_device_store:save(contacts,Next),{noreply,Next}.
manual_name(Id,S) ->
    case maps:find(auto_names,S) of
        {ok,Names} -> S#{auto_names := maps:remove(Id,Names)};
        error -> S
    end.
observed_name(Id,Name,#{contacts := Contacts}=S) ->
    Auto=maps:get(auto_names,S,#{}),Fallback=binary:part(Id,0,12),
    case maps:find(Id,Contacts) of
        error -> S#{contacts := Contacts#{Id => Name},auto_names => Auto#{Id => Name}};
        {ok,Old} -> case maps:get(Id,Auto,undefined)=:=Old of
            true when Name=/=Fallback -> S#{contacts := Contacts#{Id => Name},auto_names => Auto#{Id => Name}};
            _ -> S
        end
    end.
contact_label(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<256 -> is_list(unicode:characters_to_list(B));
contact_label(_) -> false.
handle_info(_,S) -> {noreply,S}.
