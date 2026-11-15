#!/bin/bash
# Релиз: ./release.sh X.Y.Z [--push]
# Проверяет раздел «## [X.Y.Z] — ГГГГ-ММ-ДД» в CHANGELOG.md, ветку main, чистое дерево
# (кроме VERSION, CHANGELOG.md, Resources/Info.plist), рост версии; пишет VERSION и версию в Info.plist
# (её показывает меню приложения), коммитит «Release vX.Y.Z», ставит тег vX.Y.Z; с --push отправляет в origin.
# RELEASE_TRAILER в окружении — дополнительные строки в сообщение коммита (например, Co-Authored-By).
# После релиза собрать и поставить: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:-}"; PUSH="${2:-}"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "использование: $0 X.Y.Z [--push]" >&2; exit 2; fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || { echo "релиз делается из main (сейчас $BRANCH)" >&2; exit 1; }
grep -q "^## \[$VER\]" CHANGELOG.md || { echo "в CHANGELOG.md нет раздела «## [$VER] — ГГГГ-ММ-ДД» — сначала опиши релиз" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VER" >/dev/null; then echo "тег v$VER уже есть" >&2; exit 1; fi
CUR="$(cat VERSION 2>/dev/null || echo 0.0.0)"
TOP="$(printf '%s\n%s\n' "$CUR" "$VER" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [[ "$TOP" != "$VER" || "$CUR" == "$VER" ]]; then echo "версия $VER не больше текущей $CUR" >&2; exit 1; fi
if [[ -n "$(git status --porcelain --untracked-files=no | grep -v -E '^ M (VERSION|CHANGELOG.md|Resources/Info.plist)$' || true)" ]]; then
  echo "есть незакоммиченные правки, кроме VERSION/CHANGELOG.md/Info.plist — сначала закоммить:" >&2
  git status --short --untracked-files=no >&2; exit 1
fi
echo "$VER" > VERSION
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $VER" Resources/Info.plist
git add VERSION CHANGELOG.md Resources/Info.plist
git commit -q -m "Release v$VER" ${RELEASE_TRAILER:+-m "$RELEASE_TRAILER"}
git tag -a "v$VER" -m "dictate-swift v$VER"
echo "выпущена v$VER ($(git rev-parse --short HEAD)); собрать и поставить: ./build.sh"
if [[ "$PUSH" == "--push" ]]; then git push -q origin main && git push -q origin "v$VER" && echo "отправлено в origin"; fi
