# Stage 4 · Show control

Stage 4 integrates scene timing, the master timeline and independently running
automation cells. Schema 14 saves the new show settings. Earlier ApertureCue
projects migrate with linear scenes, their existing montage edits and no new
schedule, signals or event tracks. New/Open clears all session arming and clocks.

## Implemented behavior

| Area | Scope |
|---|---|
| Scenes | Full and selective surface scenes carry a curve. Linear, ease-in, ease-out and ease-in-out share the same transition duration and follow timing. Follow still advances in scene order. |
| Timeline and recording | The existing touch recording and graphical curve editor support one-step retiming of a key range. A retime validates the complete track before accepting the history entry. |
| Markers | Pause, Recall and Jump are based on forward crossings. Each Jump has a saved destination and limit of 1–64 crossings. A jump positions the playhead at the destination and discards the rest of that tick. Explicit Seek and Stop reset the jump counts. An armed external clock owns position, so it suppresses local Jump markers during that session. |
| Conductor | Each bank can hold rows of captured automation timelines. One cell per row runs from its own host anchor. Another cell replaces that row. Launching a cell from a different bank stops the previous bank. Relaunching the same cell preserves its clock. |
| Signals | Sine, triangle and square waveforms sample the master time. Add and multiply combine named outputs. Bounded graph validation rejects cycles and invalid parameter bindings. |
| Montage | Signed video rates, explicit adjacent crossfades and an opt-in PCM audio lane extend the saved hard-cut definitions. [Montage specification](montage-spec.md) |
| Timed control and external clock | OSC dispatch targets loopback addresses. MIDI dispatch uses an explicitly armed virtual source. The dedicated opt-in localhost clock detects loss and reacquisition. [Protocol and workflow](show-control-events-spec.md) |
| Schedule | Saved scene schedules use an explicit IANA or UTC zone. Import reads an explicitly chosen local ICS file and maps accepted events to a chosen scene. It implements a defined subset of [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545), including daily and weekly repeat rules. |

Each frame starts with the current scene, applies master automation, then
signals, then active rows in bank order. Where multiple rows drive the same
parameter, the lower row wins. The active inspector recording sample takes
priority while it is being recorded. A non-looping cell holds its final value
until Stop, replacement or bank change. Master Pause holds master automation
and signals. Conductor cells keep their own clocks until stopped.

Markers and external events use a common 256-event catch-up budget, with
markers prioritized at equal timestamps and event tracks ordered by their saved
list order. Pause applies at its exact crossing even when the event queue is
full. Additional crossings can be skipped when the budget is exhausted. The
native runtime still uses the rendered current scene as the source when GO
interrupts a transition.

## Acceptance evidence

Production editor, frame/media, elapsed-time, archive and exact-source CI
results are recorded here as they finish. The original Show Control demo uses
two procedural surfaces and includes a Jump, a Pause, two Conductor banks and
a bound triangle oscillator. It produces no timed network or MIDI output.

Physical MIDI, projectors, device drift, audible audio/video synchronization,
hardware timecode and long-show workloads have separate acceptance gates.
