#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_arch="$(uname -m)"
task_package="$(mktemp -d "${TMPDIR:-/tmp}/aperturecue-package.XXXXXX")"
task_release="$task_package/ApertureCue-macOS-$task_arch"
mkdir -p "$task_release"
ditto --norsrc --noextattr dist/ApertureCue.app "$task_release/ApertureCue.app"
mkdir -p "$task_release/Demo"
# Ship only the original demos and their media. Working copies and recovery
# sidecars can exist beside them after running the editor.
for task_demo in Demo Composition ControlMapping Groups LightEngine Montage Recording SelectiveCues Shapes ShowControl Strokes Timeline; do
  cp "examples/Demo/$task_demo.aperturecue.json" "$task_release/Demo/"
done
cp examples/Demo/calibration.png examples/Demo/motion.mov "$task_release/Demo/"
mkdir -p "$task_release/Examples/Materials" "$task_release/Examples/SVG"
cp examples/Materials/OriginalGradient.fs examples/Materials/OriginalTint.fs "$task_release/Examples/Materials/"
cp examples/SVG/geometry.svg "$task_release/Examples/SVG/"
mkdir -p "$task_release/Media/Frames"
cp examples/Media/Media.aperturecue.json examples/Media/original-time-colors.mov examples/Media/original-stereo-tones.wav "$task_release/Media/"
for task_frame in frame1 frame2 frame10 frame11; do
  cp "examples/Media/Frames/$task_frame.png" "$task_release/Media/Frames/"
done
cp LICENSE THIRD_PARTY_NOTICES.md "$task_release/"
cat > "$task_release/START-HERE.txt" <<'TEXT'
ApertureCue 0.1.0 development preview

macOS 13+, current build architecture is indicated in the ZIP filename.
Open ApertureCue.app, then choose File > Open
and select Demo/Demo.aperturecue.json beside this file. Press Play.
Demo/Composition.aperturecue.json demonstrates procedural materials, Bezier
warps, scoped masks and isolated groups without external media or hardware.
Original import examples are in Examples/Materials and Examples/SVG.
Demo/ShowControl.aperturecue.json contains a procedural show. Use Show >
Conductor to launch its two rows independently. Timeline contains a bounded Jump
and a Pause marker. Schedule and OSC/MIDI dispatch are session controls.
Demo/ControlMapping.aperturecue.json shows saved OSC and MIDI assignments.
Open Show > Control mappings to start a session service and inspect addresses.
Demo/LightEngine.aperturecue.json has a routed RGBW matrix and a virtual
moving light. Open Light > Fixture patch and Light > DMX monitor, then press Play.
Media/Media.aperturecue.json demonstrates frozen image sequences, independent
source transport and reverse ping-pong. Open Sources in the Media library.
Its original stereo tone asset is unassigned and volume 0. Assign it to a
surface and choose the intended volume/route when you want audio.

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
