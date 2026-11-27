# Source montage specification

Schema 14 adds source crossfades, reverse video and a separate audio lane to
the assignable montage source. The earlier schema 7 hard-cut workflow remains
available. [Alpha 9 evidence](verification/montage-workflow.md).

## Schema 14 montage

- Picture clips accept image and video files. Audio files use the lower audio
  lane and can play during any picture interval. A forward video clip can
  enable its first audio track with **Play movie audio**. Existing videos keep
  their silent montage behavior.
- **Incoming crossfade s** sets the full overlap with the preceding clip on
  the same lane. For a picture clip ending at 4 s, place the next one at 3 s and
  enter 1 s. Enter 0 for a hard cut. The editor rejects nested overlaps, a third
  simultaneous clip on one lane, and overlaps without a matching fade. Deleting
  the outgoing clip also clears its successor's fade in the same Undo command.
- A fade starts at the incoming clip's Start and ends at the outgoing clip's
  End. A seek directly sets both source times and their weights. Picture
  interpolation uses premultiplied RGBA with a linear weight in the existing
  texture color space. Both samples go through their own orientation transforms
  before common surface geometry, material, color FX and compositing. A missing
  leg contributes transparent or opaque black according to the montage gap
  setting. The mixed source is shared by the editor, outputs and light sampler.
- **Rate** accepts 0.25…4 for forward video/audio, and −4…−0.25 for reverse
  video. Reverse starts just below Out and moves toward In. **Loop trim** wraps
  within those bounds. Reverse clips must keep the movie-audio option off.
  Each active movie leg has its own PTS interval and lease; a crossfade can
  consume two of the eight visual reader slots. Admitted sources use montage
  UUID order and outgoing-before-incoming order within a montage.
- Audio clips use the associated file's saved routing and volume, multiplied
  by the lane's linear gain. The existing PCM adapter supplies pause, seek,
  resampling, varispeed, output device selection and loss diagnostics. A clip
  schedules PCM through the earlier of its source Out and clip End. There are
  eight montage voice slots under the shared eight-PCM-adapter limit, including
  ordinary routed sources. An unassigned montage releases its adapters.
- An audio-only montage can be assigned to a surface. It plays audio while its
  visual contribution follows Black/Skip. Montage audio activates with a current
  surface assignment regardless of visibility, as with ordinary file audio.
  Gain updates arrive at editor tick cadence and the audio engine ramps each
  change. Device startup and decoder warmup can leave a newly active voice
  temporarily silent. No sample-accurate mixed-device or audible AV-sync
  measurement is claimed.
- Schema 7…13 projects keep their original hard cuts and silent video clips. The
  formerly undefined crossfade and audio fields are ignored. Legacy negative
  rates or audio-only montage references reject. Save/New/Open, Undo/Redo and
  Collect use the original source media ownership and keep stable clip IDs.

## Historical alpha 9 specification

