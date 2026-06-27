#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# make-splash.sh — render slide 1 of slides.md (the HashiCorp white theme, with
# the gradient-filled title) to demo/out/splash.png at 1280x720, for the reel's
# opening splash.
#
# Why a browser screenshot and not reveal-md --print: the theme renders the H1
# title as gradient-filled text (`background-clip: text`). reveal-md's decktape
# PDF path does not support background-clip:text, so the title text goes
# transparent and the gradient fills the whole box (a solid bar, no title). A
# live headless-Chrome screenshot of the reveal-md server renders the gradient
# title AND the branded corner decorations correctly; reveal.js query params
# drop the nav chrome (controls / progress / slide number).
#-------------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p demo/out demo/logs

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PORT="${SPLASH_PORT:-1948}"
[ -x "$CHROME" ] || { echo "Chrome not found at: $CHROME (set CHROME=...)" >&2; exit 1; }

SRVLOG="demo/logs/revealserver-$(date +%s).log"
npx reveal-md slides.md --port "$PORT" --disable-auto-open > "$SRVLOG" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; pkill -f "reveal-md slides.md" 2>/dev/null || true; }
trap cleanup EXIT

up=""
for i in $(seq 1 40); do
  if curl -sf "http://localhost:${PORT}/slides.md" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ -n "$up" ] || { echo "reveal-md server did not come up on :$PORT" >&2; tail -5 "$SRVLOG" >&2; exit 1; }

RAW="demo/out/splash-raw.png"
# 2x device scale for a crisp 1280x720 downscale; query params strip reveal chrome
"$CHROME" --headless=new --hide-scrollbars --no-sandbox --disable-gpu \
  --force-device-scale-factor=2 --window-size=1280,720 --virtual-time-budget=7000 \
  --screenshot="$RAW" \
  "http://localhost:${PORT}/slides.md?controls=false&progress=false&slideNumber=false&transition=none&backgroundTransition=none#/0" 2>/dev/null

magick "$RAW" -resize 1280x720 -background white -flatten demo/out/splash.png

# The deck's slide-1 "Presenter:" line is a live-talk placeholder; the reel is
# self-running, so erase it. The line sits centered just below the logos on plain
# white, clear of the corner gradient decorations — a white rectangle is seamless.
magick demo/out/splash.png -fill white -draw "rectangle 510,460 770,518" demo/out/splash.png

# Video-splash branding (does NOT touch the live deck): drop the AWS "powered by"
# badge and center the HashiCorp logo. Erase the full slide-1 center logo block
# (both logos + the space between), then composite HashiCorp at canvas center.
magick demo/out/splash.png -fill white -draw "rectangle 460,260 910,440" demo/out/splash.png
magick demo/out/splash.png \
  \( assets/hashicorp_logo.png -resize 150x \) -gravity center -geometry +0-5 -composite \
  demo/out/splash.png
echo "DONE -> demo/out/splash.png ($(magick identify -format '%wx%h' demo/out/splash.png))"
