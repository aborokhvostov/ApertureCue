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

## Alpha 8

27 October 2026, Apple M2 / arm64 / macOS 26.6.2. Recorded inspector automation on armed scalar tracks, ordinary schema-6 keys. The `v0.1.0-alpha.8` tag identifies `c0ef2825c65d864603d5a37583c3a2753834cf73`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40563089950) passed 82 XCTest on macOS and 82 on Linux, zero failures, plus macOS SwiftPM release/native bundle/signature/archive/artifact.

- Archive `ApertureCue-macOS-arm64.zip`, 1,177,703 bytes; SHA-256 `e13c43c0c4bc76152e0a15b052198e1531479a6b81ef60c7de13a94715d8f901`.
- Includes original `Demo/Recording.aperturecue.json`: PNG/H.264 surfaces, three existing scalar tracks and120-second recording-practice horizon, previous original demos, license and notices.
- Fresh extraction passed ZIP CRC/entry validation and `codesign --verify --deep --strict`.
- Executable directly from the extracted archive passed **46 production editor checks**, including live native input callbacks, Metal/light preview, one-gesture history, recovery before commit, release budget failure, interruption/token handling and actual H.264 seek-generation preservation through record/Undo/Redo and no-op refresh.
- Final optimized production binary passed **46 GPU/media** and **11 lighting/UDP** checks. Portable core passed **82 standalone methods**, zero failed assertions; remote XCTest passed independently as linked above. [Native recording GUI workflow](recording-workflow.md) passed.
- Recording workloads: the native practice uses2 media surfaces,3 tracks and0 output windows; original H.264 is640x360/30fps/3s looped, PNG960x540. The GUI show clock traversed120s; this is a functional workflow, not a long-run stability measure. Active automatic recording pixel checks use1 solid surface and32x18 snapshots, plus production320x180 light sampling. Core/editor fake-host intervals are deterministic rather than wall-time playback. Full-suite wall time, new throughput/drift/latency and external-display behavior were not instrumented.

Ad hoc arm64 only, not notarized/universal; macOS 13 target, runtime observed on macOS 26.6.2. No new throughput, long-show, optical FPS, decoder frame-lock or hardware conformance claim. Recording affects existing enabled/current-surface scalar tracks from inspector input; no timer, automatic provider, audio/MIDI/OSC or montage capture. Outside keys persist, but adjacent evaluated segments may change. Keys remain schema 6 and readable by alpha 7; arming is session-only.

CI maintenance for alpha8: the queued macOS 14 run was superseded after verifying the official [runner retirement notice](https://github.com/actions/runner-images/issues/13518). The workflow now pins macOS 15; production source, tests, build scripts and generated demo are unchanged from the locally verified recording commit. This does not claim runtime testing on macOS 13/14 hardware.

[Alpha 8 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.8) is a prerelease. ZIP and SHA256SUMS were confirmed `uploaded`; both server digests match local files. ZIP size matches the value above, and the tag resolves to the exact source above. Previous releases remain available.

Alpha 8 core-suite timing from actual CI logs: Linux 4.712 s and macOS 15 6.180 s reported wall time, 82 tests/zero failures each. These are test-suite durations, not presentation/decode throughput or desktop soak measurements.

## Alpha 9

28 October 2026, Apple M2 / arm64 / macOS 26.6.2 / 8 GiB. Adds assignable image/video source montage, native clip editing and schema 7. The `v0.1.0-alpha.9` tag identifies production source `63a8847315605f3456a2b55693f5bfb52889395e`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/40731651961) passed **91 actual XCTest on macOS and 91 on Linux**, zero failures, plus macOS SwiftPM release/native bundle/signature/archive/artifact. Reported suite durations: Linux 4.985 s; macOS 6.171 s. Final verification/publication documentation follows separately without changing production source.

