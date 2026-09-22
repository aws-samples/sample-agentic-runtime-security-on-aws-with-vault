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
# Output: workshop-flyer.html (self-contained, print-ready).
#
# Requires: qrencode  (brew install qrencode)
#
# Usage:
#   bash assets/flyer/build-flyer.sh              # HTML only
#   bash assets/flyer/build-flyer.sh --pdf        # HTML + workshop-flyer.pdf
#
# --pdf renders through headless Chrome, which is the same engine the flyer is
# designed against, so the CSS grid, the embedded fonts and the dark ground all
# survive and the text stays selectable. The template carries a print stylesheet
# that compacts the type scale to fit Letter in ONE page and prints the headline
# in flat ink — Chrome's print pipeline does not honour background-clip:text and
# paints the gradient as a solid box over the glyphs. Printing from the browser's
# own dialog works too, but only with "Background graphics" ticked.
#===============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

WORKSHOP_URL="${WORKSHOP_URL:-https://catalog.us-east-1.prod.workshops.aws/workshops/9d6a0b3d-9ea2-47a2-8ca4-40168cadd531/en-US}"

WANT_PDF=false
OUT=""
for arg in "$@"; do
    case "${arg}" in
        --pdf) WANT_PDF=true ;;
        -*)    echo "FATAL: unknown option ${arg}" >&2; exit 2 ;;
        *)     OUT="${arg}" ;;
    esac
done
OUT="${OUT:-${HERE}/workshop-flyer.html}"

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

if [ "${WANT_PDF}" = true ]; then
    chrome=""
    for candidate in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "$(command -v google-chrome || true)" \
        "$(command -v chromium || true)" \
        "$(command -v chromium-browser || true)"; do
        [ -n "${candidate}" ] && [ -x "${candidate}" ] && { chrome="${candidate}"; break; }
    done
    [ -n "${chrome}" ] || {
        echo "FATAL: no Chrome/Chromium found — install Google Chrome, or open ${OUT}" >&2
        echo "       in a browser and print to PDF with 'Background graphics' ticked." >&2
        exit 1
    }

    pdf="${OUT%.html}.pdf"
    # --virtual-time-budget gives the inlined @font-face faces time to decode
    # before the snapshot. --no-pdf-header-footer keeps Chrome's URL/date
    # furniture off the page.
    "${chrome}" --headless --disable-gpu --no-sandbox \
        --virtual-time-budget=10000 \
        --no-pdf-header-footer \
        --print-to-pdf="${pdf}" \
        "file://${OUT}" 2>/dev/null

    [ -s "${pdf}" ] || { echo "FATAL: Chrome produced no PDF at ${pdf}" >&2; exit 1; }
    echo "pdf written:   ${pdf}  ($(wc -c < "${pdf}" | tr -d " ") bytes)"
fi
