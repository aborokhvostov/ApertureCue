# Media playback and durability verification

This journal separates local automatic execution, visible native observations,
archive distribution and physical-device gates. The source contracts and test
counts are in the [stage-3 ledger](../stage-3-completion.md).

## Automatic execution

The baseline production app passed all 13 CLI modes, including 90 editor checks,
13 media checks, 15 offline audio checks, five durability checks and the bounded
four-source soak. Reports are [stored separately](stage-3/production-modes.json).
The original 43-entry archive passed CRC, unique safe paths, executable mode,
strict ad hoc signature and byte equality. Its extracted app passed 12 modes.
The visible workflow then found an oversized Sources window caused by a long
unwrapped help label; that archive is superseded and will not be released.

The corrected production executable passed all 13 modes again, including the
90-check editor and a 120.024-second soak. The final soak made 13,736 pulls,
with 429 missing pulls, 0.120726-second maximum legacy drift and 0.183973-second
maximum managed PTS age. Every source published sustained frames. Its source
revision is `a35963a12589223701fcfec6ef88ffb502d5a5a7`; final distribution and CI
records identify that same release source separately from the baseline.

## Visible native workflow

The workflow uses only a separate temporary copy of the original Media demo.
No existing user project or MadMapper installation is opened or modified.

Initial observations: three surfaces display the generated sequence, ordinary
H.264 and reverse ping-pong movie. Sources exposes the saved controls and session
clock. The help-label sizing problem was found in the actual visible window;
hidden callback checks had not established that its width fit the screen.
A multiline preferred width and horizontal compression priority now constrain
that label. The corrected production window was observed at 670 points wide
(1,340 screenshot pixels), fitting the current desktop; all controls and wrapped
help were visible. This closes the observed width regression in this session.

Final visible observations — 26–27 November 2026, Europe/Moscow:

- The original Media demo opens with three rendered surfaces. The sequence
  initially shows red, the ordinary video red and the reverse-trim source yellow.
- Sequence Play changes the label to Independent and advances elapsed/item time.
  Pause holds it; Seek to 0.750 sets elapsed/item to 0.750. Master remains 00:00
  and the adjacent sources remain on their master positions.
- Saving FPS 4 changes sequence duration from 2.000 to 1.000 seconds. Cmd-Z
  restores FPS 2/duration 2.000; Cmd-Shift-Z restores FPS 4/duration 1.000.
- Ordinary video Seek to 1.250 and Play/Pause advance only its source clock.
  Follow master returns elapsed/item to zero. Save source settings accepts
  Once, rate 0.5 and trim 0.25…3.25; master zero maps to item 0.250.
- The unassigned original stereo tone keeps its transport controls disabled.
  Audio routing saves a 2×2 channel-swap matrix `[0,1,1,0]` with Mute checked,
  using the system-output selection. The source remains unassigned/volume zero;
  this is a UI/persistence observation, not an audible hardware test.
- Save clears the document-dirty marker. Quit exits, relaunch opens the initial
  procedural demo, and explicit Open of the saved temporary Media copy succeeds.
  Sources retains FPS 4, Once/rate 0.5/trim 0.25…3.25 and the swap/mute matrix.
  Runtime transport correctly starts again as Follow master at elapsed zero.
- The final dialog was cancelled and the app quit without additional changes.

No unrelated file-panel content, raw hardware device identities or user files
are included in this journal. Folder discovery/import and recovery decision
branches are covered by the automatic native/core checks; this visible journal
does not claim manual execution of every panel or a forced-termination GUI test.

## Hardware and runtime limits

Automatic camera frames are injected through the production entry interface.
Audio checks render the real engine offline without starting hardware output.
UDP results use localhost. Physical camera capture/unplug, multichannel audio
wiring, actual device reconnect/sample-rate changes, audible AV synchronization,
projectors, optical refresh and long-show stability remain unverified. The video
soak is a two-minute 160×96 source-acquisition workload with no logical output;
it is not a measured projector presentation or a many-hour show run.


## Final CI and distribution

[Exact-source CI](stage-3/ci.json) passed 154 actual XCTest on each macOS/Linux,
plus the macOS release/native bundle/archive/artifact for the corrected source.
[Final distribution](stage-3/distribution.json) records the replacement 43-entry
ZIP, signature/CRC/executable/byte-equality checks and eight focused extracted-app
modes. [Published metadata](stage-3/release.json) verifies the alpha 16 tag and both
uploaded asset sizes/server-side SHA-256 values against the local files. The
release binary is the one used for the corrected visible workflow; the oversized
baseline archive was not released.
