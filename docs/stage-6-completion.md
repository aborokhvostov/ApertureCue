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
