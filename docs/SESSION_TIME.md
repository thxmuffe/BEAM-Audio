# Session time and Response time

## Session time is UTC (owner model, 2026-11-20)

Every Device reads UTC for itself. Nobody follows anybody: there is no clock
master, handover, sample protocol or time permission. Millisecond accuracy is
enough for now (owner decision 2026-11-20).

`ba_session_clock` (one gen_server per Session scope):

- starts usable at once from the Device's system clock;
- asks a time server (`clock_reference`, default `{ntp,"ntp.metas.ch"}`) at
  start and then once a minute (`clock_interval_ms`, default 60000). Each read
  is a burst of four SNTP queries; the reply with the shortest round trip wins,
  because path asymmetry grows with delay;
- maps Erlang monotonic time to UTC. Corrections up to 50 ms slew at
  `clock_slew_ppm` (default 500); larger ones, such as the first server
  answer after a wrong system clock, step;
- on an unreachable server keeps its mapping and shows `last_error`; on a
  kiss-of-death reply stops asking. `clock_reference => system` uses only the
  system clock;
- reads the system clock again at once after a resume or network change
  (`resync/1`), then asks the server, since the monotonic clock may have
  paused. A resync replaces the scheduled read or reuses the in-flight query.

Readers use `session_time/1` and `presentation/1` (times plus the Response
time); `status/0` feeds the monitor and diagnostics. The audio engine receives
the mapping through `ba_audio_engine` clock probes and converges by rate, never
by a step.

Measured from one Mac (2026-11-20, 12 queries to ntp.metas.ch): most readings
agree within ±0.5 ms; slow replies (round trip 54–65 ms against the usual 47)
were off by 3–8 ms, which the minimum-delay burst filters. The difference
between two Devices on different networks has not been measured.

## Response time

The delay between capture and playback that every speaker in the Session uses:
sample n plays at `anchor + Response time + n / rate`.

**Setting.** A signed Session setting held in the membership statement next to
the Session name (`response_ms`, 0–3000 ms, default 150). Grant holders change
it directly; on_air holders ask a grant holder (`response_request`), as with
rename. It spreads with the statement (highest revision wins). The device API
method is `offset` with `offset_ms`.

**Measurement.** `ba_response_time` (one gen_server per Session scope):

- Each speaker in the engine measures, per received packet, the Response time
  that packet needed: arrival after the capture of its last sample, plus how
  far ahead of the loudspeaker the output reads. Late packets count too: this
  is what the Response time would have had to be. The engine op `response`
  hands over the window (count, mean, p85, p99, max in ms) and starts a new one.
- A Device's value is the largest p99 among its streams: the Response time that
  would have played 99% of its packets in time.
- Devices gossip their values as signed `response` notes: 2 s after a stream
  starts, then at doubling intervals up to once a minute. Every Device keeps
  the values it heard in the last two minutes (the distribution).
- The monitor and Settings show the average as "measured". A slider over the
  distribution (for example the 85th percentile of Devices) is a later step;
  nothing changes the setting automatically.

The earlier "Automatic" mode (lateness reports from the removed Erlang mixer
raising the setting) is gone.

## Not yet verified

The measurement and gossip are implemented and unit-tested, but not yet
observed on real Devices; the iPhone needs a rebuild to carry them.
