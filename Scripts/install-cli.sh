#!/bin/zsh
# Puts `halftone` on PATH so the diagnostics commands are typeable.
#
#   halftone --report     latency for every signal switch
#   halftone --calls      the same, calls only
#   halftone --probe 30   live detector state
#
# The shim resolves the app at run time, preferring an installed copy, so it
# keeps working after the build directory moves or is cleaned.
set -e

DEST="${1:-$HOME/.local/bin}"
REPO_APP="$(cd "$(dirname "$0")/.." && pwd)/build/Halftone.app/Contents/MacOS/Halftone"

mkdir -p "$DEST"
cat > "$DEST/halftone" <<EOF
#!/bin/zsh
for candidate in \\
  "/Applications/Halftone.app/Contents/MacOS/Halftone" \\
  "$REPO_APP"
do
  [ -x "\$candidate" ] && exec "\$candidate" "\$@"
done
echo "halftone: no Halftone.app found. Build it with Scripts/release.sh," >&2
echo "or drag Halftone.app to /Applications." >&2
exit 1
EOF
chmod +x "$DEST/halftone"

echo "installed: $DEST/halftone"
case ":$PATH:" in
  *":$DEST:"*) echo "on PATH already. Try: halftone --report" ;;
  *) echo "NOTE: $DEST is not on your PATH. Add it to ~/.zshrc:"
     echo "  export PATH=\"$DEST:\$PATH\"" ;;
esac