- Archive `ApertureCue-macOS-arm64.zip`, **1,394,511 bytes**; SHA-256 `b5a1a7518da28b904b0884ef27eb14628798c7f64b985902e1f79d46e63e21d3`.
- Includes original `Demo/Montage.aperturecue.json`: two montage sources, six image/video clips, independent trims/rates, Black/Skip gaps, trim loop and a 10-second master loop. Existing own demos, PNG/H.264, GPL license and notices remain included.
- Fresh ZIP passed CRC and validation of all 27 entries: no absolute/traversal/AppleDouble paths; executable mode retained; extracted app passed `codesign --verify --deep --strict`.
- The executable directly from this extraction passed **51 editor** and **27 montage reader/Metal** checks. The final optimized production app also passed **46 GPU/media** and **11 lighting/localhost UDP** checks; portable core passed **91 standalone methods**, zero failed assertions. Local standalone execution is separate from actual CI XCTest.
- [Native montage workflow](montage-workflow.md) passed create image/video clips, trim/rate, assign, seek/play/pause, Undo/Redo, Save and genuine quit/relaunch/reopen. Earlier failed attempts, memory pressure and a UI-tool launch blocking about 55 minutes despite a 30-second timeout are recorded there; they are not soak/performance evidence.
- Generated montage fixtures are H.264 160×96 at 30/1/2 fps and variable sample intervals, including rotation/initial empty edit; rendering readbacks are 128×96. The original GUI demo uses PNG 960×540 and H.264 640×360/30 fps/3 s on two surfaces and no external output window. Accepted reader PTS coverage, generation continuity and explicit late-frame bounds are tested; drift, sustained playback/throughput and optical FPS are unmeasured.
- Source/doc and actual archive audits found no scanned credentials/private keys/personal paths. Binary demo assets are the original generated calibration PNG and motion MOV. Packaging staged without resource forks/extended attributes in a user temporary directory; a sandbox copy denial required the approved execution permission. File Provider metadata on the workspace app was cleared before re-verifying its signature.

Ad hoc arm64 only, not notarized/universal. macOS 13 target; runtime observed on macOS 26.6.2. Montage videos are silent; directly assigned ordinary sources retain independent transport/volume and may play audio even when their layer is hidden. Eight montage video readers are admitted in UUID order, with an explicit gap/diagnostic for excess sources. No reverse, crossfade/overlap, audio montage, nested source or clip recording is provided. External projector/camera/MIDI/light hardware and full reference parity remain open. Alpha 1...8 reject schema 7; keep a separate copy for downgrade.

## Alpha 10 candidate

14 November 2026 on Apple M2 / arm64 / macOS 26.6.2. The candidate adds surface geometry locks and saves schema 8. Versions 0–7 load with unlocked geometry. Saving a project in this build requires schema 8 support to reopen it. Builds target macOS 13+ and use ad hoc signing.

- Local standalone harness passed 92 core methods. Native checks passed 53 editor, 27 montage, 46 GPU/media, 11 light/UDP and local OSC/MIDI parser checks. These runs cover generated media including H.264 MOV and production window/controller paths. The lock run uses two procedural surfaces and zero external outputs in the visible editor. It verifies that an attempted drag at the old upper-left handle leaves the geometry in place, then repeats the drag successfully after unlocking. The built-in demo changes were discarded.
- The final ZIP contains the signed executable and library, eight original demo documents, their PNG/MOV, license and notices. An initial archive inspection found a recovery sidecar beside the demo. Packaging now selects the named original demos and media explicitly. The rebuilt archive has 27 entries and 1,424,963 bytes. ZIP integrity, demo byte comparison and strict app signature passed after fresh extraction. SHA-256 `8c353b4402c97c92cf4df2d8e2adb6a2c1664eeacc58c7fdd6d34b5bc9f5eabc`.
- The extracted executable passed all 53 editor and 27 montage checks from the documented repository working directory. An earlier editor run from under macOS's `/var` temporary-directory alias failed the harness's strict asset-path equality after Save. The extracted executable passed when started from the repository without changing the archive.

No new sustained throughput, external display, audible output, or lighting hardware measurements were made for this candidate.

Published as [alpha 10](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.10). The tag resolves to `2562a854eca6d5e59f352effbb8a1776e6ad4406`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/43585769766) passed 92 actual XCTest on each platform, with zero failures. The reported suite durations were 6.196 s on macOS and 2.891 s on Linux. The macOS SwiftPM release and native package/archive/artifact steps passed. The release ZIP hash matches the fresh extraction above. GitHub reports `SHA256SUMS` as 94 bytes with SHA-256 `94d52511aa14acce98ebdabcf637015d6c54c78da2cb278bcbb914c4949875b7`. Both assets are uploaded.

## Alpha 11

15 November 2026 on Apple M2 / arm64 / macOS 26.6.2. Three editable triangle vertices live inside the projective cage. Schema 9 stores them in the surface and the Shape cue field. Older projects open with their original triangle outline. The build targets macOS 13+ on Apple Silicon and uses ad hoc signing.

