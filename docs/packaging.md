# Development distribution

The current release package targets the tested Apple Silicon macOS build. It is an ad hoc signed development preview, not a universal or notarized installer. Exact verification and publication links belong in [status.md](status.md); the presence of a packaging script does not prove a release upload.

## Build and package

From the repository root on the current arm64 Mac:

```sh
./scripts/build.sh
dist/ApertureCue.app/Contents/MacOS/ApertureCue --generate-demo examples/Demo
./scripts/package.sh
```

The build script compiles the executable and original `MappingCore` library, stages the bundle in a fresh system temporary folder, copies license/notices, clears extended attributes and signs it locally before moving it into `dist`. The previous app is retained under the ignored native build folder so rebuilding does not truncate files mapped by a running process. The package script expects the app and demo to exist; it does not rebuild or rerun tests.

`package.sh` creates this layout and archives it as `dist/ApertureCue-macOS-arm64.zip`:

```text
ApertureCue-macOS-arm64/
  ApertureCue.app/
  Demo/
    Demo.aperturecue.json
    calibration.png
    motion.mov
  LICENSE
  THIRD_PARTY_NOTICES.md
  START-HERE.txt
```

It verifies the app with `codesign --verify --deep --strict`, uses `ditto` to preserve the bundle/executable layout without extended attributes/AppleDouble entries and prints the ZIP's SHA-256. Packaging uses a fresh system temporary folder so a File Provider managing the source folder cannot add Finder metadata to the signed app before archiving. The script uses the host CPU architecture in the package name; the published package is arm64, and an Intel package still needs separate testing.

`START-HERE.txt` explains opening the included demo, the GPL license, signing status and current hardware/protocol limits. The demo assets are generated from original project code. No MadMapper resources, SDKs, system frameworks or foreign projects are included.

## Source and binary correspondence

Publish the binary with the matching source commit/tag and its checksum, together with build instructions, license/notices and the dated verification report. Review the tracked file list before publishing. A GitHub Actions app-only artifact and the distribution above have different content: the latter adds Demo and first-run material.

Local reports, compiler caches, personal test projects and raw research downloads are excluded from the source repository. Selected sanitized verification reports may be committed under `docs/verification`; their scope must remain attached. CI and GitHub upload success must be verified against the actual published revision before being reported as complete.
