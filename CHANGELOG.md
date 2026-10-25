# Changelog

## 0.1.0 — initial development stage, 2026-10-25

### Added

- Native macOS 13+ AppKit desktop editor with Metal quad rendering, independent source/output corners, procedural fallback sources and a separate output window.
- MTKTextureLoader image import and AVFoundation movie playback, play/pause/seek/loop, volume and media relinking.
- Surface editing, layer order, normal/add/multiply/screen blending, color controls, regular warp mesh, polygon mask and edge feather.
- Surface snapshot capture/recall/transitions and opt-in localhost OSC/MIDI control adapter.
- Persisted linear parameter tracks for opacity/brightness/gamma/RGB, a latest-frame camera adapter, LED strip layout/sampling, raw-channel simulator and opt-in IPv4 Art-Net/sACN UDP output.
- Bounded OBJ parser and static pinhole projection imported as three editable quad patches per triangle, with painter ordering and explicit clipping/scene limitations.
- Background portable-project collection into a new folder with copied UUID-named media, relative references, validation and atomic publication; live camera identities are preserved.
- Portable project/geometry/show/protocol core, schema-1 JSON with version-0 defaults, validation, relative media references, atomic save, named-project recovery sidecar and bounded in-memory undo/redo.
- OSC/ArtDMX/sACN packet code and RGB/GRB/RGBW fixture sampling with overlap and universe-boundary validation; the strip output is an initial lighting subset.
- Original PNG/H.264 demo generator, core test suite and production Metal/AVFoundation self-test with explicit measurement scope.
- Direct native build/test fallback scripts, macOS/Linux CI definition, research catalog, behavior specification, architecture, guide and GPL-3.0-or-later licensing.

### Hardened

- New/Open resets history, show transport and lighting sampling; pending sampling uses a generation check to avoid applying a previous document's readback.
- Manual saving removes the recovery sidecar, and demo video encoding uses a temporary output before moving the completed file into place.
- OSC/MIDI delivery uses a 256-command main-thread mailbox; lighting Stop sends zero-valued ArtDmx or ordinary zero sACN data followed by three stream-termination packets. Sequence counters are separate per protocol/universe and sACN wraps modulo 256.
- Local protocol and production lighting loopback commands and a visible-drawable benchmark produce explicit reports. Native app signing clears generated bundle extended attributes before applying the local ad hoc signature.
- Changing a lighting target/protocol ends the old stream before applying validated replacement settings. Quit waits for the lighting sender queue with a bounded one-second fallback.
- OBJ reading/projection runs off the UI thread and discards late results after a document switch. The release packaging script includes the app, original demo, license/notices and first-run instructions with a SHA-256 digest.

### Known scope

This is a development implementation, not a confirmed complete MadMapper alternative. Full selective cues/timeline, advanced Bézier/groups/masks/blending/FX, general fixture definitions/moving lights/advanced protocol behavior, external video SDKs, live 3D/depth/calibration/scanning, multichannel routing, offline show export, standalone playback and Windows/Linux desktop ports remain open. Art-Net credit is documented; OEM registration is pending. Verification results are recorded in [status](docs/status.md); this change log does not assert unobserved test passes, remote CI success or hardware compatibility.
