# Architecture

This document describes the current code and the boundaries for later stages. [behavior-spec.md](behavior-spec.md) is the acceptance target; [status.md](status.md) records which parts have actually passed checks. The implementation does not reproduce MadMapper internals.

## Stack decision

The first target is the current macOS host. Swift, AppKit, Metal/MetalKit and AVFoundation provide an executable desktop/media/GPU path using the installed Apple toolchain. The native build has no package downloads and can bypass a locally broken SwiftPM manifest linker. This makes a working macOS implementation possible without first provisioning Qt 6, CMake or a particular FFmpeg build.

This choice has an explicit cost: AppKit, Metal and AVFoundation are platform adapters. They are not a cross-platform desktop backend. The independently testable `MappingCore` uses Foundation without AppKit/Metal; its geometry, schema and packet code can be exercised on Linux. Windows and Linux desktop ports need their own GUI/render/media adapters. Qt/C++20 with FFmpeg remains a possible future implementation boundary, not an existing dependency or claimed port.

License and system-library treatment are recorded in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No codec bundle or vendor SDK is silently included. The current media backend can only decode what the installed AVFoundation supports.

## Modules and ownership

| Boundary | Current code | Responsibility / limits |
|---|---|---|
| Project model | `MappingCore/Project.swift` | Value types, stable UUID references, assets, surfaces, outputs, surface snapshots, fixtures and parameter tracks |
| Commands/history | `MappingCore/EditHistory.swift` | Before/after document snapshots; capacity 100; one drag commit; not persistent history |
| Geometry | `MappingCore/Geometry.swift` | Quad validation, homography, regular mesh and coordinate math |
| Static OBJ projection | `MappingCore/Scene3D.swift` | Bounded polygonal OBJ parser, pinhole camera and baking into editable 2D quad patches; no live scene/depth renderer |
| Persistence | `MappingCore/ProjectStore.swift` | JSON schema, migration 0→1, validation, relative paths, atomic write/recovery and portable-project collection |
| Show logic | `MappingCore/ShowControl.swift`, `SelectiveCue.swift`, `TimelineRuntime.swift` | Full/selective surface recall, host-time transitions, compiled scalar automation and bounded master-clock events |
| Cue editor | `ApertureCue/CueControls.swift`, `CueWindow.swift` | Explicit capture/recapture, saved properties and per-surface field masks; no cue-owned timelines |
| Packet/fixture core | `MappingCore/Protocols.swift` | OSC, ArtDMX, sACN packet codecs and RGB/GRB/RGBW fixture sampling with address validation |
| Media adapter | `ApertureCue/MediaPool.swift` | Texture-loader images, AVPlayer movies and latest-frame camera capture shared as Metal textures |
| GPU backend | `ApertureCue/MetalRenderer.swift` | Per-view Metal queue/pipelines, homography shader, masks, blend and readback |
| Output windows | `ApertureCue/AppDelegate.swift` | Distinct windows/views/renderers, display selection, surface route and blackout |
| Controls | `ApertureCue/NetworkController.swift` | Opt-in localhost UDP OSC, CoreMIDI adapter and command routing |
| Lighting adapter | `ApertureCue/LightingController.swift` | Bounded asynchronous composition sampling, raw-channel simulator and opt-in IPv4 UDP output |
| Advanced panels | `ApertureCue/AdvancedControls.swift` | Camera selection, linear track editing and basic strip layout/output configuration |
| Editor | `AppDelegate.swift`, `CanvasOverlay.swift`, `Controls.swift` | Native UI, selection/handles, mutation coordination and inspector |
| Demo/QA | `DemoGenerator.swift`, `SelfTest.swift`, `LightingSelfTest.swift` | Original test media, production-render/media checks, visible benchmark and full sampled-lighting localhost loopback |

