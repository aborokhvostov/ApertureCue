# Source montage specification

**Implemented alpha 9 subset, schema 7.** Independently authored assignable image/video montages have passed local core/reader/Metal/editor checks, native GUI, fresh archive execution and actual macOS/Linux XCTest CI. [Evidence](verification/montage-workflow.md). This is the hard-cut subset below; reverse/crossfade/audio and full reference parity remain open.

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

## Current implementation policy

Schema 7 requires typed montage definitions; v0...v6 discard this formerly undefined extension and upgrade on save. Source/clip IDs are unique across their namespaces. Limits are 64 montage definitions, 1024 clips per montage and 4096 clips total; video rate is 0.25...4. Overlaps, cameras and nested montage sources reject before document mutation. Definitions stay outside surface Cue snapshots, while a Cue can recall a montage UUID through its source field. Deleting a montage clears current and stored Cue references in one history command.

Eight persistent decoder slots admit active montage-video sources in sorted UUID order, share one accepted frame across editor/output/light, and coalesce work to one pending request per slot. Extra active videos show the chosen gap policy with a diagnostic. Each decoded image is limited to 16 megapixels, at most 8192 on either dimension and 64 MiB of pixel storage. This bounds individual decoder images and slot count; it is not a measured total-process memory ceiling. Readers decode BGRA in presentation order. Metadata loading is actor coordinated with generation checks after suspension. Blocking sample reads, reader construction and cancellation share one serial Dispatch queue per slot; they never block Swift cooperative executor threads. Eight reads on that executor reproduced a loading stall; the same eight-source probe succeeds with this queue ownership. Source Out is bounded by the video track extent rather than an audio-only tail. PTS 0 is valid. Initial/internal uncovered intervals stay gaps; low-FPS predecessor search expands toward track start. Preferred video transform maps upright source coordinates into encoded pixel coordinates without changing surface crop/mask.

A paused frame must cover the exact requested source time. During uninterrupted playback, an adjacent frame may remain visible for at most 120 ms of show time while a new one decodes. Cut/trim/wrap/seek/relink/document changes invalidate it first. Decoder failure/loading uses explicit Black or Skip, never procedural checker fallback. Black is an opaque black source subject to normal surface opacity/color/blend; Skip removes that surface from composition. No dropped-frame, latency, drift, performance or long-show guarantee follows from this policy.

Ordinary audio is active only for assets assigned directly to current surfaces, independent of surface visibility/opacity/routing. An inactive library asset is muted and paused. Keeping the same assigned source set does not seek or change an ordinary asset's volume. Montage video decoders have no audio output. Audio montage, reverse, overlap/crossfade, waveform editing and clip recording remain open.
