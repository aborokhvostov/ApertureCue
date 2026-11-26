# Stage 3 — media playback and durability

Declared Stage 3 software acceptance passes for schema 13 and source
`a35963a12589223701fcfec6ef88ffb502d5a5a7`: production automatic checks, scoped
visible workflow, fresh archive/extracted execution and exact-source CI. Scope
remains roadmap V02–V06, V12, A01/A02 and P01–P03. Hardware/runtime gates below
remain open. [Alpha 16](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.16) is published; its tag and asset digests match the checked source/archive.

Acceptance workstreams:

- Independent ordinary-source play/pause/seek/follow-master; saved trim, signed
  speed, loop/once/hold/ping-pong/deterministic random semantics and bounded PTS
  acquisition. Frame generation invalidation must survive rapid seeks,
  relink/delete, document changes and late decoder callbacks.
- Frozen naturally sorted folder image sequences, explicit FPS and missing-frame
  policy, bounded cache/decoder queues and portable collection of every declared
  frame. Newly added files join only through an explicit refreshed import.
- PCM audio matrix, mute/gain, explicit output identity and unavailable/disconnect
  handling; real engine offline numerical/timing oracle using original tones.
  Physical output channels, audible synchronization and audio hardware remain H.
- Latest-frame camera simulator plus production disconnect/error cleanup; no
  stale image from a lost source. Real capture devices remain a separate H gate.
- Saved-source-bound recovery freshness, invalid/stale/corrupt preservation,
  atomic saves and collection, legacy migrations and a separate process
  termination/restart test on original temporary documents.
- Actual production editor/frame/media regressions, a bounded multi-source soak
  with measured PTS/drop/drift statistics, manual editor workflow, fresh archive,
  exact-source macOS/Linux XCTest and checked prerelease distribution.

Implementation, automatic checks, manual observations and hardware checks are
recorded independently. No simulator, offline audio render or localhost result
is a hardware compatibility claim. Reference equivalence remains open.

## Implemented contracts

- [Ordinary-source transport and image sequences](media-playback-spec.md): schema
  13, independent session clocks, saved signed-rate modes, actual PTS intervals,
  generation invalidation, frozen manifests and bounded image/reader ownership.
- [Audio](audio-playback-spec.md): first-track PCM, channel matrix and explicit
  output identity, bounded preparation/decoding, serialized reader cancellation,
  trim/EOF and a declared silent policy for unsupported directions/modes.
- [Durability](durability-spec.md): same-byte saved revision tokens, recovery
  freshness/ownership, separate-process termination and staged portable collection.
- Sources controls are functional native callbacks with Undo/Redo for saved
  settings. Runtime Play/Pause/Seek/Follow does not modify a saved document.
  Quit retires independent sources as well as master followers.
- `examples/Media` contains original generated PNG frames, a silent H.264 MOV
  and a stereo WAV. The audio asset is unassigned with volume zero in the demo.

## Acceptance boundaries

The local automatic workload uses original H.264 MOV at 160×96 / 30 fps, PNG
sequences and offline PCM fixtures, alongside the existing compositor/editor
regressions. The bounded video soak lasts 120 seconds with four sources: two
legacy AVPlayer loops and two managed readers (forward 1.5× loop and reverse
ping-pong). It records accepted pulls for each source, missing pulls, actual PTS
age, decoded frames, clock corrections and legacy drift. Every source must
publish sustained frames; a run with no managed frames cannot pass. This is a
local source acquisition workload with no optical output or audible audio.

Recovery integration kills a separate writer only after its atomic checkpoint
has completed and verifies the saved revision and checkpoint in a restarted
process. This does not simulate power loss or filesystem corruption.

Camera disconnect/replacement checks inject original buffers through the same
entry interface. Offline audio renders the production engine graph without
starting hardware output. Physical camera capture, channel wiring, audible AV
synchronization, actual device loss/reconnect, external projectors and show-length
stability remain open H/runtime gates. No 4K/60, optical frame lock, universal
codec support or full reference equivalence is claimed.


## Local automatic evidence — 26–27 November 2026 (Europe/Moscow)

Apple M2 / arm64, 8 GiB RAM, macOS 26.6.2 build 25G83; Apple Swift 6.4.2,
macOS 13 deployment target. The final app uses the optimized `scripts/build.sh`
path, with ad hoc signature. No external packages or proprietary SDKs are added.
[Production mode results](verification/stage-3/production-modes.json) preserve
exit codes/durations; the individual reports retain fixture scopes and limits.

