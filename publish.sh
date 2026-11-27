#!/bin/bash
# Публикация релиза (после ./release.sh X.Y.Z): сборка, архив Dictate-X.Y.Z.zip, push main + тег,
# GitHub Release с архивом — через gh: локальный или на другой машине по ssh (GH_SSH=<ssh-алиас> в .local.env,
# файл не в git). Автообновление приложений берёт архив оттуда.
# Собирать на машине с сертификатом «Dictate Local Signing»: приложения принимают обновление той же подписи.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .local.env ]] && source .local.env
VER="$(cat VERSION)"; TAG="v$VER"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "нет тега $TAG — сначала ./release.sh $VER" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "есть незакоммиченные правки" >&2; exit 1; }
security find-certificate -c "Dictate Local Signing" ${DICTATE_KEYCHAIN:+"$DICTATE_KEYCHAIN"} >/dev/null 2>&1 || { echo "нет сертификата «Dictate Local Signing» — релиз с другой подписью не встанет обновлением" >&2; exit 1; }
./build.sh
PV="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Dictate.app/Contents/Info.plist)"
[[ "$PV" == "$VER" ]] || { echo "в Info.plist $PV, а VERSION $VER" >&2; exit 1; }
ZIP="build/Dictate-$VER.zip"; rm -f "$ZIP"
ditto -c -k --keepParent build/Dictate.app "$ZIP"
git push -q origin main && git push -q origin "$TAG"
NOTES="$(awk "/^## \\[$VER\\]/{f=1;next} /^## \\[/{f=0} f" CHANGELOG.md)"
REPO="$(sed -n 's/.*static let repo = "\(.*\)".*/\1/p' Sources/Dictate/Updater.swift)"
if command -v gh >/dev/null; then
  gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Dictate $VER" --notes-file - <<< "$NOTES"
elif [[ -n "${GH_SSH:-}" ]]; then
  scp -q "$ZIP" "$GH_SSH:/tmp/"
  ssh "$GH_SSH" "PATH=/opt/homebrew/bin:\$PATH gh release create '$TAG' '/tmp/Dictate-$VER.zip' --repo '$REPO' --title 'Dictate $VER' --notes-file - ; rm -f '/tmp/Dictate-$VER.zip'" <<< "$NOTES"
else
  echo "нет gh: поставьте его или задайте GH_SSH=<ssh-алиас машины с gh> в .local.env" >&2; exit 1
fi
echo "опубликован релиз $TAG ($(du -h "$ZIP" | cut -f1))"
