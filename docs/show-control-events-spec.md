# Timed show events and external clock

Show Control in ApertureCue stores timed output tracks in the project. An enabled
track owns independent OSC and MIDI events. Show time and output arming belong to
the current session. Opening or creating a document clears arming and shuts down
the virtual MIDI source and clock listener.

## Timed OSC and MIDI

Open **Show control…**, add a track, enter an event time within the show duration,
and use **Save event**. Saving a track applies its name and enabled state. The
selected event can be edited or deleted. These are project edits with Undo/Redo.

An OSC event has a localhost IPv4 UDP port, concrete OSC address and optional
integer, float, text or Boolean argument. The sender uses the existing OSC 1.0
codec. A MIDI event emits Note On, Note Off or Control Change on channel 1…16 with
seven-bit data. A MIDI application can connect to the virtual **ApertureCue Show
Output** source. The ordinary ApertureCue MIDI input ignores this named source to
avoid a local feedback loop. Physical MIDI devices require a separate adapter or
routing outside ApertureCue. OSC outbound delivery uses UDP, so a missing receiver
can lose events. The application reports local send failures and drops failed
events instead of replaying them later.

Arm outputs from a paused show, then play or resume. Events occur on natural
forward crossings of `(oldTime, newTime]`, including eligible loop traversals.
Events at the same time use saved track and event order. The editor applies
scene crossings before it emits the tick's output batch. The timeline shares its
256-event tick budget with markers and reports when it skips excess events.
A seek or clock alignment updates the playhead silently. No event crosses exactly
at a seek target when playback resumes from there. Pause, stop, discontinuity and
disarm release active MIDI notes through the same virtual endpoint. Pair Note On
and Note Off explicitly for a note with duration. The project limit is 64 tracks
and 4,096 total events.

## External OSC clock

Choose a source token and UDP port in Show Control, then click **Arm external
clock**. Port 9001 is the initial field value. The listener binds only to
`127.0.0.1` and accepts the clock address. It is independent of the ordinary
remote control listener. Status reports waiting, locked, held or lost. Main
Play, Pause, Stop and Seek take control back from the external clock.

The sender sends OSC messages directly to that localhost endpoint. Use the
argument order shown in the table.

| Field | OSC type | Value |
|---|---|---|
| Address | — | `/aperturecue/clock` |
| Source | `s` | 1…64 ASCII letters, digits, dot, underscore or hyphen |
| Session | `s` | UUID, new on sender restart |
| Sequence | `i` | Nonnegative 32-bit integer, strictly increasing within the session |
| Position | `f` | Finite seconds in 0…31,536,000 |
| Playing | `T` or `F` | True for a clock advancing at 1× between arrivals |

Use periodic packets. The receiver interpolates from each monotonic receive
timestamp while playing. Errors within 80 ms keep the ordinary monotonic
transport running and preserve normal crossings. Larger errors, first lock,
reacquisition and sender playing-state changes align by a silent seek.
A paused clock holds its sent position with a 1 ms correction tolerance.
The local timeline loop maps positions at or beyond loop end into the configured
loop interval. Running clock correction measures phase across the wrap, so small
packet variation at the boundary preserves natural marker crossings.
A local pause marker or non-loop show boundary holds the playhead
while the sender continues its unchanged playing state. An explicit sender
pause/resume or reacquisition releases that hold.

After 750 ms with no valid fresh packet, the receiver freezes at the last
holdover boundary and clears queued output side effects. It rejects mismatched
source names, replays and older timestamps. A new UUID can replace the current
one after loss. Retired UUIDs remain rejected, with a 64-session bound per
arming. The source token distinguishes locally configured streams. Local
processes can supply that token. UDP clock bundles use immediate timetags.
The mode follows elapsed show seconds at 1× using localhost OSC packets.

The standalone core tests inject clock time to verify packet shape, ordering,
deadband, holds, loss and restart. The native test uses actual localhost UDP,
a virtual CoreMIDI receiver, and a bounded second process that sends timestamped
clock fixtures. Its report includes measured interprocess phase error on one
computer. Physical MIDI interfaces, Link/LTC/MTC, separate machine phase and
long-show drift require separate verification.
