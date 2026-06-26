#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# make-title.sh — generate a 1280x720 title card PNG for a demo beat.
#
#   bg     #0d1117 (GitHub dark — matches the VHS terminal margin)
#   title  Dracula pink, auto-fit to a fixed box (robust to title length)
#   sub    optional dimmed subtitle line
#
# Usage: make-title.sh "No Standing Privileges" out.png ["subtitle"]
#-------------------------------------------------------------------------------
set -euo pipefail

TEXT="$1"
OUT="$2"
SUB="${3:-}"

FONT_BOLD="/Users/oscar.medina/Library/Fonts/Meslo LG L DZ Bold for Powerline.ttf"
FONT_REG="/Users/oscar.medina/Library/Fonts/Meslo LG L Regular for Powerline.ttf"
BG="#0d1117"
FG="#ff79c6"
SUBFG="#8b949e"

TMP_TITLE="$(mktemp -t title_txt).png"
TMP_SUB="$(mktemp -t sub_txt).png"
trap 'rm -f "$TMP_TITLE" "$TMP_SUB"' EXIT

# Auto-fit the title into a 1120x200 box (caption: picks the largest pt that fits).
magick -background "$BG" -fill "$FG" -font "$FONT_BOLD" \
  -size 1120x200 -gravity center caption:"$TEXT" "$TMP_TITLE"

if [ -n "$SUB" ]; then
  magick -background "$BG" -fill "$SUBFG" -font "$FONT_REG" \
    -size 1000x56 -gravity center caption:"$SUB" "$TMP_SUB"
  magick -size 1280x720 xc:"$BG" \
    "$TMP_TITLE" -gravity center -geometry +0-44 -composite \
    "$TMP_SUB"   -gravity center -geometry +0+96 -composite \
    "$OUT"
else
  magick -size 1280x720 xc:"$BG" \
    "$TMP_TITLE" -gravity center -composite \
    "$OUT"
fi

echo "title card -> $OUT"
