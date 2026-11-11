%% Immutable monotonic-to-POSIX mapping. Corrections slew, never step backwards.
-module(ba_buffee_clock_mapping).
-export([new/2, correct/4, offset/2, from_monotonic/2, to_monotonic/2, remaining/2]).
-define(MILLION, 1000000).

new(Mono, Offset) -> #{start => Mono, offset => Offset, target => Offset, ppm => 0}.

correct(Mapping, Mono, Target, PPM) when PPM > 0, PPM < ?MILLION ->
    #{start => Mono, offset => offset(Mapping, Mono), target => Target, ppm => PPM}.

offset(#{start := Start, offset := Base, target := Target, ppm := PPM}, Mono) ->
    Change = min(abs(Target - Base), max(0, Mono - Start) * PPM div ?MILLION),
    Base + direction(Target - Base) * Change.

from_monotonic(Mapping, Mono) -> Mono + offset(Mapping, Mono).
remaining(#{target := Target} = Mapping, Mono) -> Target - offset(Mapping, Mono).

%% Earliest local nanosecond whose mapped time reaches the requested deadline.
to_monotonic(#{start := Start, offset := Base, target := Target, ppm := PPM}, UTC) ->
    StartUTC = Start + Base,
    case PPM =:= 0 orelse UTC =< StartUTC of
        true -> UTC - Base;
        false ->
            Duration = ceil_div(abs(Target - Base) * ?MILLION, PPM),
            EndUTC = Start + Duration + Target,
            case UTC > EndUTC of
                true -> UTC - Target;
                false ->
                    U = UTC - StartUTC,
                    case Target >= Base of
                        true -> Start + ceil_div(U * ?MILLION, ?MILLION + PPM);
                        false -> Start + (U - 1) * ?MILLION div (?MILLION - PPM) + 1
                    end
            end
    end.

direction(N) when N < 0 -> -1;
direction(_) -> 1.
ceil_div(N, D) -> (N + D - 1) div D.