`EditorController` is currently a deliberately small orchestration point and still combines file dialogs, show recall, rendering configuration and output management. The next refactor should extract an editor document/controller and show runtime before adding a multi-track timeline. That refactor must preserve tested behavior rather than substitute interfaces for working adapters.

## Geometry and rendering

Input UV and output vertices are independent normalized quads. Homography is solved in the core. The Metal fragment function evaluates projective sampling for quads, avoiding the diagonal artifact of affine texture interpolation. A regular mesh provides piecewise mapping. Quad, canonical triangle and ellipse primitives live in local cage space independently of source UV; Metal clips with signed distances, derivative antialiasing and local edge feather. The editor projects their contours and tests geometric shape membership, including overlapping mesh triangles; source masks remain separate appearance controls. Four output handles still edit the cage. Bézier tessellation, free three-vertex triangles and arbitrary topology remain later requirements.

Each output view has its own render target and `MetalRenderer`. A single `MediaPool` shares source textures across them. Arrays render back-to-front; the editor explicitly labels that order. `outputID == nil` means all outputs. Preview uses the same renderer and adds the editor overlay separately.

Current GPU format is 8-bit BGRA/RGBA unorm with normal/add/multiply/screen modes. This is not a complete color-managed, HDR or linear-light pipeline. Blend factors, brightness/gamma/tint, polygon mask and edge feather are checked with deterministic pixels for this declared format. Automatic projector soft-edge setup, arbitrary mask feather and black-level correction remain separate features.

Live rendering allows at most three submitted command buffers per renderer through a nonblocking semaphore. If all slots are busy, the next draw is skipped and counted; the UI does not wait for GPU completion. GPU completion retains CoreVideo texture wrappers until in-flight commands finish. A missing media texture uses the surface's procedural fallback. Errors remain diagnostics instead of invalid handles.

Still export and QA use an explicit offscreen render followed by `waitUntilCompleted`, BGRA readback and conversion to RGBA bitmap. That path is intentionally separate from live rendering. Its throughput must not be described as live display FPS. Lighting uses a separate asynchronous snapshot path with one pending readback; completion copies/swizzles on a worker queue and returns the result to the main thread.

## Group coordinates and editor commands

`MappingCore/Groups.swift` stores full 2D affine matrices (including shear), UUID parent links, per-group opacity and visibility. Iterative resolution rejects cycles, missing references, depth over 64, more than 4096 groups, singular/ill-conditioned matrices and finite coordinates outside the declared range. All saved current/cue geometry is validated after group composition. A batched context serves a complete list of surfaces; rendering does not mutate local document geometry.

Timeline evaluation runs before group flattening. The compositor, each output and lighting sampler receive flattened output/mesh coordinates and inherited opacity/visibility once. Source UV, masks, routing and flat back-to-front layer order are preserved. Groups are non-isolated: there is no extra compositing texture or whole-group blend/FX. Group transforms are shared project state; current surface-only scene snapshots do not capture them. Different group frames switch together with output/mesh at the cue midpoint, avoiding interpolation between unlike coordinate spaces.

Assign/reparent preserve world geometry using inverse parent matrices. The editor maps world handle drags back to the selected surface's local frame; input and source masks never use that inverse. Numeric group commands compose a world-space delta through the parent inverse, keep local member vertices intact, validate a candidate Project and commit one history value. Dissolve composes into direct child groups or bakes direct current/cue surfaces. An explicit guard prevents non-unit group opacity from being lost under direct surface opacity automation. Group labels shown in controls are bounded and built once per refresh. Editor handles/contours use transparent CAShapeLayer/CATextLayer content rather than an AppKit raster drawing cache over the CAMetalLayer; the backing view manages its layer coordinate convention ([Apple CALayer reference](https://developer.apple.com/documentation/quartzcore/calayer/isgeometryflipped)).

Interrupted scene recalls commit their changed intermediate state before a new edit/undo; no-op edits cannot silently drop dirty/history state. Invalid hierarchy resolution yields an empty composition and a diagnostic, never an untransformed output fallback.

