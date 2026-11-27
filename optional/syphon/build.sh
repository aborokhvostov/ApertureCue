#!/bin/bash
set -euo pipefail
if [[ $# != 2 || "$(basename "$1")" != Syphon.framework || ! -d "$1" ]]; then
  echo 'Usage: build.sh /path/to/Syphon.framework /path/to/helper-output-directory' >&2
  exit 2
fi
frameworks="$(cd "$(dirname "$1")" && pwd -P)"
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
mkdir -p "$2"
out="$(cd "$2" && pwd -P)"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -F "$frameworks" -framework Syphon -framework Foundation -framework Metal -framework OpenGL \
  -Wl,-rpath,"$frameworks" "$source_dir/SyphonInbox.m" -o "$out/aperturecue-syphon"
printf '%s\n' "$out/aperturecue-syphon"