- Local standalone harness passed 94 core methods. The native editor passed 54 checks including editing on a mirrored group and displaced mesh, keeping the last valid drag point, geometry locking, save and reopen. The Metal/media suite passed 47 checks including pixels and UV on asymmetric triangles in perspective and mirrored mesh frames, with sampled colors at 128×96. The 11 lighting checks use local UDP. Media regressions use original generated H.264 MOV.
- The visible editor run used two built-in procedural layers and one new triangle, with zero external outputs. It confirmed three handles, a single moving vertex inside the unchanged cage, Undo, Redo and Reset. The demo modifications were discarded. Physical displays and sustained throughput were outside this test scope.
- The arm64 ZIP has 27 entries and 1,441,570 bytes. CRC, original demo byte comparison, executable and library byte comparison, and strict app signature passed after fresh extraction. SHA-256 `faae663757f858fb533c6da9902088c1f53aacc78e73b732ea977443d4f8dcf7`.
- The extracted executable passed all 54 editor and 47 Metal/media checks.

Published as [alpha 11](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.11) from `70849fbcf2c6b389346ff19edc10d40d9c602cf9`. The [CI run](https://github.com/aborokhvostov/ApertureCue/actions/runs/43698976241) passed 94 XCTest on each platform with zero failures. The suites reported 5.500 s on macOS and 4.522 s on Linux. macOS release build, app, archive and artifact passed. GitHub's ZIP digest and size match the verified archive. The uploaded SHA256SUMS has 94 bytes and SHA-256 `6eaa77175e6ff952b082ac045ce52e773fc99bfbc396841ead4c03803b3d727b`.

## Alpha 12

15 November 2026 on Apple M2 / arm64 / macOS 26.6.2. Schema 10 adds fullscreen display assignment by UUID. Preview and fullscreen can coexist for one logical output. Disconnect, mirrored mode and ambiguous identifiers close the applicable fullscreen window on screen configuration change. Reconnect requires an explicit reopen.

- The arm64 ZIP has 27 entries and 1,477,495 bytes. CRC, original demo byte comparison, executable and library byte comparison, and strict app signature passed after fresh extraction. SHA-256 `585816f7d39ac96e010af9efbe3cbec093d3f298a1f534e34c1f002e220b7b6a`. The archive targets macOS 13+ and uses ad hoc signing. File Provider attached metadata to the work directory's copy. The packaged app and freshly extracted app passed strict signature validation.
- The local standalone harness passed 95 core methods. The extracted app passed 56 editor and 47 Metal/media checks, including original generated H.264 MOV media. On one logged-in display, two hidden native previews showed red and green routed layers at 32×18. The three-window fixture included two previews and one hidden fullscreen. Injected display reorder, disconnect, mirroring, duplicate identities and Undo/Redo exercised the production reconciliation method without changing physical topology.
- In the visible editor, the two-surface procedural demo opened one standalone preview without a display assigned, then opened fullscreen on the built-in Retina display. Escape closed each window, and reopening Outputs selected the assigned display. Changes to the built-in demo were discarded.
- Physical hotplug, projector output and extended runtime remain outside this release's evidence.

Published as [alpha 12](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.12) from `d58ff0052299bd68d1c342b5712adde6f548bc22`. [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/43714450518) passed 95 XCTest on each platform with zero failures. The suites reported 5.399 s on macOS and 4.094 s on Linux. The macOS release build, native app, archive and artifact passed. GitHub's ZIP digest and size match the verified archive. The uploaded SHA256SUMS has 94 bytes and SHA-256 `22eb162a057a794140efd85ea33d3273bd863bb4ceb7c20d0d68d4e2b3664107`.

[Alpha 9 release](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.9) is a prerelease. ZIP and SHA256SUMS were confirmed uploaded; both server SHA-256 digests and ZIP size match local evidence, and the tag resolves to the exact source above. Previous releases remain available.

## Alpha 13

19 November 2026, Apple M2 / arm64 / macOS 26.6.2, macOS 13+ target. Schema 11 adds source/output-canvas layer polygon masks, inversion and independent feather. See [specification](../polygon-mask-spec.md). Older binaries reject schema 11; use Save As to retain an older project copy.

Local standalone core: 98 methods, zero failed assertions; separate from XCTest. Production native editor: 58 checks. Metal/media: 50 checks, including numerical mask oracle at 128×96 with crop, displaced mesh and mirrored group; generated H.264 MOV tests retained. Lighting/UDP localhost: 11 checks. Hidden routing fixtures still use two previews and one fullscreen on one available display. These short suites do not establish throughput, physical hotplug, external projectors, real light fixtures, drift or show-length stability.

Manual GUI: the built-in two-surface procedural demo showed Source UV coordinates / Input region, then Output canvas coordinates / Output geometry, inversion and feather 0.120. Undo restored 0.000 and Redo restored 0.120. Screenshot showed an inverted feathered checker layer while its adjacent gradient remained intact. This test did not manually save/relaunch; production hidden integration and core check persistence separately. The test demo was discarded on quit.

Published on 26 November as [alpha 13](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.13) from `0de08d920a1f3f91b052e19bd6e9de2c1b63aaa1`. [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/44594000550) passed 98 actual XCTest per platform, zero failures: macOS 6.124 s and Linux 3.005 s. The macOS release build, native bundle, archive and artifact completed successfully. The earlier network block is resolved.

The published ZIP has 27 entries, 1,501,097 bytes and SHA-256 `07458895ac0a1e8b82cac0765f665b91463e9f0127e73bc4f339f2de4e46c739`. The checksum manifest has 94 bytes and SHA-256 `49232118d98bbe4bdd895ceeb4ff698fe522fc16dcb2fa107cc5fc5f6563da90`. Both assets are uploaded and GitHub's digests match the local files. Fresh extraction, strict ad hoc signature, original demo and built binary comparison passed; the extracted app passed 58 editor and 50 Metal/media checks. Physical hardware and notarization remain unverified.

## Alpha 14

26 November 2026 on Apple M2 / arm64 / macOS 26.6.2, using Apple Swift 6.4.2 from Xcode and a macOS 13+ target. Numeric polygon vertex editing, midpoint insertion on closed edges and removal use the existing schema 11; alpha 13 readers retain these polygons. Geometry locks and one-command history apply.

Local standalone core passed 100 methods with zero failed assertions. Production hidden editor passed 60 checks, including closing-edge insertion, numeric edits, minimum-bound/NaN rejection, preserved UV/mesh/group/mask settings, Undo/Redo, locks and save/reopen. Local standalone assertions are separate from actual remote XCTest. The extracted app passed 51 Metal/media checks, including numerical 128-point fill and pixel equality before/after closing-edge insertion. Visible GUI verified Insert after (4→5), Save vertex (x=0.25 retained on reopening), Remove vertex, Undo/Redo (4→5→4), and disabled Remove vertex at three points. The built-in procedural demo was discarded on quit. No manual save/relaunch claim is made; persistence was checked by production editor integration. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45833970500) identifies `b2b2b73ede2ecff5c0a902c7382452a6bac518a7`. Linux passed 100 actual XCTest with zero failures in 4.249 s; macOS passed 100 in 6.816 s. macOS SwiftPM release, native bundle, archive and artifact all passed. The first macOS job was cancelled after 15 minutes without a runner or steps; GitHub annotations identified hosted macOS arm64 capacity constraints. Retrying failed jobs succeeded.

