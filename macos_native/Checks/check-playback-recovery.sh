#!/bin/bash
set -euo pipefail
checks_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$checks_dir/../.." && pwd)"
check_dir="$(mktemp -d -t simplelive-recovery)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 \
  "$repo_dir/ios_native/App/Player/PlaybackRecoveryPolicy.swift" \
  "$checks_dir/PlaybackRecoveryCheck.swift" -o "$check_dir/check"
"$check_dir/check"
