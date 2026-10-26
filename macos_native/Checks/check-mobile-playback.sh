#!/bin/bash
set -euo pipefail
checks_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$checks_dir/../.." && pwd)"
products_dir="${1:-$repo_dir/macos_native/build/Build/Products/Release}"
check_dir="$(mktemp -d -t simplelive-mobile-check)"
trap 'rm -rf "$check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  -I "$products_dir" "$products_dir/SimpleLiveKit.o" \
  "$repo_dir/ios_native/App/Player/PlaybackStreamSelection.swift" \
  "$repo_dir/ios_native/App/Support/MobileRoomPlaybackSession.swift" \
  "$repo_dir/ios_native/App/Support/Stores.swift" \
  "$repo_dir/ios_native/App/Support/AppSettings.swift" \
  "$repo_dir/ios_native/App/Support/Library.swift" \
  "$repo_dir/ios_native/App/Support/Theme.swift" \
  "$repo_dir/ios_native/App/Player/DanmakuOverlay.swift" \
  "$repo_dir/ios_native/App/Player/DanmakuTextRasterizer.swift" \
  "$checks_dir/MobilePlaybackCheck.swift" -o "$check_dir/check"
SIMPLELIVE_DISABLE_DIAGNOSTICS=1 "$check_dir/check"
