# Stage 3 — media playback and durability

Schema 13 production candidate after alpha 15. Scope remains roadmap V02–V06,
V12, A01/A02 and P01–P03. Local production automatic checks pass; final visible
workflow, extracted execution and exact-source CI are separate acceptance gates.

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


## Local automatic evidence — 26 November 2026

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
| Video soak | 14 checks including 120.003 seconds / four sources | [Soak](verification/stage-3/media-soak-test.json) |

The soak made 3,409 polls / 13,636 source pulls. Accepted pulls by source were
3,401 / 3,402 / 3,339 / 3,116; 378 pulls had no eligible frame. Two managed readers
were active, with 12,936 total decoded frames and eight legacy clock corrections.
Maximum legacy clock drift was 0.125360 seconds. Maximum managed target-to-PTS
age was 0.205190 seconds, below the declared scaled-rate late-frame plus sample
interval bound. Missing pulls are reported rather than described as uninterrupted
playback; startup and discontinuity resets are included. No logical output was
presented in this acquisition workload. The separate live checks cover native
presentation, without an optical refresh or throughput claim.

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
