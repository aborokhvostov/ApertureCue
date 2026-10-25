#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_build="$PWD/.build/core-checks"
mkdir -p "$task_build/sources" "$task_build/cache"
swiftc -swift-version 5 -parse-as-library -enable-testing -emit-library -emit-module \
  -module-name MappingCore Sources/MappingCore/*.swift \
  -module-cache-path "$task_build/cache" -o "$task_build/libMappingCore.dylib" \
  -emit-module-path "$task_build/MappingCore.swiftmodule"
swiftc -swift-version 5 -parse-as-library -emit-library -emit-module \
  -module-name CoreTestSupport Tests/Runner/CoreTestSupport.swift \
  -module-cache-path "$task_build/cache" -o "$task_build/libCoreTestSupport.dylib" \
  -emit-module-path "$task_build/CoreTestSupport.swiftmodule"
# Only the XCTest import is replaced. Assertion calls and test bodies are identical to CI.
for task_source in Tests/MappingCoreTests/*.swift; do
  sed 's/^import XCTest$/import CoreTestSupport/' "$task_source" > "$task_build/sources/$(basename "$task_source")"
done
swiftc -swift-version 5 -I "$task_build" -L "$task_build" -lMappingCore -lCoreTestSupport \
  -module-cache-path "$task_build/cache" -Xlinker -rpath -Xlinker "$task_build" \
  "$task_build"/sources/*.swift Tests/Runner/main.swift -o "$task_build/core-checks"
"$task_build/core-checks"
