#!/bin/sh
# リリースビルドして Proofdeck.app を作る（Quick Look のプレビュー拡張を同梱）。
#   ./build.sh            … .build/xcode/Build/Products/Release/Proofdeck.app を作る
#   ./build.sh install    … さらに ~/Applications にコピーして、Quick Look 拡張を登録する
# .app は隠しフォルダの .build に置く。見える場所に置くと、Spotlight や Alfred に
# ~/Applications のものと二つ並んでしまうため。
# 要るもの: Xcode、Node.js、xcodegen（brew install xcodegen）
set -eu
cd "$(dirname "$0")"
(cd web && npm install --ignore-scripts --no-audit --no-fund >/dev/null && node build.mjs)
xcodegen generate --quiet
xcodebuild -project Proofdeck.xcodeproj -scheme Proofdeck -configuration Release \
  -derivedDataPath .build/xcode build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=.build/xcode/Build/Products/Release/Proofdeck.app
[ -d "$APP/Contents/PlugIns/ProofdeckPreview.appex" ] || { echo "build failed"; exit 1; }
echo "built: $(pwd)/$APP"
if [ "${1:-}" = "install" ]; then
  DEST="$HOME/Applications/Proofdeck.app"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$(pwd)/$APP" 2>/dev/null || true
  "$LSREG" -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/ProofdeckPreview.appex" 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  echo "installed: $DEST"
fi
