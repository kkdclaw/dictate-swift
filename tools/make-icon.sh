#!/bin/bash
# Resources/AppIcon.icns из tools/make-icon.swift (все размеры iconset рисуются заново, а не масштабируются)
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$T"
for s in 16 32 128 256 512; do
  swift tools/make-icon.swift "$T/icon_${s}x${s}.png" $s
  swift tools/make-icon.swift "$T/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$T" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns: $(du -h Resources/AppIcon.icns | cut -f1)"
