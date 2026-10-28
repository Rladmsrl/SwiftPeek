#!/bin/bash
set -euo pipefail
checks_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$checks_dir/../.." && pwd)"
products_dir="${1:-$repo_dir/macos_native/build/Build/Products/Release}"
check_dir="$(mktemp -d -t simplelive-buffered-check)"
trap 'rm -rf "$check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  -I "$products_dir" "$products_dir/SimpleLiveKit.o" \
  "$repo_dir/ios_native/App/Player/FLVDemuxer.swift" \
  "$repo_dir/ios_native/App/Player/HTTPChunkStream.swift" \
  "$repo_dir/ios_native/App/Player/HTTPStreamBackpressure.swift" \
  "$repo_dir/ios_native/App/Player/BufferedLiveSource.swift" \
  "$repo_dir/ios_native/App/Player/PlaybackStreamSelection.swift" \
  "$repo_dir/ios_native/App/Player/LiveHandoffPolicy.swift" \
  "$repo_dir/ios_native/App/Player/LiveHandoffTimeline.swift" \
  "$repo_dir/ios_native/App/Player/LiveJitterPolicy.swift" \
  "$repo_dir/ios_native/App/Player/NetworkPathMonitor.swift" \
  "$checks_dir/BufferedPlaybackCheck.swift" -o "$check_dir/check"
SIMPLELIVE_DISABLE_DIAGNOSTICS=1 "$check_dir/check"