| Gate | Result | Evidence |
|---|---|---|
| Foundation-only core | 154 standalone methods, zero failed assertions; not XCTest | [Core](verification/stage-3/core-summary.json) |
| Source editor | 9 focused hidden-native checks; also included in full editor | [Sources](verification/stage-3/source-editor-test.json) |
| Source PTS/cache/camera simulator | 13 checks | [Media](verification/stage-3/media-playback-test.json) |
| Audio | 15 actual-engine offline checks, no hardware output | [Audio](verification/stage-3/audio-test.json) |
| Separate-process durability | 5 checks, writer signal 9; saved bytes unchanged | [Durability](verification/stage-3/durability-test.json) |
| Full production editor | 90 checks | [Editor](verification/stage-3/editor-test.json) |
| Metal/media regressions | 51 checks | [GPU/media](verification/stage-3/self-test.json) |
| Montage | 27 checks, including rotation/VFR/gaps/eight-reader bound | [Montage](verification/stage-3/montage-test.json) |
| Composition/cache/feedback | 25 checks | [Composition](verification/stage-3/composition-test.json) |
| Live editor/presentation | 3 full-editor and 5 presentation checks | [Editor live](verification/stage-3/live-editor-test.json), [presentation](verification/stage-3/live-composition-test.json) |
| Protocol/light | OSC/MIDI localhost PASS, 11 GPU-to-UDP lighting checks | [Loopback](verification/stage-3/protocol-loopback.txt), [lighting](verification/stage-3/lighting-test.json) |
| Video soak | 14 checks including 120.024 seconds / four sources | [Soak](verification/stage-3/media-soak-test.json) |

The final soak made 3,434 polls / 13,736 source pulls. Accepted pulls by source
were 3,429 / 3,429 / 3,366 / 3,083; 429 pulls had no eligible frame. Two managed
readers were active, with 12,963 total decoded frames and eight legacy clock
corrections. Maximum legacy clock drift was 0.120726 seconds. Maximum managed
target-to-PTS age was 0.183973 seconds, below the declared scaled-rate late-frame
plus sample interval bound. Missing pulls are reported rather than described as
uninterrupted playback; startup and discontinuity resets are included. No logical
output was presented in this acquisition workload. The separate live checks cover
native presentation, without an optical refresh or throughput claim.

The audio oracle rendered 65,536 frames at 48 kHz (1.365333333 seconds) with zero
source sample-clock error. Trim 0.25…0.30 admitted 2,400 frames; fractional Out
admitted 4,801 frames according to the documented sample-interval policy. Reader
cancellation remained on its worker, and no packet copied after invalidation.

Development checks exposed and fixed stale demand state after reset, repeated
reverse-generation invalidation, a reverse leading-gap admission case, temporary
image-budget failure poisoning, inactive movie preview regression, same-route
audio retry, reader cancel/copy ownership and a nested test-fixture directory.
Earlier development runs, including a soak with no managed frames, are excluded
from this acceptance. The strengthened final soak explicitly requires sustained
frames from every source. Original demo generation was retried in isolation after
an overloaded parallel encoder run; this is not a startup-latency claim.


## Visible workflow and final revision

The first visible Sources window exposed a long unwrapped help label that
expanded its minimum width beyond the display. Hidden callback checks had not
established screen-fit behavior. Its multiline preferred width and horizontal
compression priority are corrected; the final visible workflow and replacement
archive are recorded in the [native journal](verification/media-workflow.md).
The [baseline exact-source CI](verification/stage-3/baseline-ci.json) passed
154 actual XCTest on each macOS/Linux plus macOS release/native packaging.
That baseline is retained separately from the final layout revision and release.


The corrected production app from `a35963a12589223701fcfec6ef88ffb502d5a5a7`
passed all 13 modes again after the visible layout fix. Its binary matches the
manual workflow binary. The full optimized editor result is 90 checks; the final
soak values above refer to this corrected executable. The baseline archive is
superseded, and the replacement archive has its own distribution record.


Final archive verification passes: 43 entries, CRC, safe unique names, executable
mode, strict ad hoc signature and byte equality for app and original examples.
The final extracted app passes eight focused source/media/audio/durability,
GPU/montage/composition and live-editor modes. [Distribution details](verification/stage-3/distribution.json)
and [build identity](verification/stage-3/build.json) bind these results to the
same binary used for the visible workflow. The build remains unnotarized.


[Final exact-source CI](verification/stage-3/ci.json) passed for
`a35963a12589223701fcfec6ef88ffb502d5a5a7`: 154 actual XCTest on macOS Swift 6.1.2
and 154 on Linux Swift 6.0.3, zero failures. macOS SwiftPM release build, native
bundle, archive and uploaded artifact also passed. This is separate from the
local 154-method standalone assertion run and from logged-in graphics checks.


## Published stage and next work

[Release metadata](verification/stage-3/release.json) confirms prerelease alpha 16
from the checked source above, published 27 November 2026 Europe/Moscow
(26 November 21:10:27 UTC). Both uploaded assets match their local byte sizes and
SHA-256 values; the ZIP is 2,256,895 bytes / 43 entries, SHA-256
`a17291c23df787fca255c8314c9a4042c097cbbd3656e4c2f96c5bf702d893a0`.

The declared Stage 3 software acceptance is complete. Next software work belongs
to Stage 4 Show control: wider recording/montage tools, external clocks and
Conductor scheduling, with their own behavior gates. Physical devices and
show-length stability stay open separately; this stage does not establish full
reference equivalence.
