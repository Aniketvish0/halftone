#!/bin/zsh
# Builds the .app, then packages both release artifacts: zip and DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/bundle.sh release

cd build
rm -f Halftone.app.zip Halftone.dmg
ditto -c -k --keepParent Halftone.app Halftone.app.zip

STAGE=$(mktemp -d)
cp -R Halftone.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Halftone -srcfolder "$STAGE" -ov -format UDZO Halftone.dmg > /dev/null
rm -rf "$STAGE"

echo "Artifacts:"
ls -la Halftone.app.zip Halftone.dmg
