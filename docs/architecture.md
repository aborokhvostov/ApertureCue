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
| Show logic | `MappingCore/ShowControl.swift` | Host-time transport, snapshot interpolation, validated tracks and seek-independent linear evaluation; full graphical timeline pending |
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

## Threads, media queues and time

The editor model, media coordinator and render configuration are owned by the main thread. Image decode/texture loading uses a serial worker queue; completion checks that the source entry is still current. AVFoundation owns decode scheduling. The application retains one latest image/movie texture per asset and does not append decoded frames to an unbounded application queue. Internal AVPlayer buffering is opaque to the application and is not a measured guarantee. The camera adapter starts/configures capture on a private queue, discards late frames and exchanges a single latest pixel buffer through a lock. Permission is requested only by Camera UI action; device failure is a diagnostic.

`MediaPool` uses monotonic host time for its transport display, with per-asset AVPlayer clocks for actual movie playback. Play/pause/seek fan out to those players, and an end notification performs per-asset looping. This is sufficient for the first independent media path, but it is not a shared hardware clock or frame lock between players. Generation-tagged seeks, decoder PTS/drop telemetry and drift correction remain hardening tasks.

The editor's tick runs at approximately 30 Hz for state/status/snapshot transitions; MTKView requests 60 Hz rendering. Neither timer setting guarantees the measured FPS. Audio currently uses AVPlayer volume and system routing; the future audio engine needs an explicit device clock and channel matrix.

OSC socket parsing runs on a dedicated dispatch queue and sends typed commands to the main thread. Work per callback is limited to 64 datagrams, while the OS socket buffer bounds unread datagrams. OSC/MIDI bridge commands pass through a locked mailbox that retains at most 256 pending commands and one scheduled delivery batch; excess old commands are dropped. MIDI sources have independent parser state. A general address-learning UI and network-host exposure remain separate work.

## Persistence

Schema 2 is a self-contained JSON document describing references, not a copy of media bytes. The suggested filename is `<name>.aperturecue.json`. `ProjectStore` reads at most 16 MiB, validates counts, IDs, finite coordinates, quads, supported values and references, and rejects unsupported future versions. Versions 0/unversioned and 1 migrate to version 2 with quad shapes for current surfaces and snapshots. Version 2 stores explicit quad/triangle/ellipse shapes; unknown shapes are rejected. Older alpha 1/2 readers reject version 2 rather than silently losing the shapes.

Media paths are absolute in the in-memory model and become relative to the project file on save. Paths may include `..`; relative references alone do not make a project portable if its media stays elsewhere. `ProjectStore.collect` resolves regular media files, copies them to a new sibling staging directory under UUID-derived filenames, saves `project.aperturecue.json` with relative references, reloads/verifies the result and renames the completed directory into the new destination. Missing/non-file media aborts the operation; only that invocation's random staging directory is cleaned. Existing destinations are rejected. Camera identities are retained as live IDs. The UI collects a value snapshot on a background queue and keeps the open project unchanged.

Save uses Foundation atomic data writing. Recovery is a distinct hidden sidecar beside the project, updated about every 10 seconds for a dirty, named document. Successful manual save removes that sidecar; New/Open clears the in-memory edit history. Opening offers recovery if the sidecar exists. Current limitations include no timestamp freshness filter for externally copied/remaining sidecars, no recovery for an unnamed document, no rotating manual backups and no proven power-loss durability. The isolated GUI workflow includes process-kill/restore/save; it does not establish power-loss durability.

## Show and controls

Current UI scenes store surface snapshots only. Their transitions interpolate compatible geometry/color fields and switch incompatible/discrete state according to the engine's declared rules. They are not full project Scenes or selective parameter Cues as documented for the reference. Linear tracks for opacity, brightness, gamma and RGB are edited through the Animate panel and persisted. `TimelineEngine.apply` evaluates against monotonic media-pool transport time without accumulating state across seeks. Rendered effective surfaces overlay those track values on the base document/snapshot. A graphical timeline, non-linear interpolation, markers, montage, quantization, ICS scheduling and external synchronization belong to later stages.

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