The ZIP has 27 entries and 1,467,169 bytes, SHA-256 `6fb29ac9ca223ba947a221604d9c33bb909c7507f4934a4afc992dd95590c1ba`. Fresh extraction passed strict ad hoc signature, CRC, executable modes and byte equality with both built binaries and the original ten demo documents/media. No new media/SDK dependencies are included. Notarization, physical projectors/hotplug/fixtures, long-show timing and mask throughput remain unverified.

Published as [alpha 14](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.14) on 26 November. Both uploaded assets match local sizes/digests. SHA256SUMS has 94 bytes and digest `4605ba61c4130ce29be6e7ca856f03cc761f47da0471ba6d0e76de3f59464ca4`. The source tag resolves to the exact verified commit above. Local suite wall duration, optical presentation, multi-output throughput, audio drift and soak stability were not measured.

## Alpha 15

26 November 2026, Apple M2 / arm64 / macOS 26.6.2 build 25G83, 8 GiB,
Apple Swift 6.4.2 / installed Xcode SDK. macOS 13+ target; actual local runtime
coverage is macOS 26.6.2. Stage 2 geometry/composition is the declared subset in
[the ledger](../stage-2-completion.md); this is not full reference parity.
Schema 12 adds the new geometry/composition fields and fifteen selective surface
fields. Earlier binaries reject schema 12; keep a separate copy for downgrade.

