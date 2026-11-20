%% Immutable monotonic-to-UTC mapping. Corrections slew, never step backwards.
-module(ba_session_clock_mapping).
-export([new/2, correct/4, offset/2, from_monotonic/2, remaining/2]).
-define(MILLION, 1000000).

new(Mono, Offset) -> #{start => Mono, offset => Offset, target => Offset, ppm => 0}.

correct(Mapping, Mono, Target, PPM) when PPM > 0, PPM < ?MILLION ->
    #{start => Mono, offset => offset(Mapping, Mono), target => Target, ppm => PPM}.

offset(#{start := Start, offset := Base, target := Target, ppm := PPM}, Mono) ->
    Change = min(abs(Target - Base), max(0, Mono - Start) * PPM div ?MILLION),
    Base + direction(Target - Base) * Change.

from_monotonic(Mapping, Mono) -> Mono + offset(Mapping, Mono).
remaining(#{target := Target} = Mapping, Mono) -> Target - offset(Mapping, Mono).

direction(N) when N < 0 -> -1;
direction(_) -> 1.
