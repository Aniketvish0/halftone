#!/bin/zsh
# swift test needs the CLT's Testing.framework paths spelled out (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
export HALFTONE_DEFAULTS_SUITE=me.aniket.halftone.tests
FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F$FWK \
  -Xlinker -F$FWK \
  -Xlinker -rpath -Xlinker $FWK \
  -Xlinker -rpath -Xlinker $LIB \
  "$@"
