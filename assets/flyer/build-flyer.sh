#!/usr/bin/env bash
#===============================================================================
# assets/flyer/build-flyer.sh — regenerate the one-page workshop flyer.
#
# Edit flyer.template.html (copy, layout, colours), then run this. Everything
# else is derived, so nothing in the output needs hand-editing:
#
#   * assets/aws-logo.png and assets/hashicorp_logo.png are recoloured to their
#     reversed (white) variants with real transparency — the shipped files are a
#     dark navy wordmark and a black hexagon on a SOLID WHITE field, and both
#     disappear or show as a white box on the flyer's dark ground.
#   * the QR code is generated from WORKSHOP_URL below and inlined as an SVG
#     path, so the flyer has no external image requests and prints crisp.
#
# Output: workshop-flyer.html (self-contained, ~31 KB, print-ready).
#
# Requires: qrencode  (brew install qrencode)
#
# Usage: bash assets/flyer/build-flyer.sh
#===============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

WORKSHOP_URL="${WORKSHOP_URL:-https://catalog.us-east-1.prod.workshops.aws/workshops/9d6a0b3d-9ea2-47a2-8ca4-40168cadd531/en-US}"
OUT="${1:-${HERE}/workshop-flyer.html}"

command -v qrencode >/dev/null 2>&1 || {
    echo "FATAL: qrencode not found. Install it with:  brew install qrencode" >&2
    exit 1
}
[ -f "${HERE}/flyer.template.html" ] || { echo "FATAL: flyer.template.html missing" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

# QR: generate, then rebuild it as ONE svg path from qrencode's own module grid
# (its native SVG is ~52 KB of individual <rect> elements).
qrencode -t SVG -o "${work}/qr.svg" -m 0 --level=M "${WORKSHOP_URL}"

python3 "${HERE}/build-flyer.py" \
    --repo "${REPO}" --here "${HERE}" --work "${work}" \
    --url "${WORKSHOP_URL}" --out "${OUT}"

echo "flyer written: ${OUT}"
