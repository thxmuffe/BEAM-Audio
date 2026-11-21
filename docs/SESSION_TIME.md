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

**Setting.** The signed membership statement carries the effective delay
(`response_ms`, 0–3000 ms) and whether adjustment is automatic
(`response_auto`). New Sessions start in Automatic at 150 ms. Saved statements
without a mode start in Automatic at their saved value. OpenSound offers
Automatic, 250 ms and 2 s. Selecting a fixed value pins the shared delay.
Returning to Automatic starts at the current value and resumes adjustment.
Grant holders sign selections directly and on_air holders can request them.
Any member can submit a measured adjustment because microphone publication
needs no on_air privilege. The Device API accepts a whole number of
milliseconds or the string `"automatic"` in the `offset` command's
`offset_ms` field.

**Measurement.** `ba_response_time` (one gen_server per Session scope):

- The audio engine collects timing samples locally for speakers that are
  enabled for playback. Its `response` command drains each speaker's sample
  count and exact sum in nanoseconds, alongside its diagnostic percentiles.
- Signed `response` notes carry a batch count and sum. The Session estimate
  adds batches from the last two minutes, counting each signed note ID once
  even if it arrived through several neighbours. The measured value is the
  total sum divided by the total sample count.
- Signed `playback` notes report playback starts, stops and changes in playback
  failure state. A new playback start resets the reporting cadence throughout
  the Session. With fresh samples available, the interval starts at 250 ms
  and grows with the sample count to at most 2 seconds. The timing statistics
  remain available across cadence resets. Packet-level diagnostics stay local.
- The Device snapshot exposes the last known playback state for its listed
  Devices.

**Automatic adjustment.** In Automatic, a Device with at least one unpaused published input
(system capture, microphone or any other source) checks whether the setting
should rise or fall to **2.5 times the measured Session mean**. It uses the exact
sample count and sum, rounds once to integer milliseconds and caps the result
at 3000 ms. For example, 45 ms gives 113 ms. Without fresh samples or a ready
signed setting, it leaves the value unchanged.

Checks start after 500 ms, then use intervals of 1, 2, 4 and at most 5 seconds.
Starting/resuming an input or starting new playback resets the cadence.
Stopping/pausing every input or losing the local audio controller stops changes.
The existing authenticated request/approval path applies: a grant holder signs
the setting, while another Device requests that change from a grant holder.
Without a reachable grant holder, requests cannot change the shared setting.
Identical settings do not create new signed revisions. Grant holders check
the signed mode when processing a measurement, so an adjustment already in
flight cannot change a fixed delay.

`ba_cadence` is a shared helper for starting with frequent observations and
spacing them out as they accumulate. Each reporting process owns its cadence
state and timer. Delay gossip advances using packet sample counts. Automatic
adjustment advances using completed checks with measurements. Both use the
same scheduling logic and choose their own intervals and reset events.

## Not yet verified

Playback reporting and automatic adjustment have yet to be observed on real
Devices.