## Threads, media queues and time

The editor model, media coordinator and render configuration are owned by the main thread. Image decode/texture loading uses a serial worker queue; completion checks that the source entry is still current. AVFoundation owns decode scheduling. The application retains one latest image/movie texture per asset and does not append decoded frames to an unbounded application queue. Internal AVPlayer buffering is opaque to the application and is not a measured guarantee. The camera adapter starts/configures capture on a private queue, discards late frames and exchanges a single latest pixel buffer through a lock. Permission is requested only by Camera UI action; device failure is a diagnostic.

`MediaPool` uses monotonic host time for its transport display, with per-asset AVPlayer clocks for actual movie playback. Play/pause/seek fan out to those players, and an end notification performs per-asset looping. This is sufficient for the first independent media path, but it is not a shared hardware clock or frame lock between players. Generation-tagged seeks, decoder PTS/drop telemetry and drift correction remain hardening tasks.

The editor's tick runs at approximately 30 Hz for state/status/snapshot transitions; MTKView requests 60 Hz rendering. Neither timer setting guarantees the measured FPS. Audio currently uses AVPlayer volume and system routing; the future audio engine needs an explicit device clock and channel matrix.

OSC socket parsing runs on a dedicated dispatch queue and sends typed commands to the main thread. Work per callback is limited to 64 datagrams, while the OS socket buffer bounds unread datagrams. OSC/MIDI bridge commands pass through a locked mailbox that retains at most 256 pending commands and one scheduled delivery batch; excess old commands are dropped. MIDI sources have independent parser state. A general address-learning UI and network-host exposure remain separate work.

## Persistence

Schema 6 is a self-contained JSON document describing references, not a copy of media bytes. The suggested filename is `<name>.aperturecue.json`. `ProjectStore` reads at most 16 MiB, validates counts, IDs, finite coordinates, quads, supported values and references, and rejects unsupported future versions. Versions 0/unversioned and 1 load as quad shapes; version 2 retains explicit primitive shapes. Versions 0…2 migrate exact nonempty legacy group labels to shared root UUID definitions across current surfaces and scene snapshots. Version 3 persists group IDs, parents, affine coefficients, visibility and opacity; legacy string labels are rejected in normalized v3 documents. Saving a legacy in-memory model also upgrades its labels. Older alpha 1…3 readers reject v3 rather than silently losing hierarchy.

Media paths are absolute in the in-memory model and become relative to the project file on save. Paths may include `..`; relative references alone do not make a project portable if its media stays elsewhere. `ProjectStore.collect` resolves regular media files, copies them to a new sibling staging directory under UUID-derived filenames, saves `project.aperturecue.json` with relative references, reloads/verifies the result and renames the completed directory into the new destination. Missing/non-file media aborts the operation; only that invocation's random staging directory is cleaned. Existing destinations are rejected. Camera identities are retained as live IDs. The UI collects a value snapshot on a background queue and keeps the open project unchanged.

Save uses Foundation atomic data writing. Recovery is a distinct hidden sidecar beside the project, updated about every 10 seconds for a dirty, named document. Successful manual save removes that sidecar; New/Open clears the in-memory edit history. Opening offers recovery if the sidecar exists. Current limitations include no timestamp freshness filter for externally copied/remaining sidecars, no recovery for an unnamed document, no rotating manual backups and no proven power-loss durability. The isolated GUI workflow includes process-kill/restore/save; it does not establish power-loss durability.

## Show and controls

Current scenes remain surface-only snapshots. `CueScope.full` retains the established snapshot/ordering/visibility transition path. `CueScope.selective` carries per-UUID `CueBinding` masks and snapshot payloads; `CueSelection.destination` merges selected fields onto the current ordered surface list. Missing UUIDs skip with a visible editor diagnostic, without resurrection. Unselected fields, names, IDs, current order and additional layers remain current. Groups, asset definitions, fixtures, output configurations and clocks are not captured by either mode.

