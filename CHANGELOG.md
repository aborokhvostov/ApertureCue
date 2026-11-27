# Changelog

## 0.1.0-alpha.18 — Control protocols

- Add saved UUID-based MIDI and OSC mappings, Learn, explicitly selected feedback, and a session control panel. Schema 15 migrates earlier projects with no new mappings.
- Add scoped IPv4 OSC send/receive, bounded blob packets and OSCQuery HTTP/WebSocket with opt-in local discovery.
- Add targeted Art-Net discovery diagnostics, bounded lighting updates, IPv4 sACN multicast and optional synchronization.

## 0.1.0-alpha.17 — Show control, 2026-11-27

- Add Conductor banks with independently running automation cells, row exclusivity and explicit parameter priority. Generate and combine show-time signals in a bounded graph.
- Add scene easing, bounded timeline jumps and Undoable retiming of recorded key ranges. Apply instant scene markers in order when a delayed tick crosses several.
- Add timed localhost OSC and virtual MIDI tracks, optional external OSC timecode with loss/reacquisition, local iCalendar import and session-armed scene schedules.
- Extend montage clips with reverse video, adjacent crossfades, separate PCM audio clips and optional forward movie audio.
- Schema 14 migrates earlier projects and preserves their existing hard cuts, transport and linear cue curves. Include an original procedural Show Control demo.

## 0.1.0-alpha.16 — media playback and durability, 2026-11-27

- Add independent per-source transport and saved trim/signed speed/Once/Loop/Hold/PingPong/seeded Random modes. Preserve adjacent source clocks, generation-tag frame publication and source state through relink/refresh; keep ordinary montage/rotation behavior.
- Add naturally sorted frozen image-sequence folders, explicit FPS/Refresh, bounded image payload leases, coalesced loads, permanent corrupt-frame diagnostics and transient admission retry. Include an original media/sequence/stereo-tone demo.
- Add source audio files and bounded PCM routing to an explicit device UID: channel matrix, clipping/master gain, mute, positive speed/trim, exact EOF and paused clock. Reverse/random/hold audio is explicitly silent. Keep decoder cancellation serialized with reads; preserve silence on unavailable devices and allow explicit same-route retry.
- Bind recovery to exact saved bytes/path/mtime, preserve stale/corrupt/legacy sidecars, validate Restore before installing a document, and clear only owned checkpoints on Save/Discard. Extend atomic portable collection to frozen frames/audio and bounded stable file reads.
- Schema 13 migrates earlier projects without activating undefined source extensions. New CLI modes cover source controls/PTS/cache/camera simulation, silent offline audio, guarded forced-process termination and a bounded four-source soak. Software/manual/archive/CI evidence and physical limits are tracked in [stage 3](docs/stage-3-completion.md).

## 0.1.0-alpha.15 — geometry and composition, 2026-11-26

- Add independent regular/Bézier source and output lattices, explicit mesh linking, lattice-preserving cage edits, numeric surface transforms, keyboard nudges and bounded freehand capture. Reject exhausted precision budgets rather than emit a coarse warp.
- Add projective and isolated groups with whole-group blend/FX, multiple layer/group/global polygon and cubic masks, chroma/luma key and color FX. Add output edge ramps, video-wall crops, bounded original SVG raster import and previous-generation feedback with cycle-safe resets.
- Add a typed expression material editor and a declared single-pass ISF expression subset, preserving accepted material pipelines after rejected edits. Include original procedural Composition, ISF and SVG examples.
- Schema 12 persists new fields across documents and surface cues; Material and Effects extend selective snapshots to 15 atomic fields. Keep legacy undefined fields isolated during decoding. Reset and PNG export preserve independent source/composition semantics; malformed parallel mesh arrays fail loading safely.
- Move drawable acquisition off AppKit, preserve static overlay layers during material-clock ticks, and keep gesture tools mutually exclusive. Validate the full visible editor and resize/cancellation/recovery paths independently of offscreen frame tests.
- Verification and remaining hardware/runtime limits are recorded in [stage ledger](docs/stage-2-completion.md), [status](docs/status.md) and the feature matrix. Earlier release archives remain available; older binaries reject schema 12.

## 0.1.0-alpha.14 — polygon vertex editor, 2026-11-26

