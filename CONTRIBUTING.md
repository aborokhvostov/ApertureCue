# Contributing

ApertureCue is an independently authored application. Read [status](docs/status.md), [roadmap](docs/roadmap.md) and [feature matrix](docs/feature-matrix.md) before choosing work. The project accepts original contributions under `GPL-3.0-or-later`; do not contribute proprietary implementation code, vendor shaders, paid assets, secrets or somebody else's show project.

## Development

On macOS 13+, use `./scripts/build.sh` to produce `dist/ApertureCue.app`. On a healthy Swift toolchain use `swift build` and `swift test`. The local fallback `./scripts/test-core.sh` runs the same core test bodies using a small original assertion runner when SwiftPM/XCTest are unavailable; always state which path you used.

The desktop integration command is `dist/ApertureCue.app/Contents/MacOS/ApertureCue --self-test`. It needs a logged-in graphics session and writes local artifacts. Review its JSON report and images; an executable exit code is not a claim about untested devices. Linux CI targets only the portable core. Windows desktop and CI are not yet available.

## Changes and reviews

- Keep model/geometry/project/packet code independent of AppKit/Metal in `MappingCore`. Put concrete OS/device ownership in adapters.
- Define behavior and edge cases before adding a subsystem. Add meaningful deterministic tests for math/state/packets or production-render checks for visual changes; avoid tests that merely mirror an implementation.
- Document schema migrations and reject future versions safely. Preserve UUID references, relative asset paths, atomic saves and readable diagnostics.
- Keep decode/network work off UI callbacks. State queue limits, ownership and failure/reconnect behavior.
- Update the matrix with separate researched/implemented/automatic/manual/hardware evidence. A simulated receiver does not certify a lighting node.
- Include exact dependency versions/configurations and official license sources in `THIRD_PARTY_NOTICES.md` before introducing libraries or SDKs. Optional loading does not automatically solve GPL compatibility.

A pull request should describe the concrete problem, resulting user behavior, relevant checks and material limitations. Reference matrix IDs and attach original minimal reproduction files when helpful. Do not upload recordings/screenshots containing private projects or machine secrets.

## Research and bug reports

Black-box observations should state exact reference version, operating system, hardware, own inputs, one changed parameter and observed output. Distinguish documentation from observation and inference. Do not bypass activation, modify the reference installation or overwrite user projects.

For a bug report include the ApertureCue revision, OS/CPU/GPU, display layout, media codec/resolution/frame rate, number of surfaces/outputs, exact steps and a small original sample. For performance include measurement method, duration, frame-time data, drops and memory; report unavailable metrics as unavailable.

## Publishing

Review the tracked file list before pushing. Publish only the project's own sources, original/generated assets and required license material. Keep source and binary revisions aligned. Report ad hoc signing, missing notarization and CI status accurately. New major capabilities must not be represented by empty panels or marked complete until their acceptance gate passes.
