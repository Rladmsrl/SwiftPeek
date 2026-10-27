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
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null || \
   git rev-parse -q --verify "refs/tags/v$version-macos" >/dev/null; then
  echo 'This version is already tagged; run scripts/bump-version.py first.' >&2
  exit 1
fi
release_dir="$repo_dir/.local/releases/$version/macos"
if [[ -e "$release_dir" ]]; then
  echo 'Release directory already exists; inspect it before retrying.' >&2
  exit 1
fi
mkdir -p "$release_dir/staging"
xcodegen generate --spec macos_native/project.yml > "$release_dir/generate.log" 2>&1
xcodebuild -project macos_native/SimpleLiveMac.xcodeproj -scheme SimpleLiveMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath macos_native/build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_CODE_COVERAGE=NO \
  build > "$release_dir/build.log" 2>&1
app="$release_dir/staging/SwiftPeek.app"
ditto --noextattr --norsrc macos_native/build/Build/Products/Release/SwiftPeek.app "$app"
# Remove STABS/debug map paths before signing the distributed copy.
xcrun strip -S "$app/Contents/MacOS/SwiftPeek" > "$release_dir/strip.log" 2>&1
codesign --force --sign - --options runtime --timestamp=none "$app" > "$release_dir/sign.log" 2>&1
python3 scripts/audit-release.py "$app" --version "$version" --build "$build"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Project generation changed tracked files; review and commit before packaging.' >&2
  exit 1
fi
archive="SwiftPeek-$version-macOS-universal.zip"
COPYFILE_DISABLE=1 ditto -c -k --noextattr --norsrc --keepParent "$app" "$release_dir/$archive"
git archive --format=zip --prefix="SwiftPeek-$version/" -o "$release_dir/SwiftPeek-$version-source.zip" HEAD
(cd "$release_dir" && shasum -a 256 "$archive" "SwiftPeek-$version-source.zip" > SHA256SUMS.txt)
echo "Ready: $archive, matching source archive, SHA256SUMS.txt (under .local/releases/$version/macos)"
