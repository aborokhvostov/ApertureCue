# Working on ApertureCue

Read `docs/status.md`, `docs/roadmap.md`, and `docs/feature-matrix.md` before continuing. The goal remains an independently implemented open source projection/video/light/show application; the existing desktop path is a foundation and does not establish MadMapper equivalence.

Keep original code/assets only. Never modify the MadMapper installation or existing user projects. Use original generated media and separate test documents. Record documentation, observations, implementation, automatic checks, manual checks and hardware checks separately. Simulator/localhost evidence is not hardware compatibility.

The current desktop target is macOS 13+, with Foundation-only `MappingCore`. `scripts/build.sh` builds an ad hoc signed app without package downloads. `scripts/test-core.sh` runs the same test bodies through a standalone assertion harness when XCTest is absent; do not report it as XCTest execution. Normal SwiftPM/XCTest CI remains independently required. Build scripts may need the installed toolchain's module cache permissions; do not modify the system toolchain.

After behavioral changes, run the relevant core tests and production integration checks. Mac graphics checks require a logged-in session; UDP localhost binding and H.264 helpers may require the environment's approved execution permission. Relevant CLI modes are documented in README. Do not add nonfunctional controls or hardware claims.

Update status/matrix with evidence and limitations before publishing. Check tracked content for secrets, personal data, foreign assets and build outputs. Follow current Art-Net notices/OEM and E1.31 scope limitations. Keep optional proprietary SDKs out of the base distribution.
