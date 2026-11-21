%% Each caller owns its cadence. Observations advance through the intervals,
%% and a check without new observations can reschedule at the current interval.
-module(ba_cadence).
-export([new/3,due/2,observe/2,schedule/2]).

new(Intervals,ObservationsPerStep,Now) ->
    schedule(#{intervals => list_to_tuple(Intervals),per_step => ObservationsPerStep,
               observations => 0},Now).

due(#{due := Deadline},Now) -> Now>=Deadline.

observe(#{observations := Count}=Cadence,N) ->
    Cadence#{observations := Count+N}.

schedule(#{intervals := Intervals,per_step := PerStep,observations := Count}=Cadence,Now) ->
    Index=min(tuple_size(Intervals),1+Count div PerStep),
    Cadence#{due => Now+element(Index,Intervals)}.
