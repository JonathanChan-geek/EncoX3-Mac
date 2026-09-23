#!/bin/bash
# Build drag-and-drop DMG and ZIP archives using only Apple's command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
release_version="$(cat VERSION)"
release_arch="$(lipo -archs '.build/apps/Enco X3.app/Contents/MacOS/EncoMenu')"
case "$release_arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported release architecture: $release_arch" >&2; exit 1 ;;
esac
release_name="EncoX3-Mac-${release_version}-${release_arch}"
release_dir="$PWD/release/v${release_version}"
mkdir -p "$release_dir"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/encox3-package.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

ditto '.build/apps/Enco X3.app' "$stage_dir/Enco X3.app"
ln -s /Applications "$stage_dir/Applications"
cp docs/INSTALL.zh-CN.md "$stage_dir/安装说明.md"
cp LICENSE "$stage_dir/LICENSE"
codesign --verify --deep --strict "$stage_dir/Enco X3.app"

hdiutil create -ov -volname "Enco X3 ${release_version}" \
  -srcfolder "$stage_dir" -fs HFS+ -format UDZO "$release_dir/$release_name.dmg"
ditto -c -k --sequesterRsrc --keepParent '.build/apps/Enco X3.app' "$release_dir/$release_name.zip"
cp docs/INSTALL.zh-CN.md "$release_dir/INSTALL.zh-CN.md"
(
  cd "$release_dir"
  shasum -a 256 "$release_name.dmg" "$release_name.zip" INSTALL.zh-CN.md > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
echo "Release artifacts: $release_dir"
