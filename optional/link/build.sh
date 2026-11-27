#!/bin/bash
set -euo pipefail
readonly LINK_COMMIT=5ba907ae027a8c2ec8824463e37296dcefc5e9be
readonly ASIO_COMMIT=8806a6803cde7054c3049d3666d3ec36786568c5
if [[ $# != 2 && ( $# != 3 || "$3" != --fixtures ) ]]; then
  echo 'Usage: build.sh /path/to/Link-4.1.1 /path/to/output [--fixtures]' >&2
  exit 2
fi
sdk="$(cd "$1" && pwd -P)"
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
asio="$sdk/modules/asio-standalone"
if [[ "$(git -C "$sdk" rev-parse HEAD)" != "$LINK_COMMIT" ||
      "$(git -C "$asio" rev-parse HEAD)" != "$ASIO_COMMIT" ||
      -n "$(git -C "$sdk" status --porcelain)" ||
      -n "$(git -C "$asio" status --porcelain)" ]]; then
  echo 'Use the clean pinned Link-4.1.1 checkout and its pinned Asio submodule.' >&2
  exit 2
fi
mkdir -p "$2"
out="$(cd "$2" && pwd -P)"
flags=(-std=c++17 -O2 -pthread -mmacosx-version-min=13.0 -DLINK_PLATFORM_UNIX=1 -DLINK_PLATFORM_MACOSX=1
  -DASIO_NO_TYPEID=1 -DASIO_STANDALONE=1 -DASIO_VERSION_NAMESPACE=link_asio_1_38_2)
xcrun clang++ "${flags[@]}" -I"$sdk/include" -isystem "$asio/include" "$source_dir/LinkBridge.cpp" -o "$out/aperturecue-link"
printf '%s\n' "$out/aperturecue-link"
if [[ ${3:-} == --fixtures ]]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/aperturecue-link-if.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  # These test binaries use lo0 and a private multicast group, never Link's LAN group.
  # The production helper above uses the unmodified official upstream headers.
  mkdir -p "$scratch/ableton/platforms/posix" "$scratch/ableton/discovery" "$out/fixtures"
  cat > "$scratch/ableton/platforms/posix/ScanIpIfAddrs.hpp" <<'EOF'
#pragma once
#include <ableton/discovery/AsioTypes.hpp>
#include <vector>
namespace ableton::platforms::posix {
struct ScanIpIfAddrs {
  std::vector<discovery::IpAddress> operator()() { return {discovery::IpAddressV4::loopback()}; }
};
}
EOF
  sed -e 's/224\.76\.78\.75/239.255.236.77/' -e 's/20808/46382/g' \
    "$sdk/include/ableton/discovery/IpInterface.hpp" > "$scratch/ableton/discovery/IpInterface.hpp"
  xcrun clang++ "${flags[@]}" -DAPERTURECUE_LINK_TEST=1 -I"$scratch" -I"$sdk/include" -isystem "$asio/include" \
    "$source_dir/LinkBridge.cpp" -o "$out/fixtures/aperturecue-link"
  xcrun clang++ "${flags[@]}" -I"$scratch" -I"$sdk/include" -isystem "$asio/include" \
    "$source_dir/LinkFixturePeer.cpp" -o "$out/fixtures/aperturecue-link-peer"
  printf '%s\n' "$out/fixtures/aperturecue-link" "$out/fixtures/aperturecue-link-peer"
fi
