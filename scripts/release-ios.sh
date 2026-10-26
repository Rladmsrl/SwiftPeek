#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the reviewed release snapshot before packaging.' >&2
  exit 1
fi
version="$(sed -n "s/.*MARKETING_VERSION: '\([^']*\)'.*/\1/p" shared/version.yml)"
build="$(sed -n "s/.*CURRENT_PROJECT_VERSION: '\([^']*\)'.*/\1/p" shared/version.yml)"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo 'This version is already tagged; run scripts/bump-version.py first.' >&2
  exit 1
fi
release_dir="$repo_dir/.local/releases/$version"
if [[ -e "$release_dir" ]]; then
  echo 'Release directory already exists; inspect it before retrying.' >&2
  exit 1
fi
mkdir -p "$release_dir/staging/Payload"
xcodegen generate --spec ios_native/project.yml > "$release_dir/generate-ios.log" 2>&1
xcodebuild -project ios_native/SimpleLive.xcodeproj -scheme SimpleLive \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$release_dir/build-ios" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  ENABLE_CODE_COVERAGE=NO build > "$release_dir/build-ios.log" 2>&1
app="$release_dir/staging/Payload/SwiftPeek.app"
ditto --noextattr --norsrc "$release_dir/build-ios/Build/Products/Release-iphoneos/SwiftPeek.app" "$app"
xcrun strip -S "$app/SwiftPeek" > "$release_dir/strip-ios.log" 2>&1
python3 scripts/audit-release.py "$app" --platform ios --version "$version" --build "$build"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Project generation changed tracked files; review and commit before packaging.' >&2
  exit 1
fi
archive="SwiftPeek-$version-iOS-unsigned.ipa"
COPYFILE_DISABLE=1 ditto -c -k --noextattr --norsrc --keepParent "$release_dir/staging/Payload" "$release_dir/$archive"
git archive --format=zip --prefix="SwiftPeek-$version/" -o "$release_dir/SwiftPeek-$version-source.zip" HEAD
(cd "$release_dir" && shasum -a 256 "$archive" "SwiftPeek-$version-source.zip" > SHA256SUMS.txt)
echo "Ready: $archive, matching source archive, SHA256SUMS.txt (under .local/releases/$version)"