`CueParameter` defines 13 atomic units: opacity, brightness, gamma, RGB color, feather, blend mode, visibility, source (media ID plus generator), input quad, output geometry (output quad plus mesh/dimensions plus parent ID), shape (selector plus stroke), source mask and output routing. Shared `CueSelection.validate` rejects duplicate/empty targets or masks, mismatched snapshot IDs and invalid timing. Project validation checks structural snapshot payloads and active references. Unselected media/output/group references are dormant: validation clears those references in a temporary projection without rewriting the stored snapshot. Enabling a resource-bearing field requires its references to exist again.

The selective interpolator starts from the current surface and changes only included fields. Numeric values interpolate linearly; discrete fields switch at the midpoint. Compatible input/output geometry, masks and stroke payloads interpolate with endpoint fallback for invalid quads or strokes; incompatible topology/coordinate frames switch atomically. Unlike the full path, selecting visibility alone does not modify opacity, and hidden surfaces retain excluded values. The adapter validates the merged destination Project before starting a recall, preserving history/document state on rejection. An interrupted transition latches the actual intermediate document before the next mutation/recall; no-op edits still commit changed recall state.

The cue editor separates draft masks from saved values. Capture creates a new cue; saved scope is fixed. Save updates metadata/timing/masks without sampling live values, while Recapture explicitly samples current targets using the draft mask. Removing every selected field removes that snapshot target. Saved-cue rows use the stored snapshot; New draft uses current surfaces. New/Open close the old cue window and reset its selection/draft. Deleting a cue removes its marker references and tracks that no longer have a target among current surfaces or remaining full snapshots, in one validated history command.

Recalls do not request media play/pause/seek or reset the show clock. Scalar automation overlays the recalled base surfaces before group resolution, so an active track continues to override its field. The host-clock cue fade remains independent of timeline Pause. Cue-owned timelines, launch quantization, timeline clips, scheduling and external synchronization remain open requirements.

The network listener binds only `127.0.0.1` and starts on explicit UI request. It accepts the documented `/aperturecue/...` command subset. OSC Query, network discovery, remote-host input and general learning/routing UI are absent. MIDI provides a fixed note/CC profile.

Basic lighting now connects fixture sampling to the compositor. A 320×180 offscreen output composition is sampled with nearest-pixel lookup at up to 30 Hz. A fixture is a line of normalized pixel positions, with RGB/GRB/RGBW channel order and one-based address; overlap and cross-universe spans are rejected. The raw-channel simulator is independent of hardware. Explicit numeric IPv4 output sends ArtDMX to 6454 or sACN data to 5568 on a worker queue; ArtDmx also binds source port 6454. Sequence state is separate per protocol/universe; sACN wraps modulo 256 including zero. One in-flight ordinary sender frame is allowed and excess work is skipped.

Stop invalidates pending sampling generations and sends zero ArtDmx, or an ordinary zero sACN data packet followed by three Stream Terminated packets. Termination values alone are insufficient because receivers ignore them. A validated target/protocol change first stops the old destination. New/Open also stops lighting and resets show transport. Quit uses deferred application termination to drain the sender queue, with a one-second fallback; UDP delivery remains unacknowledged. Defaults do not send network traffic. The target/protocol are runtime settings, not serialized output configuration. Full fixture definitions, moving lights, 16-bit channels, sync/discovery, protocol conformance, recording and hardware certification remain separate gates. Required Art-Net attribution and pending OEM registration are in the user guide/notices.

## Static OBJ import boundary

The parser accepts a bounded polygonal Wavefront OBJ subset and triangulates planar faces while preserving UV seams. It never follows MTL/external-file directives. Reading/parsing/projection run on a background queue; a document-generation guard discards late results after New/Open. The editor's import action creates a fixed pinhole camera from Z/FOV, looks toward the origin and bakes each triangle into three convex quad patches, assigned to the selected media. Projection import is capped at 1365 triangles; the resulting own project stores ordinary patches, not an OBJ source scene.

