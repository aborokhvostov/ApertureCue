# Distribution verification

## Alpha 2

26 October 2026, Apple M2 / macOS 26.6.2. The `v0.1.0-alpha.2` source tag identifies this archive's production source; documentation may advance after publication.

- Archive: `ApertureCue-macOS-arm64.zip`.
- SHA-256: `2c3a00f4717af6ccbde856a2c57cb1723bc843d78df42c576235a508cfdb469c`.
- Created by `scripts/package.sh` from the locally built and tested production app.
- Extracted with `ditto` into a fresh system temporary directory. No AppleDouble, absolute or parent-traversal ZIP entries.
- Extracted app: `codesign --verify --deep --strict` passed.
- Executable from the extracted app: `--editor-test`, **11 PASS**, including real hidden fullscreen constructor/Escape, scene recall/save/undo and media import.
- Local production code also passed 29 GPU/media checks and 11 GPU-to-UDP lighting checks. Native GUI observations are recorded separately in [gui-workflow.md](gui-workflow.md).

Ad hoc signature only: no notarization, external-device certification, universal build or older macOS runtime claim. The build targets macOS 13; runtime observations above are on macOS 26.6.2. Actual CI results are linked in [status.md](../status.md).

## Alpha 3

26 October 2026, same Apple M2 / macOS 26.6.2 environment. Production source adds triangle/ellipse cages and project schema 2; the `v0.1.0-alpha.3` source tag identifies `3bcab64e50c5d362d57d144f41498cdd44b6c26d`. [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40330574327) passed macOS/Linux 43 XCTest each and macOS release build/native bundle/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, SHA-256 `62d6e4b156009f12422e2c30b7793e78a4998c8f6fa2d2fb28fb53237ff9c129`.
- Includes original procedural `Demo/Shapes.aperturecue.json` beside the existing PNG/H.264 demo. Production ProjectStore loaded/validated the Shapes project and generated its projected contours.
- Fresh extraction passed ZIP entry checks (no AppleDouble/absolute/traversal entries) and `codesign --verify --deep --strict`.
- Executable from this extracted app passed all **13 editor integration checks**, including the working inspector shape control, source preview, geometric picking, scene persistence and schema-2 save/new/open.
- Local core: 43 assertion methods; production GPU/media: 35 checks; complete lighting pipeline: 11 checks. GUI observations: [shape-workflow.md](shape-workflow.md).

Same signing/runtime/hardware limitations as above. Alpha 1/2 reject schema-2 projects; retain a separate old project copy if returning to those binaries.

[Alpha 3 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.3) assets were confirmed `uploaded` through GitHub API; server ZIP digest matched the SHA-256 above. Alpha 1/2 archives and tags remain available independently.

## Alpha 4

27 October 2026, Apple M2 / macOS 26.6.2. Production source adds UUID affine group hierarchy, schema 3 and vector editor overlay. The `v0.1.0-alpha.4` tag identifies source `aa3cde6666a6794d461e23bce2a291e642cccb25`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40415540170) passed 50 XCTest on macOS and 50 XCTest on Linux, plus macOS SwiftPM release build/native bundle/signature/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, SHA-256 `59a986c33959b2cf045a426c4f7adf905a3cd46b6c444b50da393474884e7286`.
- Fresh package includes the original `Demo/Groups.aperturecue.json`, previous shape/media demos, license and notices. No third-party application assets or SDKs are included.
- Fresh extraction passed entry validation (no absolute/traversal/AppleDouble entries) and `codesign --verify --deep --strict`.
- The executable directly from this extracted archive passed **20 production editor checks**, including asymmetric vector cage coordinates, exact Dissolve/Undo/Redo checker pixels, group output/lighting composition and schema-3 save/new/open.
- Local core: **50 methods, 0 failed assertions** through the standalone harness. Production GPU/media: **39 checks**; GPU-to-localhost-UDP lighting: **11 checks**. Native GUI regression is recorded in [group-workflow.md](group-workflow.md).

Same signing/runtime/hardware limitations as earlier archives. Group opacity is inherited per layer, not an isolated group buffer. Group setup is shared project state outside surface-only scenes. Group perspective/FX/automation remain open. Alpha 1/2/3 reject schema-3 projects; retain a separate older document if returning to them.

[Alpha 4 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.4) is a prerelease with both ZIP (842,915 bytes) and SHA256SUMS assets confirmed `uploaded`. GitHub reported the same ZIP SHA-256 as above; its tag resolves to the source revision above. Earlier releases remain available.

## Alpha 5

27 October 2026, Apple M2 / arm64 / macOS 26.6.2. Adds textured polyline/cubic stroke surfaces and schema 4. The `v0.1.0-alpha.5` tag identifies source `3677a3b98ed3525c03d434ed902f1077e2b560a9`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40422000377) passed 57 XCTest on macOS and 57 on Linux, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, 908,240 bytes, SHA-256 `736863d32709c9ca26f9822e8037cb34a7c308eec99fb73346037c0080cef623`.
- Fresh package contains the original `Demo/Strokes.aperturecue.json` with two path surfaces and compatible curve scenes, previous demos, license and notices.
- ZIP validation rejected absolute/traversal/AppleDouble entries; the fresh extraction passed `codesign --verify --deep --strict`.
- Executable directly from the extracted archive passed **23 production editor checks**, including invalid shape conversion rejection, cubic split/remove/history, inverse group+mesh tangent editing, visible stroke pixels and schema-4 scene/save/new/open.
- Final optimized production binary also passed **46 GPU/media** and **11 lighting/UDP** checks. Local portable core passed **57 assertion methods** with zero failures through the standalone harness. [Native GUI path workflow](stroke-workflow.md) passed separately.

