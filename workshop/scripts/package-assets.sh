#!/usr/bin/env bash
# Sync diagram SVGs from repo-root assets/ to workshop/static/images/.
#
# RESEARCH §Pitfall 5: the slide deck uses relative `assets/<svg>` paths while
# Workshop Studio resolves images via absolute `/static/images/<svg>` paths.
# This script reconciles the two by copying the canonical SVGs (produced by the
# excalidraw-to-svg pipeline in Plan 03) into the Workshop Studio static tree.
#
# Run this AFTER any update to the diagrams in assets/.

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$REPO_ROOT/assets"
DST_DIR="$REPO_ROOT/workshop/static/images"

mkdir -p "$DST_DIR"

for svg in architecture-overview uc1-flow uc2-oauth-flow uc3-ciba-flow audit-correlation verify-vault-split vault-authorization-flow; do
    if [ -f "$SRC_DIR/$svg.svg" ]; then
        cp "$SRC_DIR/$svg.svg" "$DST_DIR/$svg.svg"
        echo "  copied $svg.svg -> workshop/static/images/"
    else
        echo "  SKIP: $SRC_DIR/$svg.svg not found (run excalidraw-to-svg.py first)"
    fi
done
