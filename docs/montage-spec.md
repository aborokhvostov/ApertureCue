# Next stage: source montage specification

**Planned, not implemented.** This is the next engineering boundary after recorded scalar automation. It does not change the schema-6 alpha8 application or assert a montage/render/audio test pass.

The official reference describes assignable montage sources with video/image arrangement, trims, speed/loop, reverse/crossfade and gap policies: [R19 track types](https://docs.madmapper.com/madmapper/6/10.-timelines/track-types-and-inspectors), [R20 clips](https://docs.madmapper.com/madmapper/6/10.-timelines/clips). Exact interval, decoder, conflict and latency policies below are independent design decisions.

## First working boundary

- A montage has a stable source UUID and is assignable to surfaces. Clips reference existing image/video asset UUIDs. No cameras or nested montages in the first subset.
- Clips have stable UUIDs, timeline start/duration and video In/Out, positive rate and loop. Images use start/duration. Start/end uses `[start,end)`; touching clips are legal, overlap within one montage rejects atomically. Reverse and crossfade remain later gates.
- Video position is `In + elapsed * rate`, modulo `Out-In` when looping. A non-loop clip cannot outlast its source span at the chosen rate. Out beyond actual decoded duration reports a runtime diagnostic rather than silently seeking invalid media.
- Gap is explicitly Skip or Black. Missing/warming video must not invoke the surface's procedural fallback or reuse a previous clip's frame. Pause holds the requested position; Seek/Stop evaluates the schedule directly. Boundaries do not generate marker events.
- Cue changes source assignment while the existing master clock/marker rules continue. Montage definitions remain shared project state outside surface snapshots. A persisted montage requires a new schema and explicit older-reader rejection.

## Ownership and timing gates

A montage must not seek/rate/pause the ordinary `MediaPool.Entry[assetUUID]`. One file used by ordinary surfaces and multiple montages needs independent decoder sessions/identities. Images may share immutable textures. Decoder count, loading and caches must have explicit bounds.

Cut, seek, wrap, relink and document replacement invalidate old completion/frame generations. Before an accepted new frame, use the explicit gap/loading behavior. Retain CVPixelBuffer/CVMetalTexture ownership through every GPU submission. Editor/output/light consume the same accepted montage frame. Continuous playback uses anchors/rate, not a seek every tick; actual accepted display PTS and seek latency need measured reports before any synchronization claim.

The first montage video path should be silent. Existing ordinary `MediaPool.play()` starts all entries: muting only new montage decoders would leave the original asset's unrelated audio running. Define source activation/audio ownership and test it; never change a shared asset's volume to hide the problem. Assigned ordinary sources must retain their independent transport/audio behavior.

## Acceptance before publication

Use generated media with distinguishable temporal frames. Test exact starts/ends, trims/rate/loop/gaps, paused and rapid seeks, stale completions, source relink, one file simultaneously ordinary plus two montage positions, source clock/seek-generation isolation, markers/Cue/scalar priority, real output/light frames, Save/Open/Collect/Undo and malformed UUID/range/overlap/budget rejection. Record actual frame PTS/tolerances, delayed-frame behavior and unmeasured metrics. Native GUI and fresh archive/CI remain separate gates; no external-device compatibility follows from these tests.
