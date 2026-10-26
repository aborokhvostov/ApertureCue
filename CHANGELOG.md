# Changelog

## 0.1.0-alpha.5 candidate — textured line and Bezier paths, 2026-10-27

- Add round-cap/round-join textured polyline and cubic Bezier surfaces inside projective/mesh cages, with bounded adaptive flattening and single coverage at self-crossings.
- Add working path creation, canvas anchors/tangents, numeric node/width/closed editing, shape-preserving cubic insertion, removal and Undo/Redo. World edits invert group and warp frames; shape changes reject invalid geometry atomically.
- Add schema 4 path persistence/migration and compatible scene interpolation. Keep local tolerance, cage clipping, 16:9 width metric and nearest-segment UV seams explicit.
- Local verification: 57 standalone core methods, 46 GPU/media checks, 23 editor checks and 11 lighting/UDP checks passed; native path editing/save/relaunch/open passed. Remote CI/release are pending; see status.

## 0.1.0-alpha.4 — hierarchical groups, 2026-10-27

- Add UUID group hierarchies with affine/shear transforms, inherited per-layer opacity/visibility, numeric world-space translate/scale/mirror/rotation and pivots. Assign/reparent preserve world geometry; Dissolve preserves surfaces, media and scene references with Undo/Redo. A guard prevents losing direct opacity automation when dissolving non-unit-opacity groups.
- Add working group dialogs and surface parent selection; grouped world handles map back into local geometry while input/masks stay in source UV. Source/mesh mode priority is consistent, and inactive lighting no longer recomputes the hierarchy.
- Introduce schema 3 with legacy label migration across current surfaces and cues. Group setup is shared project state; surface-only scenes do not capture it. Different group frames switch with their output/mesh at the cue midpoint.
- Preserve dirty/history when a running scene is interrupted by a no-op edit or Undo; reject cycles, missing refs, invalid transforms and out-of-range geometry atomically. Identity/same-parent operations are exact no-ops.
- Add original Groups demo. Core: 50 assertion methods; production GPU/media: 39 checks; editor: 20 checks. Vector overlay fixes black preview regions after group dialogs and keeps cages aligned with mouse coordinates; native Dissolve/Undo/Redo/save/relaunch/open passed. Exact-source macOS/Linux CI passed 50 XCTest each, macOS release/native build, signature, archive and artifact.


## 0.1.0-alpha.3 — perspective primitive surfaces, 2026-10-26

- Add triangle and ellipse primitives in the existing four-corner perspective cage, with shape-aware selection/contours, independent source crop, mesh, source-mask intersection and local edge feather. Signed-distance clipping includes derivative antialiasing. Free three-vertex UV editing remains outside this subset.
- Add working creation buttons and inspector shape control with undo/redo; Input mode previews the complete source. Include an original procedural Shapes demo.
- Introduce project schema 2 with v0/v1 quad migration, explicit shape persistence in scenes/portable collection, unknown-shape rejection and future-version protection for older builds.
- Local verification: 43 core assertion methods, 35 production GPU/media checks, 13 editor integration checks and 11 GPU-to-UDP lighting checks. Native GUI creation, cage editing, full source preview, built-in fullscreen and save/relaunch/open passed; macOS/Linux CI passed 43 XCTest each; macOS release build, native bundle/archive/artifact also passed on `3bcab64`.


## 0.1.0-alpha.2 — SDK compatibility and frame ownership, 2026-10-26

- Use stable Objective-C camera-disconnect and session-error notification names across Apple SDKs; macOS CI exposed Swift API renames that the newer local SDK accepted. The entire application also passes local type-checking against macOS 15.4 SDK.
- Acquire each media source once per composition and retain exactly its CoreVideo frame wrappers until GPU completion, including asynchronous sampling. Repeated video surfaces now have a dedicated frame-consistency check.
- Capture immutable UDP packet/error snapshots and explicit main-actor sendable shutdown completion.
- Keep fullscreen output above the menu level and verify the real output constructor/Escape path. Native GUI import, geometry edits, save/reopen and forced-termination recovery were exercised in an isolated copy.
- Keep surfaces absent from a recalled scene disabled so automation targets remain valid and the recalled document stays savable/undoable. Same-path relink reloads a restored resource instead of reusing a failed cache entry.
- Verified Linux XCTest: 38 tests, zero failures. Local GPU/media suite: 29 checks; editor integration: 11 checks; lighting pipeline: 11 checks. macOS CI passed SwiftPM release build, XCTest, native packaging and artifact upload on `12a2356`; see status for the verified run.

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
