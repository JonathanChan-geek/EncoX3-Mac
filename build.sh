#!/bin/bash
# Builds the release binaries and packages both app bundles into dist/.
#
# Requires only the Command Line Tools (no Xcode, no extra dependencies):
# `swift build -c release` plus ad-hoc `codesign -s -`.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
echo "==> binaries in $BIN_DIR"

rm -rf dist
mkdir -p dist

write_plist() {
  # $1 = path, $2 = executable, $3 = bundle id, $4 = bundle name
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$2</string>
	<key>CFBundleIdentifier</key>
	<string>$3</string>
	<key>CFBundleName</key>
	<string>$4</string>
	<key>CFBundleDisplayName</key>
	<string>$4</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>读取已连接的 OPPO Enco X3 状态并调整其降噪设置。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>读取已连接的 OPPO Enco X3 状态并调整其降噪设置。</string>
</dict>
</plist>
PLIST
}

copy_licenses() {
  # $1 = app path: ship the license/upstream paperwork inside the bundle.
  local resources="$1/Contents/Resources"
  mkdir -p "$resources"
  cp LICENSE "$resources/LICENSE"
  cp -R LICENSES "$resources/LICENSES"
  cp docs/UPSTREAM.md "$resources/UPSTREAM.md"
}

package_app() {
  # $1 = app name, $2 = source binary, $3 = bundle id
  local app="dist/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BIN_DIR/$2" "$app/Contents/MacOS/$2"
  write_plist "$app/Contents/Info.plist" "$2" "$3" "$1"
  copy_licenses "$app"
  # A bundle that cannot be signed is not a deliverable: fail loudly instead of shipping it.
  if ! codesign --force --deep --sign - "$app"; then
    echo "error: ad-hoc codesign failed for $app" >&2
    exit 1
  fi
  if ! codesign --verify --deep --strict "$app"; then
    echo "error: signature verification failed for $app" >&2
    exit 1
  fi
  echo "==> built $app ($(du -sh "$app" | cut -f1), 已签名, 含 LICENSE/LICENSES/UPSTREAM.md)"
}

package_app "Enco X3" EncoMenu local.nigo.EncoX3
package_app "Enco Probe" encoctl local.nigo.EncoX3Probe

echo
echo "done."
echo "  open 'dist/Enco X3.app'                                # 菜单栏应用（首次启动自动展开面板）"
echo "  EncoMenu --diagnostics                                 # 附：最小状态日志到 stderr"
echo "  'dist/Enco Probe.app/Contents/MacOS/encoctl' probe --seconds 20"
echo "  'dist/Enco Probe.app/Contents/MacOS/encoctl' cycle-anc --journal /绝对路径/anc-restore.json"
echo "  'dist/Enco Probe.app/Contents/MacOS/encoctl' cycle-audio --journal /绝对路径/audio-restore.json"
echo
echo "降噪模式（关闭/通透/智能/深度/中度/轻度/自适应通透）与 EQ 预设/空间音效均已实机验收，默认可用；"
echo "--enable-verified-anc、--enable-audio 仅为兼容保留，无实际效果。"
echo "未完成的音频恢复记录不会被覆盖（退出码 7），详见 README。"
