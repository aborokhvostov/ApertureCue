# ApertureCue

Independent, open source projection mapping for macOS, with a portable Swift core. ApertureCue is an early desktop application developed from its own code and assets. MadMapper 6 is a functional reference; feature equivalence has **not** been reached.

The current application contains a Metal compositor, editable perspective quad, triangle and ellipse cages with separate input and output geometry, image/video import through macOS media frameworks, transport controls, separate display outputs, project saving and undo/redo. Alpha 4 adds hierarchical affine groups and schema 3; alpha 3 remains available as the schema-2 build. Older project versions migrate on load, and older binaries reject newer schemas. Further implemented layers include polygon masks, a regular warp mesh, color controls, hierarchical group transforms/opacity/visibility, surface snapshots, linear parameter automation, a live camera adapter, local OSC/MIDI controls and basic LED strip mapping with a simulator and opt-in UDP output. OBJ import bakes a static pinhole projection into editable quad patches; it is not a depth-buffered 3D scene. Exact verification and remaining limitations are recorded in [status](docs/status.md), with an [84-function research matrix](docs/feature-matrix.md).

[Download the Apple Silicon development build (alpha 4)](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.4). It includes the original demo and is ad hoc signed, without notarization. [Archive verification and checksum](docs/verification/distribution.md).

## Build and launch

Requirements: macOS 13 or later, a Metal-capable Mac, and Xcode Command Line Tools or Xcode with Swift 5.9 or later. The native build uses only the installed Apple SDK and Swift toolchain; it downloads no application dependencies.

```sh
./scripts/build.sh
open dist/ApertureCue.app
```

The script creates an app for the current CPU architecture and applies a local ad hoc signature. It does not produce a notarized universal release.

Generate the original demonstration project, then open it:

```sh
dist/ApertureCue.app/Contents/MacOS/ApertureCue --generate-demo examples/Demo
dist/ApertureCue.app/Contents/MacOS/ApertureCue examples/Demo/Demo.aperturecue.json
```

The demo contains a generated calibration PNG, a generated H.264 MOV and two surfaces with snapshot transitions. Use **Import…** for your own image or video, **Output geometry** to move corners, **Input region** to select the source area, then **Outputs…** to choose a display. The [user guide](docs/user-guide.md) describes the controls and file format.

Use File → **Collect portable project…** to write a new folder containing `project.aperturecue.json` and copied media under UUID-based filenames. Collection runs in the background and publishes the folder only after copying and validation succeed. The open project stays in place; camera entries retain device identities rather than becoming recorded media.

On a healthy Swift Package Manager installation, the normal developer workflow is also available:

```sh
swift build -c release
swift test
.build/release/ApertureCue
```

The native build script is a fallback for the local toolchain where SwiftPM manifest linking is broken. The same core test bodies can be run through `./scripts/test-core.sh` when local XCTest is unavailable. It substitutes a small assertion runner and does not replace a genuine SwiftPM/XCTest CI run.

## Verification

```sh
./scripts/test-core.sh
dist/ApertureCue.app/Contents/MacOS/ApertureCue --self-test
dist/ApertureCue.app/Contents/MacOS/ApertureCue --protocol-loopback
dist/ApertureCue.app/Contents/MacOS/ApertureCue --lighting-test
dist/ApertureCue.app/Contents/MacOS/ApertureCue --benchmark
```

The GPU tests require a logged-in macOS graphics session. `--self-test` exercises the production Metal shader and AVFoundation path and writes `artifacts/local/self-test.json`, original test media and image results. `--protocol-loopback` checks real localhost OSC delivery and MIDI parsing. `--lighting-test` exercises production GPU composition → fixture sampling → UDP ports 6454/5568 → packet decode and writes `artifacts/local/lighting-test.json`; it does not certify physical nodes. `--benchmark` presents real visible drawables and writes `artifacts/local/live-benchmark.json`. The self-test's separate offscreen readback benchmark is not live presentation FPS.

Local core, production-render/media, OSC/MIDI and lighting loopback checks have passed during development; native bundle launch and an initial visible GUI rendering inspection have also been performed. The short benchmark uses procedural sources and does not establish video throughput or show-length stability. See the dated [status report](docs/status.md) and [stored verification reports](docs/verification) for exact revision, counts, environment, scope and outstanding manual workflow checks.

The GitHub Actions workflow defines macOS build/core-test/package jobs and a Linux Swift 6 core-test job. Its first remote result must be checked after publication. Windows desktop support and Windows CI are pending; the Linux job does not build a desktop UI. Physical projectors, multiple external displays and lighting devices have separate verification requirements.

To assemble the current Apple Silicon development distribution after building and generating the demo:

```sh
./scripts/package.sh
```

It verifies the app signature and writes `dist/ApertureCue-macOS-arm64.zip` with the app, Demo, license/notices and `START-HERE.txt`, then prints its SHA-256. This packaging path is for the current arm64 build; it does not create an Intel/universal or notarized binary. See [packaging notes](docs/packaging.md).

## Scope and next stages

The larger goal remains a complete projection/video/light/show tool. [Roadmap](docs/roadmap.md) retains Bézier editing, advanced masks and blending, a full timeline editor, fixture definitions and advanced network lighting, external video SDKs, audio routing, 3D/calibration, standalone playback and platform ports as explicit stages. Basic automation and LED output do not complete those larger subsystems; simulated devices remain distinct from hardware compatibility.

Useful documents: [architecture](docs/architecture.md), [behavior specification](docs/behavior-spec.md), [research and sources](docs/research.md), [contributing](CONTRIBUTING.md), [change log](CHANGELOG.md).

## License and provenance

Copyright (C) 2026 ApertureCue contributors. Unless a file states otherwise, the original source code, documentation and generated demonstration assets in this repository are licensed under the GNU General Public License, **version 3 or (at your option) any later version**, SPDX `GPL-3.0-or-later`. The complete canonical GPLv3 text is in [LICENSE](LICENSE). The program is provided without warranty, as described there.

[Third-party notices](THIRD_PARTY_NOTICES.md) distinguish the Swift toolchain license from macOS system frameworks. No MadMapper code, shaders, graphics, binaries or user projects are included. ApertureCue is independent and is not endorsed by MadMapper's authors.

The required Art-Net protocol credit appears in the [user guide](docs/user-guide.md#protocol-credits). OEM registration is pending; this development subset does not claim complete Art-Net 4 conformance.