Local standalone core passed 133 methods with zero failed assertions, separately
from actual remote XCTest. The optimized native app passed 81 editor, 25
composition, 51 GPU/media, 27 montage, 11 lighting/UDP, 5 live presentation,
3 full-editor live checks and OSC/MIDI localhost loopback. The fresh extracted
app repeated 81 editor, 25 composition, 5 live presentation and 3 full-editor
live checks. [Sanitized reports and wall durations](stage-2/distribution.json).
Original generated H.264 fixtures remain in the media regressions. The live
renderer test shows five procedural layers at 1920×1080 for six seconds; actual
EditorController uses its ordinary auto-sized view. These are short behavior
checks, not optical refresh, sustained throughput or long-show measurements.

The final ZIP has **34 entries, 1,960,870 bytes**, SHA-256
`3ee1279efe8f98093ed5dfb858a1c3f11c790a828a4fb445fc749439093eff91`.
CRC, safe archive paths, executable modes, strict ad hoc signature and exact
executable/library/Info/demo/example bytes after fresh extraction all passed.
The archive includes nine original demo documents and PNG/H.264 media, two
original ISF examples, an original SVG, GPL license and notices. Recovery
sidecars, working copies, optional proprietary SDKs and build caches are excluded.
Arm64 only; ad hoc signed, not notarized or universal.

[Manual journal](composition-workflow.md#manual-checks), on the first accepted
extracted candidate before the compiler-only matrix rewrite: separate original demo
copies, visible Composition, output Bézier numeric edit and Undo/Redo, FX and
material override edit, Save/Quit/relaunch/reopen, Play/Pause. The repository's
original demo files and existing recovery snapshot were preserved. No physical
projector, display hotplug, optical seam, audio drift, camera, MIDI device or
lighting fixture verification is implied. Published as [alpha 15](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.15)
from `031045777b413bb6034bf6e11d34ca883e27ce37`. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45881995353)
passed 133 actual XCTest per platform, zero failures: macOS Swift 6.1.2 suite
14.436 s and Linux Swift 6.0.3 suite 6.824 s. macOS SwiftPM release/native app,
archive and artifact passed. The first failed CI exposed the compact-expression
type-check limit; the explicit matrix loop resolved it. The final local executable
and core library are byte-identical to the manually exercised candidate.

GitHub confirms the exact tag and both assets uploaded. ZIP size/digest match
the fresh archive above; SHA256SUMS is 94 bytes with SHA-256
`e429216310f6e51960058585d69173a3c7965bac85f5bd6058d02cf12439b05b`.
[Machine-readable CI](stage-2/ci.json), [release](stage-2/release.json).


## Alpha 16

Published 27 November 2026 Europe/Moscow (26 November 21:10:27 UTC),
[prerelease alpha 16](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.16)
uses source `a35963a12589223701fcfec6ef88ffb502d5a5a7`.
[Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45895275823)
passed 154 actual XCTest on each macOS/Linux and macOS release/native/archive/artifact.

The Apple M2 / arm64 / macOS 26.6.2 / Swift 6.4.2 local app targets macOS 13+,
uses ad hoc signing and is not notarized. ZIP: **2,256,895 bytes / 43 entries**,
SHA-256 `a17291c23df787fca255c8314c9a4042c097cbbd3656e4c2f96c5bf702d893a0`.
The 94-byte SHA256SUMS file hashes to
`7788cefad922d447896d55e7dbdc16c218cd1f802e7697b65148b56461ff773b`.
Both uploaded assets have matching server-side digests/sizes and uploaded state;
the release is prerelease, not draft, and its tag points to the tested source.

CRC, safe unique paths, executable mode, strict signature and app/demo/example
byte equality pass after fresh extraction. The final extracted app passes
Sources 9, media 13, offline audio 15, durability 5, GPU/media 51, montage 27,
composition 25 and live-editor 3. The same binary completed the scoped visible
Save/Quit/relaunch/Open workflow and the full production 13-mode suite including
90 editor checks and the 120-second four-source soak. The earlier archive that
exposed the long help-label width was superseded and never released.

[Build/distribution identity](stage-3/distribution.json), [release metadata](stage-3/release.json),
[native journal](media-workflow.md) and [stage ledger](../stage-3-completion.md)
record source, fixture resolution/codec/count/duration and limitations separately.
The original Media demo includes four PNG frames, H.264 MOV and an unassigned
volume-zero stereo WAV. No hardware camera/audio/projector compatibility,
audible sync, optical refresh, long-show, 4K/60 or reference-equivalence claim.
