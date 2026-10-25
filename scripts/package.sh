#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_arch="$(uname -m)"
task_package="$(mktemp -d "${TMPDIR:-/tmp}/aperturecue-package.XXXXXX")"
task_release="$task_package/ApertureCue-macOS-$task_arch"
mkdir -p "$task_release"
ditto --norsrc --noextattr dist/ApertureCue.app "$task_release/ApertureCue.app"
ditto --norsrc --noextattr examples/Demo "$task_release/Demo"
cp LICENSE THIRD_PARTY_NOTICES.md "$task_release/"
cat > "$task_release/START-HERE.txt" <<'TEXT'
ApertureCue 0.1.0 development preview

macOS 13+, current build architecture is indicated in the ZIP filename.
Open ApertureCue.app, then choose File > Open
and select Demo/Demo.aperturecue.json beside this file. Press Play.

This locally ad hoc signed build is not notarized. Source and complete
build instructions: https://github.com/aborokhvostov/ApertureCue

Independent implementation; feature equivalence to MadMapper has not
been reached. External projectors, MIDI and lighting hardware have not
been certified. See docs/status.md in the source for actual tests and
limitations. Art-Net OEM registration and the current E1.31 standards
audit remain pending. The app starts no network output automatically.

GPL-3.0-or-later. No warranty. LICENSE and third-party notices included.
TEXT
xattr -cr "$task_release"
codesign --verify --deep --strict "$task_release/ApertureCue.app"
ditto -c -k --norsrc --noextattr --keepParent "$task_release" "$task_release.zip"
cp "$task_release.zip" "dist/ApertureCue-macOS-$task_arch.zip"
shasum -a 256 "dist/ApertureCue-macOS-$task_arch.zip"
