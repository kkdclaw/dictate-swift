#!/bin/bash
# Сборка Dictate.app: ./build.sh [--install]
# --install — заменить /Applications/Dictate.app и запустить.
# Подпись: постоянная — разрешения macOS (Микрофон, Универсальный доступ, Мониторинг ввода) переживают
# пересборку, потому что macOS узнаёт приложение по сертификату, а не по хэшу сборки. По умолчанию —
# локальный сертификат «Dictate Local Signing» из связки ключей (создание и удаление — README), другой —
# DICTATE_SIGN_ID="…". Сертификата нет — ad-hoc (-): после каждой пересборки разрешения выдавать заново.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Dictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Dictate "$APP/Contents/MacOS/Dictate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/whisper-assets Resources/vad Resources/dashboard Resources/help "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ресурсы пакетов SwiftPM (шейдеры MLX — mlx-swift_Cmlx.bundle, словари токенизаторов…)
for b in .build/release/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# whisper.cpp — фреймворк рядом с бинарником (rpath @executable_path/../Frameworks задан в Package.swift)
cp -R .build/release/whisper.framework "$APP/Contents/Frameworks/"
# номер сборки — коммит: видно в «О программе» и в журнале
BUILD="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

DEFAULT_ID="Dictate Local Signing"
if [[ -z "${DICTATE_SIGN_ID:-}" ]] && security find-certificate -c "$DEFAULT_ID" >/dev/null 2>&1; then
  DICTATE_SIGN_ID="$DEFAULT_ID"
fi
SIGN="${DICTATE_SIGN_ID:--}"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN" "$APP"
echo "собрано: $APP ($(cat VERSION) · $BUILD, подпись ${DICTATE_SIGN_ID:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Dictate 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Dictate.app
  cp -R "$APP" /Applications/
  open /Applications/Dictate.app
  echo "поставлено и запущено: /Applications/Dictate.app"
fi
