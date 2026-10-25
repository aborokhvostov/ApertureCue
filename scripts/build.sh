#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Desktop build requires macOS. Use swift test for the portable core.' >&2
  exit 1
fi
task_build="$PWD/.build/native"
task_package="$task_build/package-$(uuidgen)"
task_app="$task_package/ApertureCue.app"
mkdir -p "$task_build/module-cache" "$PWD/dist" "$task_app/Contents/MacOS" "$task_app/Contents/Frameworks" "$task_app/Contents/Resources"
swiftc -swift-version 5 -O -whole-module-optimization -module-cache-path "$task_build/module-cache" -target "$(uname -m)-apple-macosx13.0" -emit-library -emit-module -module-name MappingCore Sources/MappingCore/*.swift -o "$task_build/libMappingCore.dylib" -emit-module-path "$task_build/MappingCore.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libMappingCore.dylib'
swiftc -swift-version 5 -O -whole-module-optimization -module-cache-path "$task_build/module-cache" -target "$(uname -m)-apple-macosx13.0" -I "$task_build" -L "$task_build" -lMappingCore Sources/ApertureCue/*.swift -o "$task_build/ApertureCue" -Xlinker -rpath -Xlinker '@executable_path' -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
cp "$task_build/ApertureCue" "$task_app/Contents/MacOS/"
cp "$task_build/libMappingCore.dylib" "$task_app/Contents/Frameworks/"
cp packaging/Info.plist "$task_app/Contents/"
cp LICENSE THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/"
xattr -cr "$task_app"
codesign --force --sign - "$task_app/Contents/Frameworks/libMappingCore.dylib"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
# Preserve mapped files of a running previous build instead of truncating them.
if [[ -d dist/ApertureCue.app ]]; then mv dist/ApertureCue.app "$task_package/Previous-ApertureCue.app"; fi
mv "$task_app" dist/ApertureCue.app
echo "Built $PWD/dist/ApertureCue.app"
