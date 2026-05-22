#!/usr/bin/env bash
# 从 MacApp/Assets/AppIcon.png 生成 AppIcon.icns（1024 源图）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/MacApp/Assets/AppIcon.png"
OUT="$ROOT/MacApp/Assets/AppIcon.icns"
ICONSET="$ROOT/MacApp/Assets/AppIcon.iconset"

if [[ ! -f "$SRC" ]]; then
  echo "[icon] missing $SRC"
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

make_icon() {
  local size=$1
  local name=$2
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

make_icon 16  icon_16x16.png
make_icon 32  icon_16x16@2x.png
make_icon 32  icon_32x32.png
make_icon 64  icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "[icon] built $OUT"