The official reference describes assignable montage sources with video/image arrangement, trims, speed/loop, reverse/crossfade and gap policies: [R19 track types](https://docs.madmapper.com/madmapper/6/10.-timelines/track-types-and-inspectors), [R20 clips](https://docs.madmapper.com/madmapper/6/10.-timelines/clips). Exact interval, decoder, conflict and latency policies below are independent design decisions.

## First working boundary

- A montage has a stable source UUID and is assignable to surfaces. Clips reference existing image/video asset UUIDs. No cameras or nested montages in the first subset.
- Clips have stable UUIDs, timeline start/duration and video In/Out, positive rate and loop. Images use start/duration. Start/end uses `[start,end)`; touching clips are legal, overlap within one montage rejects atomically. Reverse and crossfade remain later gates.
- Video position is `In + elapsed * rate`, modulo `Out-In` when looping. A non-loop clip cannot outlast its source span at the chosen rate. Out beyond actual decoded duration reports a runtime diagnostic rather than silently seeking invalid media.
- Gap is explicitly Skip or Black. Missing/warming video must not invoke the surface's procedural fallback or reuse a previous clip's frame. Pause holds the requested position; Seek/Stop evaluates the schedule directly. Boundaries do not generate marker events.
- Cue changes source assignment while the existing master clock/marker rules continue. Montage definitions remain shared project state outside surface snapshots. A persisted montage requires a new schema and explicit older-reader rejection.

## Ownership and timing gates

A montage must not seek/rate/pause the ordinary `MediaPool.Entry[assetUUID]`. One file used by ordinary surfaces and multiple montages needs independent decoder sessions/identities. Images may share immutable textures. Decoder count, loading and caches must have explicit bounds.

Cut, seek, wrap, relink and document replacement invalidate old completion/frame generations. Before an accepted new frame, use the explicit gap/loading behavior. Retain CVPixelBuffer/CVMetalTexture ownership through every GPU submission. Editor/output/light consume the same accepted montage frame. The video-only AVAssetReader actor walks presentation samples sequentially; jumps rebuild the reader and use adaptive predecessor search. Source rate is evaluated by the schedule rather than changing an ordinary AVPlayer. Accepted frames expose actual CMSampleBuffer presentation timestamp and coverage end; measured reports are required before any synchronization claim.

The first montage video path should be silent. Existing ordinary `MediaPool.play()` starts all entries: muting only new montage decoders would leave the original asset's unrelated audio running. Define source activation/audio ownership and test it; never change a shared asset's volume to hide the problem. Assigned ordinary sources must retain their independent transport/audio behavior.

## Acceptance before publication

Use generated media with distinguishable temporal frames. Test exact starts/ends, trims/rate/loop/gaps, paused and rapid seeks, stale completions, source relink, one file simultaneously ordinary plus two montage positions, source clock/seek-generation isolation, markers/Cue/scalar priority, real output/light frames, Save/Open/Collect/Undo and malformed UUID/range/overlap/budget rejection. Record actual frame PTS/tolerances, delayed-frame behavior and unmeasured metrics. Native GUI and fresh archive/CI remain separate gates; no external-device compatibility follows from these tests.

## Alpha 9 implementation policy

Schema 7 requires typed montage definitions; v0...v6 discard this formerly undefined extension and upgrade on save. Source/clip IDs are unique across their namespaces. Limits are 64 montage definitions, 1024 clips per montage and 4096 clips total; video rate is 0.25...4. Overlaps, cameras and nested montage sources reject before document mutation. Definitions stay outside surface Cue snapshots, while a Cue can recall a montage UUID through its source field. Deleting a montage clears current and stored Cue references in one history command.

Eight persistent decoder slots admit active montage-video sources in sorted UUID order, share one accepted frame across editor/output/light, and coalesce work to one pending request per slot. Extra active videos show the chosen gap policy with a diagnostic. Each decoded image is limited to 16 megapixels, at most 8192 on either dimension and 64 MiB of pixel storage. This bounds individual decoder images and slot count; it is not a measured total-process memory ceiling. Readers decode BGRA in presentation order. Metadata loading is actor coordinated with generation checks after suspension. Blocking sample reads, reader construction and cancellation share one serial Dispatch queue per slot; they never block Swift cooperative executor threads. Eight reads on that executor reproduced a loading stall; the same eight-source probe succeeds with this queue ownership. Source Out is bounded by the video track extent rather than an audio-only tail. PTS 0 is valid. Initial/internal uncovered intervals stay gaps; low-FPS predecessor search expands toward track start. Preferred video transform maps upright source coordinates into encoded pixel coordinates without changing surface crop/mask.

A paused frame must cover the exact requested source time. During uninterrupted playback, an adjacent frame may remain visible for at most 120 ms of show time while a new one decodes. Cut/trim/wrap/seek/relink/document changes invalidate it first. Decoder failure/loading uses explicit Black or Skip, never procedural checker fallback. Black is an opaque black source subject to normal surface opacity/color/blend; Skip removes that surface from composition. No dropped-frame, latency, drift, performance or long-show guarantee follows from this policy.

Ordinary audio is active only for assets assigned directly to current surfaces, independent of surface visibility/opacity/routing. An inactive library asset is muted and paused. Keeping the same assigned source set does not seek or change an ordinary asset's volume. Montage video decoders have no audio output. Audio montage, reverse, overlap/crossfade, waveform editing and clip recording remain open.
