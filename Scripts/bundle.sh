#!/bin/zsh
# Builds Halftone and assembles an ad-hoc-signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-release}"
swift build -c "$CONF"

BIN=".build/$CONF/Halftone"
APP="build/Halftone.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Halftone"
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force -s - "$APP"
echo "Built $APP"
