# Stage 6 · Light engine

Schema 16 adds independently authored fixture profiles, layout import, native
patch and monitor panels, and additive lighting-adapter modules. Existing
strip fixtures keep their original RGB/GRB/RGBW slot order and point sampling.

| Matrix | Software scope |
|---|---|
| L01 | Asynchronous 320×180 composition batch per sample, logical output and edge blend routing, nearest and box kernels. |
| L02–L05 | Native edit/save/Undo, address validation, 8/16-bit fixture roles, matrix/serpentine and reserved skipped slots, surface-driven position and dimmer. |
| L06 | Transactional CSV and native JSON patch import, JSON export, and SVG positions through the existing safe geometry parser. |
| L07 | 512-slot monitor, bounded single-universe local input, explicit routing to armed network output, freshness timeout and retirement. |
| L08 | Portable raw DMX sequence, bounded capture, atomic files, simulation and opt-in replay through the existing sender. |
| L09 | Ambient-compensated grayscale scan stack decoding, missing/ambiguous slot diagnostics and opt-in import with reserved gaps. |
| L10 | Buffered USB-DMX packet preview/export, optional explicit macOS serial sender and SPI RGB payload preview/export. |

Tests use original procedural colors, scans, binary traces, localhost UDP and
injected adapter sinks. Real fixture modes, sensor/camera calibration,
USB interface models, electrical SPI and field-network timing have independent
hardware checks. The Art-Net OEM and current E1.31 conformance scope follows the
[lighting transport specification](lighting-transport-spec.md).

[Light engine and layout formats](light-engine-spec.md) · [DMX sequences](dmx-sequence-spec.md) ·
[Scan capture import](led-scanner-spec.md) · [Adapter module](lighting-adapter-spec.md)

## Verification

- The standalone assertion harness ran 199 core methods with zero failures.
  The exact source ran 199 XCTest on macOS and 199 on Linux. The macOS job
  also ran SwiftPM release, native bundling, ZIP packaging and artifact
  upload. [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45958866571)
- The optimized native integration used two routed procedural surfaces at
  320×180 on an Apple M2. The first 20 wall slots included a four-slot
  zero gap. The virtual head yielded exact coarse/fine bytes `128, 0` at
  normalized Pan 0.5, and the relay delivered `42, 97` at the local sACN
  receiver before enumerated retirement. The USB worker used only virtual
  sinks. [Reports](verification/stage-6/)
- The visible diagnostic editor added a disposable RGB line spanning
  slots 1–48 and edited a 16-bit channel draft spanning slots 1–80.
  Accessibility polling timed out when leaving that modal window.
  Save/Open, Undo/Redo and the exact routed DMX output were verified
  by the optimized integration. The visible extracted app opened its built-in
  demo and showed the Light menu. [Manual diagnostic](verification/stage-6/manual-diagnostic.json) ·
  [Extracted app launch](verification/stage-6/manual-release.json)
- The ZIP passed executable mode, signature, CRC and byte equality.
  Eight focused extracted modes passed. [Archive](verification/distribution.md#alpha-19)

All 24 production modes passed. The separate 120.006-second regression played
four original 160×96 H.264/MOV sources at 30 fps with no logical outputs. It
recorded 13,640 pulls, 705 without an eligible frame, 118.304 ms maximum legacy
clock drift and 200.004 ms maximum eligible managed PTS age. [Media report](verification/stage-6/media-soak.json)
