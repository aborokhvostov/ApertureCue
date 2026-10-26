# Alpha 2 distribution verification

26 October 2026, Apple M2 / macOS 26.6.2. The `v0.1.0-alpha.2` source tag identifies this archive's production source; documentation may advance after publication.

- Archive: `ApertureCue-macOS-arm64.zip`.
- SHA-256: `2c3a00f4717af6ccbde856a2c57cb1723bc843d78df42c576235a508cfdb469c`.
- Created by `scripts/package.sh` from the locally built and tested production app.
- Extracted with `ditto` into a fresh system temporary directory. No AppleDouble, absolute or parent-traversal ZIP entries.
- Extracted app: `codesign --verify --deep --strict` passed.
- Executable from the extracted app: `--editor-test`, **11 PASS**, including real hidden fullscreen constructor/Escape, scene recall/save/undo and media import.
- Local production code also passed 29 GPU/media checks and 11 GPU-to-UDP lighting checks. Native GUI observations are recorded separately in [gui-workflow.md](gui-workflow.md).

Ad hoc signature only: no notarization, external-device certification, universal build or older macOS runtime claim. The build targets macOS 13; runtime observations above are on macOS 26.6.2. Actual CI results are linked in [status.md](../status.md).

## Alpha 3 candidate

26 October 2026, same Apple M2 / macOS 26.6.2 environment. Production source adds triangle/ellipse cages and project schema 2; the release tag will identify the corresponding source revision after successful CI.

- Archive `ApertureCue-macOS-arm64.zip`, SHA-256 `62d6e4b156009f12422e2c30b7793e78a4998c8f6fa2d2fb28fb53237ff9c129`.
- Includes original procedural `Demo/Shapes.aperturecue.json` beside the existing PNG/H.264 demo. Production ProjectStore loaded/validated the Shapes project and generated its projected contours.
- Fresh extraction passed ZIP entry checks (no AppleDouble/absolute/traversal entries) and `codesign --verify --deep --strict`.
- Executable from this extracted app passed all **13 editor integration checks**, including the working inspector shape control, source preview, geometric picking, scene persistence and schema-2 save/new/open.
- Local core: 43 assertion methods; production GPU/media: 35 checks; complete lighting pipeline: 11 checks. GUI observations: [shape-workflow.md](shape-workflow.md).

Same signing/runtime/hardware limitations as above. Alpha 1/2 reject schema-2 projects; retain a separate old project copy if returning to those binaries.
