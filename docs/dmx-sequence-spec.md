# DMX sequence recording and replay

Open **DMX Sequence…** from the lighting controls. **Record live** captures
accepted universe snapshots from the live composition sampler. **Finish recording**
opens the result in the sequence preview, where you can play, seek and inspect
every raw slot in a selected universe. **Save as…** writes an independent
`.acdmx` file. **Open…** loads that file into the panel; it does not require
the source project or its fixture definitions.

The panel defaults to **Play preview**. The preview clock leaves live lighting
and the armed network route undisturbed. To send an opened or recorded
sequence, explicitly arm the selected lighting route and use **Play to armed
output**. The lighting controller validates the sequence universe numbers
against its active protocol, replaces the live sampler as packet source during
replay and retires the replay stream on Stop, end of sequence or output loss.
The receiver uses the controller's existing rate, coalescing and protocol
termination rules.

## Binary format version 1

Each field is unsigned big-endian. The slot data uses the original byte order.
The file contains timestamps and raw slots. Fixture definitions, target hosts,
hardware identifiers and project paths are outside the format.

| Location | Width | Meaning |
|---|---:|---|
| File header | 8 bytes | ASCII magic `ACDMXSEQ` |
| File header | 2 bytes | Version 1 |
| File header | 2 bytes | Reserved, zero |
| File header | 4 bytes | Number of snapshots |
| File header | 8 bytes | Total duration in microseconds |
| Each snapshot | 8 bytes | Microseconds from capture start |
| Each snapshot | 2 bytes | Number of active universes |
| Each universe entry | 2 bytes | Universe number 0…63,999 |
| Each universe entry | 2 bytes | Slot count 1…512 |
| Each universe entry | Slot count bytes | Raw values in slot order |

Universe entries within a single snapshot use ascending unique number order.
Each snapshot is a full set. A universe absent from the snapshot is retired.
A snapshot with zero universes clears the active set. Frame times strictly
increase and stay at or below the recorded duration.

The file admits 64 unique universe numbers, 216,000 snapshots, a four-hour
duration and 64 MiB of encoded data. Capture keeps the accepted prefix when it
reaches a limit. The reader rejects unsupported or malformed headers,
duplicates, truncation, trailing data and files over the limits. The main
thread admits one file read or atomic save at a time. A failed load preserves
the currently accepted sequence. Document reset retires any pending load
result.

## Timing and values

Capture uses a monotonic host clock and stores elapsed integer microseconds.
Consecutive identical snapshots coalesce and retain their hold interval.
Before the first snapshot the preview is empty. Between snapshots the previous
one holds up to the exact next timestamp. Seeking previews the covering
snapshot directly. While the network stream is active, a seek replaces the
pending frame and increments the replay generation. Old scheduled replay
callbacks cannot publish after a seek, Stop, document change or output loss.

The native replay clock evaluates at up to 30 Hz. Catch-up chooses the current
snapshot after a delayed tick. It does not burst through missed snapshots.
Network output is limited by the armed route's rate and asynchronous worker.
The file holds exact slot values and recorded microsecond timestamps. Native
scheduling, transmission and a physical receiver's refresh have separate timing
limits.

The automatic native session check captures original raw values, seeks through
gaps and verifies exact replacement bytes and isolated output handoff. Its
callback adapter is an in-process fixture. Native lighting loopbacks exercise
the separate wire protocols. Physical nodes, cable timing, attached fixtures
and long-run output remain distinct verification work.