Ad hoc signing only, not notarized or universal; macOS 13+ target, runtime tested on macOS 26.6.2. No new stroke throughput/4K/soak or hardware compatibility claim. Local-width/cage clipping, round joins/caps, accepted nearest-segment UV seams and bounded local cubic tolerance are specified in the user guide. Freehand drawing, alternate join/cap modes, filled FreeDraw and Bezier mesh/masks remain open. Alpha 1–4 reject schema 4; retain an older project copy when downgrading.

[Alpha 5 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.5) is a prerelease. Both ZIP and SHA256SUMS assets were confirmed `uploaded`; GitHub ZIP size/digest match the values above. The release tag resolves to the exact source above. Earlier release assets/tags remain available.

## Alpha 6

27 October 2026, Apple M2 / arm64 / macOS 26.6.2. Adds graphical scalar timeline and independent show runtime, schema 5. The `v0.1.0-alpha.6` tag identifies source `99ea8de94ff26b88622a2d5492acd3ec000580f7`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40501836787) passed 65 XCTest on macOS and 65 on Linux, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, 1,015,096 bytes; SHA-256 `2c1378ebf3347234e86e85b15f5d525f6203ccabb5222495eaedb62fea4389e7`.
- Includes original `Demo/Timeline.aperturecue.json`: three scalar tracks, Hold/Linear/Bezier, pause/scene markers, explicit finite duration; previous original demos/license/notices retained.
- Fresh ZIP extraction passed entry validation (no absolute/traversal/AppleDouble entries) and `codesign --verify --deep --strict`.
- Executable directly from this extracted ZIP passed **29 production editor checks**, including master sampling shared by editor/output/light, graph callbacks/history/layout, markers/loop, legacy continuation and schema-5 save/new/open.
- Final optimized production app passed **46 GPU/media** and **11 lighting/UDP** checks. Portable core passed **65 standalone methods**, zero failed assertions; actual XCTest CI is separate. Native GUI verification: [timeline-workflow.md](timeline-workflow.md).

Same signing/runtime/hardware limitations as earlier releases: ad hoc arm64, not notarized/universal, macOS 13 target but runtime tested on macOS 26.6.2. Six scalar parameter lanes are implemented; clip/audio/MIDI/OSC montage, recording, Auto Curve, marker jump chains, external clock and Conductor banks remain open. Marker/UI sampling is timer-driven, not physical latency/frame-lock certification. Legacy v0-v4 migrate to continuing transport; new shows stop at Duration by default. Alpha 1-5 reject schema 5; keep an older project copy for downgrade.

[Alpha 6 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.6) is a prerelease. ZIP and SHA256SUMS assets were confirmed `uploaded`; server ZIP size/SHA-256 match the values above, and its tag resolves to the exact source above. Earlier releases remain available independently.

## Alpha 7

27 October 2026, Apple M2 / arm64 / macOS 26.6.2. Selective surface cues, native Scenes editor and schema 6. The `v0.1.0-alpha.7` tag identifies `64e2dfa309849e6b49e08402353a9962769783ca`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40509423121) passed 74 XCTest on macOS and 74 on Linux, zero failures, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, 1,110,016 bytes; SHA-256 `c78bf200fe65ec6d52b9661f023618316ceab02795eec06ab2fcf405b51c6392`.
- Includes original `Demo/SelectiveCues.aperturecue.json`: four full/selective scenes and one independent brightness track, previous generated demos, license and notices.
- Fresh extraction passed ZIP CRC/entry checks (no absolute/traversal/AppleDouble entries) and `codesign --verify --deep --strict`.
- The executable from the extracted archive passed **36 production editor checks**, including actual checkbox/capture/save/recapture/GO callbacks, layout width, missing-only no-op, full-owner orphan cleanup, and selective recall during a running generated H.264 decode.
- Final optimized production app passed **46 GPU/media** and **11 lighting/UDP** checks. Portable core passed **74 standalone methods**, zero failed assertions. Actual remote XCTest is separate from this local harness and passed as linked above. [Native selective GUI workflow](selective-workflow.md) passed.

Ad hoc arm64 signing only; not notarized/universal. macOS 13 target, runtime observed on macOS 26.6.2. No new throughput/frame-lock/long-show or physical hardware claim. Full snapshots remain surface-only; group definitions are shared, timeline can override recalled base parameters, and source-excluding cues keep current clocks. Recorded automation/montage/external clocks remain open. Alpha 1...6 reject schema 6; keep an older copy when downgrading.

[Alpha 7 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.7) is a prerelease. ZIP and SHA256SUMS were confirmed `uploaded`; GitHub ZIP size/SHA-256 match the local values above. The release tag resolves to the exact source above. Previous releases remain available.
