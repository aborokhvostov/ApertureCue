# Source montage verification

28 October 2026 (Europe/Moscow), macOS 26.6.2 / Apple M2 / arm64 / 8 GiB. This stage is independently authored and does not establish reference parity or hardware compatibility.

## Automatic evidence

- Portable core: 91 standalone test methods, zero failed assertions. Local CLT lacks XCTest; actual remote XCTest is a separate release gate.
- Production reader/Metal suite: 27 checks through generated H.264 media, including 30 fps, 1 fps, variable sample intervals and 90-degree presentation metadata. Readback uses 128×96 pixels. Temporal palette comparisons allow 32/255 for lossy RGB/YUV conversion; exact gap and shared-consumer comparisons use their tighter explicit tolerances. This is not a color-management accuracy claim.
- Recorded samples expose actual accepted AVAssetReader CMSampleBuffer PTS and coverage end. A reader time range can trim the first covering sample's PTS; it is not necessarily the original file sample timestamp. No nominal-FPS assumption is used for coverage. The generated initial empty edit produces a valid black sample at PTS 0, followed by the original later timestamps.
- One ordinary playing file and two independently positioned montages retain different decoded temporal colors. Actual ordinary player volume, mute, seek generation and playback continuity are checked. An unassigned same-file ordinary player stays muted and paused after asynchronous readiness/seek.
- Black/Skip, missing media, cuts, trim/rate/loop, PTS 0, backwards/repeated/60 rapid seeks, stale document work, same-path replacement, orientation, variable-frame coverage and Out beyond video extent are exercised. Editor/output and asynchronous lighting readback share the accepted frame; CVPixelBuffer and CVMetalTexture references are retained.
- Playing-mode tests step explicit schedule times and check stable generations, loop invalidation and late-frame policy: 110 ms of show time is accepted at rate 2, 130 ms is rejected, and paused targets require exact coverage. These are deterministic time-stepped checks, not a real-time soak, drift or latency measurement.
- Eight simultaneous decoder owners are tested, with a diagnostic and gap for the ninth, followed by owner release. The earlier cooperative-executor implementation stalled all eight reads. A sampled owned process showed all cooperative workers blocked in `copyNextSampleBuffer`; four reads completed. Moving blocking reader construction/read/cancel to per-slot serial Dispatch queues made the same eight-source probe complete. Async metadata remains actor coordinated; leases reject stale completions.

## Native workflow

An isolated optimized ad hoc signed copy loaded the original montage demo from a fresh user-temporary folder. The native source library showed ordinary assets plus montage sources; the Montage window displayed the correct six example clips, trims/rates, gap settings and selection strip. Default-size layout was visually inspected.

The visible workflow passed: select the saved video clip, Seek clip start to 3 s, Play, Pause at 6.353 s, observe the left Black gap while the right video continues; create a new 10 s montage; add a 1 s H.264 clip with In 0.5 / Out 2.5 / rate 2; add the original image at 2 s for 1 s; assign it to the selected surface; Undo restores the old source and Redo restores the new montage; Save clears dirty state. Seeking the image clip to 2 s displays the original calibration image in the perspective cage. A real Quit/relaunch/Open restores all three montage sources, the new assignment and both clips, including the saved video trim/rate. Saved schema 7 JSON independently retained montage/clip UUIDs. Only generated test projects were changed; test copies were quit afterward.

Early attempts under severe local memory pressure lost accessibility access during text/layout updates, and one unoptimized whole-editor run failed the pre-existing selective-movie readiness deadline. The optimized final bundle passed all 51 editor checks sequentially, including paused draft layout after timer updates and actual movie checks. The playhead avoids assigning an unchanged label during pause. An older test copy's Open dialog left a JSON in `/tmp` disabled; a fresh signed identity with a fresh user-temporary project opened and reopened successfully. These changed conditions do not establish a single root cause for that earlier dialog state.

One UI-service launch call blocked about 55 min despite timeout 30 s; subsequent same-copy relaunch took seconds. The blocked tool call is not application soak, decode latency or performance evidence. No new performance claim is derived from status-bar FPS or screenshots.

## Final build and archive

Production source is `63a8847315605f3456a2b55693f5bfb52889395e`. The final optimized signed arm64 app passed 46 GPU/media, 27 montage, 51 editor and 11 lighting/UDP checks. The fresh ZIP passed CRC/path/AppleDouble/executable-mode validation and strict deep signature verification; its extracted executable passed all 51 editor and 27 montage checks. Packaging retried with approved execution permission after sandbox copy operations were denied. File Provider metadata attached to the workspace copy was cleared before signature re-verification; packaging staged without resource forks/extended attributes in the user temporary directory.

[Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40731651961) passed 91 actual XCTest on Linux (4.985 s) and 91 on macOS (6.171 s reported suite duration), zero failures, plus macOS SwiftPM release/native bundle/signature/archive/artifact. CI runtime evidence is separate from logged-in local GPU/UI checks. See [distribution](distribution.md) for the final archive digest and publication status.

## Boundaries

Source videos are silent in montages. Ordinary audio activation follows direct assignment to current surfaces, including hidden/zero-opacity layers. Decoder admission follows assigned montage IDs in deterministic UUID order, including hidden surfaces; it is a montage-reader limit, not a bound on all ordinary AVPlayers or total process memory. There is no reverse, crossfade/overlap, audio montage, nested source, clip recording, external display/projector or physical lighting claim. No new throughput, long-show, optical FPS or multi-source frame-lock claim is made.
