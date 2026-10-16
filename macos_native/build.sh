#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodegen generate --spec "$project_dir/project.yml"
xcodebuild -project "$project_dir/SimpleLiveMac.xcodeproj" \
  -scheme SimpleLiveMac -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$project_dir/build" build
printf '\nApp: %s\n' "$project_dir/build/Build/Products/Release/SwiftPeek.app"