Painter ordering uses average triangle depth. There is no depth buffer, live camera/model transform, lighting/shadows, near-plane clipping of polygons or projector calibration; crossing/out-of-range triangles are skipped. This distinction matters for intersections and camera movement: reimport is needed for a new projection. Parser/projection math and visible imported patches can be tested while the full 3D/scanning roadmap stays open.

## Future platform and SDK boundaries

Preserve the project schema and deterministic core when introducing protocols such as `MediaSource`, `RenderBackend`, `OutputTarget`, `ControlEndpoint` and `HardwareAdapter`; their current concrete responsibilities are visible above. Interfaces should be extracted from actual second implementations rather than added as empty plugin registries.

Windows/Linux paths require a native or Qt-based UI, Vulkan/OpenGL/another backend, a specific FFmpeg build configuration and OS MIDI/audio/display adapters. Interchange tests must render the same own project against the same geometry/pixel tolerances. Core-only CI does not certify these backends.

SDKs with redistribution or GPL compatibility constraints remain optional and absent from the base build. Each adapter needs exact license/configuration review, capability discovery, timeout/disconnect behavior, simulator/loopback checks and separate hardware verification. In-process optional loading is not a license workaround. 3D/calibration, structured-light scanning, standalone output and laser modules each need acceptance evidence beyond a visible UI control.

## Build and measurement

SwiftPM describes `MappingCore`, `ApertureCue` and XCTest targets. `scripts/build.sh` directly compiles the same sources into an ad hoc signed macOS app when local SwiftPM is broken. `scripts/test-core.sh` uses the same test bodies with the project's fallback assertion runner when XCTest is missing. Both paths should remain reproducible and the remote SwiftPM result should be reported separately.

CI defines macOS build/test/package and Linux core tests; Windows jobs are pending. Native build clears generated-bundle extended attributes before ad hoc signing; notarization remains separate. Local core, GPU/media and OSC/lighting loopbacks have passing development results, and the app has been launched and visibly inspected. Exact revision/counts and remaining manual gates are kept in status, rather than inferred from the test source.

`--self-test`, `--protocol-loopback`, `--lighting-test` and `--benchmark` are separate entry points. Offscreen integration reports include their own resolution/source/surface/output count and elapsed CPU/GPU data. The short visible benchmark measures actual drawable submission/completion and sampled process CPU/RSS; it does not measure optical refresh or decoder throughput. No GPU utilization percentage, long-run stability, decoder-drop count, external-output result or performance target is inferred from shader source or timer frequency.

`scripts/package.sh` verifies and archives the current arm64 app together with the original demo, license/notices and first-run instructions. It prints an archive SHA-256 and does not sign with a Developer ID, notarize, or create a universal binary. See [packaging.md](packaging.md) for the source/binary staging workflow and the distinction from app-only CI artifacts.

## Textured stroke surfaces

`StrokePath` stores 2...32 local anchors and independent cubic tangents, width and open/closed state. Line ignores tangents; Bezier uses cubic segments. Finite-segment control-hull bounds drive bounded de Casteljau subdivision (0.0005 local 16:9 metric tolerance, 256 segments, depth 10); exhaustion rejects the edit. Coincident endpoints and collinear reversal are explicitly tested. Width uses cage-height units and the full path is clipped to the cage.

Metal evaluates the nearest segment capsule once per fragment. Arc length supplies longitudinal UV and signed normal distance supplies transverse UV before the independent input homography/mask. Round joins/caps and self-crossings use one coverage/opacity evaluation; exact ties retain the first segment, with accepted UV seams. Unit directions and metric lengths are calculated in Double before Float upload so very short absolute endpoints cannot collapse into a zero denominator. Changed paths alone rebuild the renderer's bounded per-visible-surface segment buffer cache. This is O(segment count) fragment work, not a new throughput claim.

