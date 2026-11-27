# Stage 4 · Show control

Stage 4 integrates scene timing, the master timeline and independently running
automation cells. Schema 14 saves the new show settings. Earlier ApertureCue
projects migrate with linear scenes, their existing montage edits and no new
schedule, signals or event tracks. New/Open clears all session arming and clocks.

The declared software stage is complete and [alpha 17 is published](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.17).
The tested release source is `73ae54729394530745dcdec92de17e627d506bfd`.

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
| Schedule | Saved scene schedules use an explicit IANA or UTC zone. Import reads an explicitly chosen local ICS file and maps accepted events to a chosen scene. It implements a defined subset of [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545), including daily and weekly repeat rules. [Schedule specification](show-schedule-spec.md) |

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

The integrated optimized app passed five Conductor checks, five schedule checks,
five OSC/MIDI and external clock checks and 29 montage checks. These checks ran with the full regression suite. The original Show Control demo uses
two procedural surfaces and includes a Jump, a Pause, two Conductor banks and
a bound triangle oscillator. It produces no timed network or MIDI output.

Physical MIDI, projectors, device drift, audible audio/video synchronization,
hardware timecode and long-show workloads have separate acceptance gates.

The 171-method standalone assertion run completed with zero failed assertions.
The optimized production executable passed all 16 modes. This includes
91 native editor checks, 5 Conductor, 5 schedule, 5 control/clock, 29 montage,
25 composition, 51 GPU/media, 13 media playback, 9 Sources, 15 offline audio,
5 durability, 3 live-editor, 5 live-presentation and 11 lighting checks.
OSC/MIDI localhost loopback passed separately. [Stored reports](verification/stage-4/production-modes.json)

The Conductor check covers overlapping automation of two rendered procedural
surfaces at 128×80 with one logical output, ordered instant scene recalls in a
late tick, replacement/bank changes, and Save/Open. The calendar check covers
local ICS import, Undo/Redo and duplicate UID rejection, one due GO, live
definition reconciliation, cue deletion and disarming on Open.
[Conductor](verification/stage-4/conductor.json) · [Schedule](verification/stage-4/schedule.json)

An independent local sender exercised clock acquisition, phase, timeout, restart
and manual takeover. Maximum measured same-host error was 0.677 ms across 139
samples. Timed OSC reached a localhost UDP receiver and virtual MIDI loopback
verified bytes and note release. [Control and external clock](verification/stage-4/control.json)

The native montage oracle decoded real original 160×96 H.264 clips at the
forward/reverse crossfade midpoint. Pixel RGBA went from 227/21/21/255 through
124/21/125/255 to 20/20/228/255. The midpoint PTS values were 0.731667 and
2.733333 s. The offline 48 kHz engine matched both stereo voice matrices/gains
without starting a physical device. [Montage](verification/stage-4/montage.json)

The four-source H.264/MOV regression soak ran for 120.016 s at 160×96 and
30 fps. The sources produced 13,920 pulls with 113 missing pulls, including
startup and reverse-generation resets. Peak legacy drift was 119.459 ms and
peak eligible managed PTS age 205.465 ms. The soak acquired source frames
without logical output. [Soak](verification/stage-4/media-soak.json)


## Visible workflow and archive

Opened a separate copy of the procedural show and launched Rise and Fall in
different rows on the diagnostic build. The window reported two active rows.
Stop row kept the other row active. Stop all cleared both with the master
still at 0. The timeline reached the exact 3.500-second Pause. A future-only
test scene schedule was added, armed, disarmed and saved through native
controls. [Diagnostic observations](verification/stage-4/manual-diagnostic.json)

The optimized app from the freshly extracted ZIP reopened that saved fixture
with its calendar row intact and Disarmed. The native OSC/MIDI window showed
Outputs off and explicit external clock arming. [Release app observations](verification/stage-4/manual-release.json)

The 44-entry ZIP passed CRC, unique safe paths, signature, executable mode and
byte equality of app and original demo files. Its extracted app passed seven
focused modes. [Distribution record](verification/stage-4/distribution.json)


## CI and publication

[Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45946371538) passed 171 XCTest on each macOS/Linux
with zero failures, including the macOS SwiftPM release build, native bundle,
archive and artifact. [Run record](verification/stage-4/ci.json)

The published tag points to the checked source. The prerelease ZIP contains
44 entries and is 2,593,398 bytes. SHA-256 `850557aa09d9a5bfde554eb7418575b0ea5069234ee259d9484b6019cd34fabf`.
Both uploaded assets match local size and server-side SHA-256.
[Published metadata](verification/stage-4/release.json)
