#!/bin/zsh
# swift test needs the CLT's Testing.framework paths spelled out (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
export HALFTONE_DEFAULTS_SUITE=me.aniket.halftone.tests
ROOT=$(xcode-select -p)
FWK=$ROOT/Library/Developer/Frameworks
LIB=$ROOT/Library/Developer/usr/lib
if [[ ! -d $FWK ]]; then
  # Xcode layout keeps Testing.framework inside the shared frameworks dir
  FWK=$ROOT/../Frameworks
  LIB=$ROOT/usr/lib
fi
exec swift test \
  -Xswiftc -F$FWK \
  -Xlinker -F$FWK \
  -Xlinker -rpath -Xlinker $FWK \
  -Xlinker -rpath -Xlinker $LIB \
  "$@"
