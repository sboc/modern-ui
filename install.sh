#!/usr/bin/env bash
# Symlink Modern UI into a WoW AddOns folder so edits here show up after /reload.
# Usage: ./install.sh [/path/to/_retail_/Interface/AddOns]
set -euo pipefail
DEST="${1:-$HOME/Dropbox/WoW/AddOns}"
SRC="$(cd "$(dirname "$0")" && pwd)/modern-ui"
[ -d "$DEST" ] || { echo "AddOns folder not found: $DEST" >&2; exit 1; }
ln -sfn "$SRC" "$DEST/modern-ui"
echo "Linked $SRC -> $DEST/modern-ui"
