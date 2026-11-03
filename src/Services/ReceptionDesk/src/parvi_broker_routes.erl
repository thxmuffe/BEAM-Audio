-module(parvi_broker_routes).
-include_lib("inets/include/httpd.hrl").
-export([do/1]).

do(#mod{data = Data} = Info) ->
    case proplists:get_value(status, Data) of
        undefined ->
            {Code, Type, Body} = route(Info),
            Headers = [{code, Code}, {content_type, Type},
                       {content_length, integer_to_list(byte_size(Body))},
                       {"cache-control", "no-store"},
                       {"x-content-type-options", "nosniff"},
                       {"content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'"}],
            {proceed, [{response, {response, Headers, Body}} | Data]};
        _ -> {proceed, Data}
    end.

route(#mod{method = Method, request_uri = URI} = Info) ->
    Path = hd(string:split(URI, "?")),
    case {Method, Path} of
        {"GET", "/api/nodes"} -> json(200, #{node_ids => parvi_directory:nodes()});
        {"POST", "/api/nodes"} -> register(Info);
        {"GET", "/"} -> json(200, #{service => <<"ReceptionDesk">>, api => <<"/api/nodes">>});
        {_, "/api/nodes"} -> json(405, #{error => <<"Use GET to list or POST to register.">>});
        _ -> json(404, #{error => <<"Not found">>})
    end.

register(#mod{parsed_header = Headers, entity_body = Body}) ->
    Type = proplists:get_value("content-type", Headers, ""),
    case hd(string:split(Type, ";")) of
        "application/json" ->
            try json:decode(iolist_to_binary(Body)) of
                #{<<"node_id">> := Node} ->
                    case parvi_directory:register(Node) of
                        {ok, Nodes} -> json(200, #{node_ids => Nodes, registered_node_id => Node});
                        {error, invalid_node_id} -> json(400, #{error => <<"Use an Erlang node name such as mac@192.168.1.10 (max 255 bytes).">>});
                        {error, directory_full} -> json(503, #{error => <<"Directory limit reached (256 names). Restart to clear it.">>})
                    end;
                _ -> json(400, #{error => <<"JSON must contain node_id." >>})
            catch
                _:_ -> json(400, #{error => <<"Invalid JSON">>})
            end;
        _ -> json(415, #{error => <<"Content-Type must be application/json">>})
    end.

json(Code, Value) -> {Code, "application/json; charset=utf-8", iolist_to_binary(json:encode(Value))}.
