%% Device-local address book. Saving a key never grants Swarm permissions.
-module(ba_contacts).
-behaviour(gen_server).
-export([start_link/0,list/0,put/2,delete/1,group/2,delete_group/1,resolve/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
list() -> gen_server:call(?MODULE,list).
put(Id,Name) -> gen_server:call(?MODULE,{put,Id,Name}).
delete(Id) -> gen_server:call(?MODULE,{delete,Id}).
group(Name,Ids) -> gen_server:call(?MODULE,{group,Name,Ids}).
delete_group(Name) -> gen_server:call(?MODULE,{delete_group,Name}).
resolve(Selection) -> gen_server:call(?MODULE,{resolve,Selection}).
init([]) -> {ok,ba_device_store:load(contacts,#{contacts => #{},groups => #{}})}.
handle_call(list,_,S) -> {reply,S,S};
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
    true = ba_swarm_job:hex(Id,64),true = label(Name),
    true = map_size(Contacts)<256 orelse maps:is_key(Id,Contacts),
    S#{contacts := Contacts#{Id => Name}};
update({delete,Id},#{contacts := Contacts,groups := Groups}=S) ->
    S#{contacts := maps:remove(Id,Contacts),groups := maps:map(fun(_,Ids) -> lists:delete(Id,Ids) end,Groups)};
update({group,Name,Ids},#{contacts := Contacts,groups := Groups}=S) ->
    true = label(Name),true = is_list(Ids) andalso length(Ids)=<15,
    true = lists:usort(Ids)=:=lists:sort(Ids),
    true = map_size(Groups)<64 orelse maps:is_key(Name,Groups),
    true = lists:all(fun(Id) -> maps:is_key(Id,Contacts) end,Ids),S#{groups := Groups#{Name => Ids}};
update({delete_group,Name},#{groups := Groups}=S) -> S#{groups := maps:remove(Name,Groups)}.
label(B) when is_binary(B),byte_size(B)>0,byte_size(B)=<128 -> is_list(unicode:characters_to_list(B));
label(_) -> false.
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
