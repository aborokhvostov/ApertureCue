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
