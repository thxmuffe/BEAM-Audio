%% Minimal unicast SNTP measurement (RFC 4330); never sets the OS clock.
%% OTP supplies sockets/time; this module only binds the standard wire exchange.
-module(parvi_sntp).
-export([query/3]).
-define(NS, 1000000000).
-define(EPOCH, 2208988800).
-define(ERA, 4294967296).

query(Host, Port, Timeout) ->
    try
        {ok, Family} = resolve(Host),
        {ok, Address} = inet:getaddr(Host, Family),
        {ok, Socket} = gen_udp:open(0, [Family, binary, {active, false}]),
        try exchange(Socket, Address, Port, Timeout)
        after gen_udp:close(Socket) end
    catch
        throw:Reason -> {error, Reason};
        error:{badmatch, {error, Reason}} -> {error, Reason};
        error:_ -> {error, invalid_ntp_reply}
    end.

resolve(Host) ->
    case application:get_env(parvi, clock_resolver) of
        {ok, {Module, Function}} -> Module:Function(list_to_binary(Host));
        undefined -> {ok, inet}
    end.

exchange(Socket, Address, Port, Timeout) ->
    ok = gen_udp:connect(Socket, Address, Port),
    M1 = erlang:monotonic_time(nanosecond),
    T1 = erlang:system_time(nanosecond),
    Stamp = encode_time(T1),
    ok = gen_udp:send(Socket, <<16#23, 0:312, Stamp:64>>),
    {ok, {Address, Port, Reply}} = gen_udp:recv(Socket, 0, Timeout),
    M4 = erlang:monotonic_time(nanosecond),
    %% Use elapsed monotonic time so an OS wall-clock step during the query
    %% cannot corrupt the four-timestamp calculation.
    T4 = T1 + M4 - M1,
    decode(Reply, Stamp, T1, T4, M1, M4).

decode(<<LI:2, Version:3, 4:3, Stratum:8, _:16,
         RootDelay:32/signed, Dispersion:32, Reference:4/binary, _:64,
         Originate:64, Receive:64, Transmit:64, _/binary>>,
       Originate, T1, T4, M1, M4) when Version =:= 3; Version =:= 4 ->
    case Stratum of 0 -> throw({kiss_of_death, Reference}); _ -> ok end,
    true = LI =/= 3 andalso Stratum < 16 andalso Receive =/= 0 andalso Transmit =/= 0,
    T2 = decode_time(Receive, T1), T3 = decode_time(Transmit, T1),
    true = T3 >= T2,
    Delay = (M4 - M1) - (T3 - T2),
    true = Delay >= -1000000,
    Correction = ((T2 - T1) + (T3 - T4)) div 2,
    Uncertainty = max(0, Delay) div 2 + max(0, RootDelay) * ?NS div 131072 +
                  Dispersion * ?NS div 65536,
    {ok, #{offset_ns => T1 - M1 + Correction, sampled_at => M4,
           round_trip_ns => max(0, Delay), uncertainty_ns => Uncertainty, stratum => Stratum}};
decode(_, _, _, _, _, _) -> {error, invalid_ntp_reply}.

encode_time(Time) ->
    Seconds = Time div ?NS + ?EPOCH,
    Fraction = (Time rem ?NS) * ?ERA div ?NS,
    ((Seconds rem ?ERA) bsl 32) bor Fraction.

decode_time(Stamp, Hint) ->
    Seconds = Stamp bsr 32, Fraction = Stamp band 16#ffffffff,
    HintSeconds = Hint div ?NS + ?EPOCH,
    Era = HintSeconds div ?ERA,
    %% NTP's 32-bit seconds wrap in 2036. Select the era nearest local civil time.
    Candidates = [Seconds + E * ?ERA || E <- [Era - 1, Era, Era + 1]],
    [{_, FullSeconds} | _] = lists:sort([{abs(S - HintSeconds), S} || S <- Candidates]),
    (FullSeconds - ?EPOCH) * ?NS + Fraction * ?NS div ?ERA.