The editor projects anchors/tangents through group/cage/mesh and inverts the same frames on edits. A batched centerline helper splits local segments at mesh-cell/diagonal crossings, preserving the visible warp in overlay guides. Folded meshes choose the first covered triangle for inverse editing. Shape conversion validates the candidate before history publication. Scene paths interpolate only compatible node/closed/shape/group frames, falling back to a discrete path if an intermediate curve collapses or exhausts its precision budget.

Schema 4 stores the path payload across surfaces and scene snapshots. Loading/saving pre-v4 models clears stroke extension data while retaining established primitives/groups; pre-v3 label migration remains independent. Older binaries reject the new schema. This stroke subset does not provide freehand smoothing, filled paths, alternate join/cap modes or Bezier mesh/masks.

## Parameter timeline runtime and editor

`ShowRuntime` owns master monotonic time, duration/continuation, loop range and marker traversal independently from AVFoundation movie clocks. `TimelineProgram` compiles validated enabled tracks once after project mutations; each sample uses binary search. `AutomationCurve` caches validated scalar keys for the graphical editor. Hold/linear/Bezier are outgoing-key modes; normalized monotonic cubic time is inverted by bounded bisection, with bounded y controls preventing value overshoot. The canvas caches curve paths separately from playhead redraw.

The main adapter ticks the runtime, sends ordered scene markers to the existing host-clock CueEngine, applies compiled parameter values, then resolves groups once for editor/output/light composition. Explicit seek/wrap/pause/end reconciles media play/pause/seek. Manual scene fades retain their independent host-clock behavior while the parameter timeline is paused. Decoder frame lock and physical event latency are not claimed.

Markers use strict forward crossing (old,new]; seek never fires, pause latches exact time, and loop-start landing is not a new crossing. A 256-event/loop budget bounds delayed ticks; excess cues are skipped visibly while earliest pause remains mandatory. Changed configurations validate atomically, drain naturally elapsed old events into a bounded one-shot queue, then publish the new program. Seek/Stop clear stale queued events. Time-zero automatic markers reject explicitly.

Schema 5 stores timeline settings, pause/scene marker IDs and key easing/controls. v0...v4 normalize keys to linear and migrate to stopAtEnd=false continuation, preserving old long media playback; new projects default to a 10-second finite graph. Continuation time can exceed the graph horizon up to the global 365-day bound. Named scene deletion removes referencing markers and newly orphaned tracks in the same history snapshot. New/Open close the old timeline window and reset runtime/selection. No clip montage, recorded automation, network event tracks, external clock or Conductor bank runtime is implied.


## Selective cue schema and group edits

Schema 6 requires explicit cue `scope` and `bindings`. Project decoding treats schema 0…5 cues as full snapshots and ignores extension keys with those names; saving/loading upgrades them through the existing geometry/group/stroke/timeline migrations. Schema-6 unknown scopes/parameters, missing required cue keys and malformed bindings fail rather than silently widening recall. Older readers reject the unsupported project version. Only current surfaces and full snapshots keep absent-surface automation targets eligible: selective snapshots cannot resurrect a deleted layer.

Dissolve evaluates selective masks when preserving endpoint appearance. Selected geometry is converted with its parent frame; excluded dormant frames are retained. If geometry is excluded, selected appearance conversion follows possible direct membership in current/full/geometry-selected states rather than its dormant snapshot parent. Guards reject ambiguous inside/outside frames, geometry recalls that would lose inherited opacity/visibility, and direct opacity automation conflicts. Baking can change the transition path between preserved endpoints. Group definitions remain shared state, so this is an independently specified edit policy rather than a full group-pose snapshot system. Automatic, manual and hardware evidence are recorded separately in status/matrix and verification logs; this description makes no release or hardware verification claim.
