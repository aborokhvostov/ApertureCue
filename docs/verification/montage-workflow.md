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

## Native workflow in progress

An isolated ad hoc signed test copy loaded the original `Montage.aperturecue.json`. The native source library showed ordinary assets plus two montage sources; the Montage window displayed the correct six clips, trims/rates, gap settings and selection strip. Layout was visually inspected at its default size.

Create/edit/assign/history/save/relaunch/reopen through the visible GUI are still pending final verification. An early draft attempt lost accessibility access during text/layout updates; the app was sampled and the disposable copy closed. The playhead now avoids assigning an unchanged label during pause. A later whole-editor run under severe local memory pressure failed the pre-existing selective-movie readiness deadline before reaching montage controls. Neither failure is counted as a passing GUI/full-editor gate. Recheck these with the final optimized bundle before publication.

## Boundaries

Source videos are silent in montages. Ordinary audio activation follows direct assignment to current surfaces, including hidden/zero-opacity layers. Decoder admission follows assigned montage IDs in deterministic UUID order, including hidden surfaces; it is a montage-reader limit, not a bound on all ordinary AVPlayers or total process memory. There is no reverse, crossfade/overlap, audio montage, nested source, clip recording, external display/projector or physical lighting claim. No new throughput, long-show, optical FPS or multi-source frame-lock claim is made.