- Add numeric mask vertex coordinates, midpoint insertion on every closed edge and removal with a 3…128-point bound. Show polygon handle numbers beyond four vertices.
- Keep schema 11 and existing mask/cue semantics. Commands preserve input/output/mesh/group/settings, respect geometry locks, reject invalid changes atomically and support Undo/Redo. Modal edits reject changed documents, selection or surface snapshots.
- Local checks: 100 standalone core methods, 60 editor checks and 51 Metal/media checks from the extracted ZIP; visible numeric editing/insertion/removal/Undo/Redo/minimum-bound workflow passed. Exact-source [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45833970500) passed 100 XCTest on each macOS/Linux, zero failures, and macOS packaging. [Published archive](docs/verification/distribution.md#alpha-14) has matching verified assets.

## 0.1.0-alpha.13 — layer polygon mask controls, 2026-11-19

- Add source UV / output canvas coordinates, inversion and separate mask feather. Keep output masks fixed when a surface, mesh or group moves, applying only to that layer. Geometry lock guards all mask controls.
- Schema 11 preserves legacy source masks and persists settings in surfaces and scene snapshots. Selective Mask owns all settings; incompatible coordinates/inversion switch together at transition midpoint.
- Local verification: 98 standalone core methods, 58 editor, 50 Metal/media and 11 lighting/localhost checks; visible native settings and Undo/Redo verified. Publication/CI/archive evidence is recorded in docs/verification/distribution.md.

## 0.1.0-alpha.8 - recorded inspector automation, 2026-10-27

- Add session-only per-track Arm and Record input for six existing scalar tracks. Continuous inspector gestures replace touched key spans with ordinary linear keys, retain outside key metadata, preview through shared rendering/light composition, and commit one Undo per gesture.
- Stop recording on transport discontinuities, Scene GO and document edits; late native tracking tokens cannot modify a changed document. Accepted keys participate in recovery before history commit. No-input gestures remain clean no-ops.
- Preserve show/media clocks through pure track edits and Undo/Redo; remove spurious media seeks on unchanged show configuration. Run the timer in common modes while sliders track.
- Keep schema 6, compatible with alpha 7 readers; include an original recording-practice project. Local checks passed: 82 standalone core methods, 46 GPU/media, 46 editor and 11 lighting/UDP. Native recording drag, per-gesture Undo/Redo, save/relaunch/reopen and restored curve/seek passed. Fresh ZIP extraction/signature and all 46 editor checks from the archive passed. Exact-source [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40563089950) passed 82 XCTest on macOS and 82 on Linux, zero failures, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

## 0.1.0-alpha.7 — selective surface cues, 2026-10-27

- Add UUID-bound selective surface cues with 13 atomic field masks, numeric/discrete transitions, missing-target diagnostics and current layer/order preservation. Recall retains running show/media clocks and active parameter automation.
- Add a native Scenes editor with per-surface fields, stored/current values, explicit Capture / Save properties / Recapture, timing/follow and complete history. Saved scope is fixed; new capture chooses scope.
- Add schema 6, legacy full-snapshot migration, dormant excluded resource references, group Dissolve guards and atomic orphan-track/marker cleanup on scene deletion. Include an original SelectiveCues demo.
- Local checks passed: 74 standalone core methods, 46 GPU/media, 36 editor and 11 lighting/UDP. Native selective Capture/Save/Recapture/GO/Undo/save/relaunch/reopen and layout regression passed. Fresh archive extraction/signature and all 36 editor checks from the ZIP passed. Exact-source [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40509423121) passed 74 XCTest on macOS and 74 on Linux, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

## 0.1.0-alpha.6 — graphical parameter timeline, 2026-10-27

- Add a separate graphical parameter timeline with multi-track bindings, key insertion/drag/numeric editing, Hold/Linear/Bezier easing and curve handles, enable/delete/history and view zoom.
- Add independent compiled show runtime, duration/continuation, loop range, pause/scene markers and a bounded exactly-once event queue across edits. Existing scenes keep host-clock fades; movie seek/loop synchronization remains independent from decoder frame lock.
- Add schema 5 with legacy linear/continuation migration, preserving long playback beyond the default graph horizon. Time-zero markers reject; deleting scenes cleans marker references.
- Local checks passed: 65 standalone core methods, 46 GPU/media, 29 editor and 11 lighting/UDP. Native key/curve/marker/loop/save/reopen GUI passed. Exact-source CI passed 65 XCTest on macOS and 65 on Linux, plus macOS release/native bundle/signature/archive/artifact.

## 0.1.0-alpha.5 — textured line and Bezier paths, 2026-10-27

- Add round-cap/round-join textured polyline and cubic Bezier surfaces inside projective/mesh cages, with bounded adaptive flattening and single coverage at self-crossings.
- Add working path creation, canvas anchors/tangents, numeric node/width/closed editing, shape-preserving cubic insertion, removal and Undo/Redo. World edits invert group and warp frames; shape changes reject invalid geometry atomically.
- Add schema 4 path persistence/migration and compatible scene interpolation. Keep local tolerance, cage clipping, 16:9 width metric and nearest-segment UV seams explicit.
- Local verification: 57 standalone core methods, 46 GPU/media checks, 23 editor checks and 11 lighting/UDP checks passed; native path editing/save/relaunch/open passed. Exact-source CI passed 57 XCTest on macOS and 57 on Linux, plus macOS release/native build/signature/archive/artifact; see status.

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

This is a development implementation, not a confirmed complete MadMapper alternative. Broader recording tools/montage, advanced Bézier/groups/masks/blending/FX, general fixture definitions/moving lights/advanced protocol behavior, external video SDKs, live 3D/depth/calibration/scanning, multichannel routing, offline show export, standalone playback and Windows/Linux desktop ports remain open. Art-Net credit is documented; OEM registration is pending. Verification results are recorded in [status](docs/status.md); this change log does not assert unobserved test passes, remote CI success or hardware compatibility.
