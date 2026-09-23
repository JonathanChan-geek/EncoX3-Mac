#!/bin/bash
# Installs the built apps into ~/Applications (per-user only; never system-wide)
# and verifies the bundles exist and are signed.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d dist ]; then
  echo "dist/ 不存在，先运行 ./build.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
for app in "dist/Enco X3.app" "dist/Enco Probe.app"; do
  if [ ! -d "$app" ]; then
    echo "跳过（未找到）: $app" >&2
    continue
  fi
  rm -rf "$HOME/Applications/$(basename "$app")"
  cp -R "$app" "$HOME/Applications/"
  echo "已安装: $HOME/Applications/$(basename "$app")"
done

echo
echo "校验签名:"
codesign --verify --deep --strict "$HOME/Applications/Enco X3.app" && echo "  Enco X3.app 签名有效"
codesign --verify --deep --strict "$HOME/Applications/Enco Probe.app" && echo "  Enco Probe.app 签名有效"

cat <<'NOTE'

下一步
  1. 先让耳机在系统蓝牙设置中处于已连接状态（本应用不会主动连接/配对/断开）。
  2. 若首次读取不到设备，打开 系统设置 > 隐私与安全性 > 蓝牙，允许对应 App。
  3. 菜单栏图标点开即用；诊断命令见 README。
NOTE
