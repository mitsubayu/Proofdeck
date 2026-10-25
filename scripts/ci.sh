#!/bin/bash
# The exact checks CI runs, so a green run here means a green pipeline.
# There are no unit tests yet: this builds Release and checks that the bundle
# carries its extension and MCP server and that the signature holds together.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA=".build/xcode"
LOG=".build/reports"
rm -rf "$LOG"
mkdir -p "$LOG"

echo "▸ Bundling the renderer and generating the project"
./scripts/bootstrap.sh

echo "▸ Release build"
xcodebuild \
    -project Proofdeck.xcodeproj \
    -scheme Proofdeck \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    "$@" \
    build >"$LOG/build.log" 2>&1 || {
    grep -E "error:" "$LOG/build.log" | head -20 || true
    echo "✘ release build failed — see $LOG/build.log"
    exit 1
}

APP="$DERIVED_DATA/Build/Products/Release/Proofdeck.app"
echo "▸ Checking the bundle"
for f in Contents/MacOS/Proofdeck Contents/MacOS/proofdeck-mcp \
         Contents/PlugIns/ProofdeckPreview.appex Contents/Resources/web/index.html; do
    [[ -e "$APP/$f" ]] || { echo "✘ missing $f"; exit 1; }
done
# Quick Look only loads a sandboxed extension, so losing the entitlement in a
# signing change would silently turn the preview off.
codesign -d --entitlements - "$APP/Contents/PlugIns/ProofdeckPreview.appex" 2>/dev/null |
    grep -q "com.apple.security.app-sandbox" || { echo "✘ preview extension is not sandboxed"; exit 1; }
codesign --verify --deep --strict "$APP"

echo "✓ all checks passed"
