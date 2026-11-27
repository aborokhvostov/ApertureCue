# MIDI Time Code

Open **Show → MIDI Time Code…**, select a CoreMIDI input, set **Show time zero (source seconds)**, and click **Arm time code**. For 25 fps source time `01:00:00:00`, enter `3600` so the show begins at zero. Leave the value at zero for sources whose clock starts at midnight. Positions preceding show zero stay paused at zero. Time code wraps at its own 24-hour boundary. For drop-frame sources, enter an elapsed-second origin derived from the source frame count.

MTC and the localhost OSC clock share one external clock owner. The MIDI selection follows the explicitly selected CoreMIDI unique ID. When the source disappears or times out, the show and media pause after the existing 0.75-second holdover. Fresh data from the same selected UID can reacquire the transport. **Disarm time code** or a local show seek returns control to the operator. Arming applies to the current project session and ends on project replacement or app exit.

The assembler accepts MIDI 1.0 quarter-frame messages at 24, 25, 29.97 drop-frame, and 30 fps. Forward quarter frames drive forward playback. Reverse quarter frames update the paused playhead. Universal full-frame messages locate and pause. The decoder validates frame labels and compensates for the two-frame running assembly delay. A partial cycle or an invalid label produces no position. SMPTE user bits, MIDI beat clock, and LTC audio input are separate protocol paths. [MIDI Association time-code specification](https://midi.org/midi-time-code)

## Evidence and limits

The portable suite checks fragmented messages, both directions, real-time byte interleaving, all four rate codes, drop-frame transitions, midnight wrap, oversized data, and malformed labels. The native `--midi-time-code-test` mode starts an independent process with an original virtual CoreMIDI source, measures phase, and checks source isolation, locate, real source teardown, same-UID reconnect, reverse scrub, and takeover. It writes `artifacts/local/midi-time-code/report.json`. Physical MIDI timing, audio LTC, MIDI hardware profiles, and lighting-console compatibility require independent hardware checks.

## Optional Ableton Link

Ableton publishes the desktop Link source under GPL-2.0-or-later and offers a separate proprietary license. The published LinkKit SDK terms are separate from the desktop source license. ApertureCue's base app has no Link dependency. A future Link integration needs an exact pinned upstream revision and dependency/license inventory, a separate build and deployment check, and an independent Link phase and loss test. [Desktop Link license](https://github.com/Ableton/link/blob/master/LICENSE.md) · [LinkKit SDK license](https://github.com/Ableton/LinkKit/blob/master/LICENSE.md)
