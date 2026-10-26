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
