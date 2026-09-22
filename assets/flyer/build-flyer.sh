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
#   bash assets/flyer/build-flyer.sh --email      # email-flyer.html (Outlook)
#
# --email renders email.template.html, a SEPARATE Outlook-safe rebuild of the
# same content. Outlook on Windows lays out mail with the Word engine, which
# ignores grid, flex and gradients, so the print flyer cannot
# simply be reused — see the comment block at the top of that template.
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
WANT_EMAIL=false
OUT=""
for arg in "$@"; do
    case "${arg}" in
        --pdf)   WANT_PDF=true ;;
        --email) WANT_EMAIL=true ;;
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

    # The print stylesheet is tuned to land the default content on ONE Letter
    # page with ~14px to spare. A longer WORKSHOP_URL wraps the footer link and
    # can push it over, so assert rather than hand back a silent two-pager.
    pages=$(python3 -c "
import re,sys
d=open(sys.argv[1],'rb').read()
print(len(re.findall(rb'/Type\s*/Page[^s]', d)))" "${pdf}")
    if [ "${pages}" != "1" ]; then
        echo "FATAL: the flyer rendered ${pages} pages; it must be 1." >&2
        echo "       Fix: content or WORKSHOP_URL grew past the page. Tighten the" >&2
        echo "       @media print block in flyer.template.html (spacing first, then" >&2
        echo "       copy) until it fits — do not drop body copy below 12px, which" >&2
        echo "       is the 9pt print floor." >&2
        exit 1
    fi

    # Optional, only when zbarimg is installed: prove the QR still scans at a
    # resolution well below what a phone camera gets off a printed sheet.
    if command -v zbarimg >/dev/null 2>&1 && command -v pdftoppm >/dev/null 2>&1; then
        png="${work}/scan.png"
        pdftoppm -png -r 100 -f 1 -l 1 "${pdf}" "${png%.png}" 2>/dev/null
        shot=""; for cand in "${png%.png}"*.png; do [ -f "${cand}" ] && { shot="${cand}"; break; }; done
        # zbarimg exits non-zero when it finds no barcode — exactly the case this
        # guard exists to report. Under `set -e` an unguarded command
        # substitution would abort here and the FATAL below would never print,
        # so absorb the status and let the comparison do the failing.
        got=""
        if [ -n "${shot}" ]; then
            got=$(zbarimg --quiet --raw "${shot}" 2>/dev/null | head -1 | tr -d "\r\n") || got=""
        fi
        if [ "${got}" != "${WORKSHOP_URL}" ]; then
            echo "FATAL: the QR code did not decode to WORKSHOP_URL at 100 dpi." >&2
            echo "       got: ${got:-<no read>}" >&2
            echo "       Fix: enlarge .qr svg in the @media print block." >&2
            exit 1
        fi
        echo "qr verified:   decodes to WORKSHOP_URL at 100 dpi"
    fi

    echo "pdf written:   ${pdf}  (1 page, $(wc -c < "${pdf}" | tr -d " ") bytes)"
fi

#-------------------------------------------------------------------------------
# --email — the flyer as an Outlook-safe HTML email body.
#
# Rendered from email.template.html, a SEPARATE rebuild of the same content:
# Outlook on Windows lays out mail with the Word engine, which drops grid,
# flex and gradients, so workshop-flyer.html cannot be reused. border-radius is
# the exception: the Word engine drops it and renders a square, which is exactly
# what a version without it renders, while every web-based client (new Outlook,
# OWA, Apple Mail, Gmail) rounds properly. So it is kept, and asserted below.
# Logos and QR come from the same sources as the print flyer, so the two
# artefacts cannot drift. See the docstring in build-email.py.
#-------------------------------------------------------------------------------
if [ "${WANT_EMAIL}" = true ]; then
    [ -f "${HERE}/email.template.html" ] || {
        echo "FATAL: email.template.html missing" >&2; exit 1; }
    email_out="${HERE}/email-flyer.html"
    python3 "${HERE}/build-email.py" \
        --repo "${REPO}" --here "${HERE}" --work "${work}" \
        --url "${WORKSHOP_URL}" --out "${email_out}"

    # Word drops background-color on block elements but honours the bgcolor
    # ATTRIBUTE, so every coloured cell must carry both. A panel added with
    # only the CSS renders white-on-white in Outlook — broken for exactly the
    # audience this file exists for.
    attr_bg=$(grep -o 'bgcolor="#[0-9a-fA-F]\{6\}"' "${email_out}" | wc -l | tr -d ' ')
    if [ "${attr_bg}" -lt 10 ]; then
        echo "FATAL: only ${attr_bg} bgcolor attributes found; coloured cells are missing them." >&2
        exit 1
    fi
    # Anything the Word engine cannot lay out must not be in the body at all.
    for banned in 'display:flex' 'display:grid' 'linear-gradient' 'background-clip' '<style'; do
        if grep -q "${banned}" "${email_out}"; then
            echo "FATAL: '${banned}' is in the email body; the Word engine ignores it." >&2
            exit 1
        fi
    done
    # Rounded corners, to match the artifact. A td only rounds when its table
    # is border-collapse:separate — under collapse the property is silently
    # dropped by every engine that honours it at all, so assert both.
    radii=$(grep -o 'border-radius:' "${email_out}" | wc -l | tr -d ' ')
    if [ "${radii}" -lt 12 ]; then
        echo "FATAL: only ${radii} border-radius declarations; the corners are square." >&2
        exit 1
    fi
    if grep -q 'border-collapse:collapse;[^"]*border-radius' "${email_out}"; then
        echo "FATAL: a rounded element sits on a collapsed table; the radius will not render." >&2
        exit 1
    fi
    # The marks and the QR must actually be embedded, or the paste is text-only.
    imgs=$(grep -o 'src="data:image/png;base64,' "${email_out}" | wc -l | tr -d ' ')
    if [ "${imgs}" -ne 3 ]; then
        echo "FATAL: expected 3 embedded images (AWS, HashiCorp, QR); found ${imgs}." >&2
        exit 1
    fi
    if command -v zbarimg >/dev/null 2>&1; then
        python3 - "${email_out}" "${work}/qr-check.png" <<'EXTRACT'
import base64, pathlib, re, sys
html = pathlib.Path(sys.argv[1]).read_text()
m = re.findall(r'src="data:image/png;base64,([^"]+)"', html)
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(m[-1]))
EXTRACT
        got=$(zbarimg --quiet --raw "${work}/qr-check.png" 2>/dev/null | head -1 | tr -d "\r\n") || got=""
        if [ "${got}" != "${WORKSHOP_URL}" ]; then
            echo "FATAL: the embedded QR did not decode to WORKSHOP_URL (got: ${got:-<no read>})." >&2
            exit 1
        fi
        echo "qr verified:    embedded PNG decodes to WORKSHOP_URL"
    fi
    echo "email written:  ${email_out}  (${attr_bg} bgcolor cells, ${radii} rounded, ${imgs} embedded images)"
    echo "                open in a browser, Select All, Copy, paste into Outlook"
fi
