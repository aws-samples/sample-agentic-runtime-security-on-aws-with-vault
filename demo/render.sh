#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# render.sh — render the workshop walkthrough demo reel.
#
# The reel walks the actual workshop content page-by-page with the VERBATIM
# commands an attendee runs: the five Deploy Foundation sections, then Use Case 2
# (Vault JWT Authentication) and Use Case 3 (Three-Plane Audit Correlation).
#
# For each beat: generate a title card (make-title.sh) -> 2.5s title segment,
# render the terminal segment (VHS tape against the LIVE cluster), normalize
# both to 1280x720/30fps, and concat title+terminal into beat-<id>.mp4. Then
# prepend the splash (slide 1 of slides.md) and concat all beats into
# demo/out/security-forensics.mp4 + .gif.
#
# Title card center-screen FIRST, then the terminal appears — per beat.
#
# Prereqs: vhs, ffmpeg, ImageMagick (magick); live AWS creds + 'workshop' kube
# context (the terminal segments run real kubectl/aws/athena commands). The UC2
# beat (05) reads demo/out/uc2-jwt.env — produce it first with:
#   UC2_DEMO_PASSWORD='<oscar-pw>' bash demo/capture-uc2-jwt.sh oscar
#
# Usage:
#   bash demo/render.sh             # all beats + assemble
#   bash demo/render.sh 05          # one beat by id (no assemble)
#   bash demo/render.sh assemble    # reassemble reel from existing beats
#   bash demo/render.sh stitch-uc3 <take.mp4> <request_id> [trim_seconds]
#                                   # assemble the UC3 live-take reel: splash +
#                                   # UC3 title + take + audit transition title
#                                   # + audit beat (06b pinned to request_id)
#-------------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p demo/out demo/logs

# beat metadata: "id|Title|Subtitle|tapefile|speedup"
# speedup>1 time-compresses the terminal segment to keep long live commands
# (test-foundation ~25s, the oidc-check kubectl-run pod ~35s, the UC2 vault reads)
# readable while trimming wall-clock.
BEATS=(
  "00|Verify Infrastructure|Foundation verification — EKS, RDS, Bedrock KB, audit log groups|demo/tapes/00-verify-infrastructure.tape|2"
  "01|Ingest Knowledge Base|Every Bedrock data source ingested — status COMPLETE|demo/tapes/01-ingest-knowledge-base.tape|1.5"
  "02|Validate Vault|3-node Raft HA · KMS auto-unseal · audit device enabled|demo/tapes/02-validate-vault.tape|1.25"
  "03|Validate Identity Access|IBM Verify Identity Access — seven pods, OIDC serving|demo/tapes/03-validate-identity-access.tape|2"
  "04|Platform Health Check|One script — eight platform checks, all PASS|demo/tapes/04-platform-health-check.tape|1.5"
  "05|Vault JWT Authentication|Use Case 2 — a user JWT becomes per-user database credentials|demo/tapes/05-vault-jwt-auth.tape|1.25"
  "06|Three-Plane Audit Correlation|Use Case 3 — one request_id stitches approval, auth, and the write|demo/tapes/06-three-plane-audit.tape|1.5"
)

ONLY="${1:-}"

norm() {  # normalize any mp4 to 1280x720 / 30fps / yuv420p, padded on #0d1117
  ffmpeg -y -loglevel error -i "$1" \
    -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=#0d1117,fps=30,format=yuv420p" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p "$2"
}

build_beat() {
  local id="$1" title="$2" sub="$3" tape="$4" speed="${5:-1}"
  echo "==> beat $id: $title (speed ${speed}x)"
  bash demo/make-title.sh "$title" "demo/out/title-$id.png" "$sub"
  ffmpeg -y -loglevel error -loop 1 -t 2.5 -i "demo/out/title-$id.png" \
    -vf "fps=30,format=yuv420p" -c:v libx264 -crf 18 -pix_fmt yuv420p "demo/out/seg-$id-title.mp4"
  vhs "$tape"
  local term="demo/out/term-$id.mp4"
  if [ "$speed" != "1" ]; then
    ffmpeg -y -loglevel error -i "$term" -filter:v "setpts=PTS/${speed}" -an "demo/out/term-$id-spd.mp4"
    term="demo/out/term-$id-spd.mp4"
  fi
  norm "$term" "demo/out/seg-$id-term.mp4"
  printf "file '%s'\nfile '%s'\n" "$PWD/demo/out/seg-$id-title.mp4" "$PWD/demo/out/seg-$id-term.mp4" > "demo/out/concat-$id.txt"
  ffmpeg -y -loglevel error -f concat -safe 0 -i "demo/out/concat-$id.txt" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p "demo/out/beat-$id.mp4"
  echo "    -> demo/out/beat-$id.mp4"
}

SPLASH_SECS="${SPLASH_SECS:-3.5}"
build_splash() {  # opening splash = slide 1 of slides.md (HashiCorp white theme)
  if [ ! -f demo/out/splash.png ]; then
    echo "==> splash.png missing — generating via make-splash.sh"
    bash demo/make-splash.sh
  fi
  echo "==> splash segment (${SPLASH_SECS}s)"
  ffmpeg -y -loglevel error -loop 1 -t "$SPLASH_SECS" -i demo/out/splash.png \
    -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=white,fps=30,format=yuv420p" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p demo/out/seg-splash.mp4
}

assemble() {  # splash + beat-*.mp4 in BEATS order -> reel + gif (renders no beats)
  local b id rest
  build_splash
  > demo/out/concat-all.txt
  echo "file '$PWD/demo/out/seg-splash.mp4'" >> demo/out/concat-all.txt
  for b in "${BEATS[@]}"; do
    IFS='|' read -r id rest <<< "$b"
    if [ ! -f "demo/out/beat-$id.mp4" ]; then
      echo "MISSING demo/out/beat-$id.mp4 — render it first (bash demo/render.sh $id)" >&2
      return 1
    fi
    echo "file '$PWD/demo/out/beat-$id.mp4'" >> demo/out/concat-all.txt
  done
  echo "==> assembling final reel"
  ffmpeg -y -loglevel error -f concat -safe 0 -i demo/out/concat-all.txt \
    -c:v libx264 -crf 18 -pix_fmt yuv420p demo/out/security-forensics.mp4
  ffmpeg -y -loglevel error -i demo/out/security-forensics.mp4 \
    -vf "fps=12,scale=1280:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse" \
    demo/out/security-forensics.gif
  echo "DONE -> demo/out/security-forensics.mp4 + .gif"
}

# assemble-only: rebuild the reel from existing beats without re-rendering any of
# them. Use after re-rendering a single beat in isolation (e.g. retiming a beat's
# Sleeps) so the already-clean beats are not re-rolled.
if [ "$ONLY" = "assemble" ] || [ "$ONLY" = "--assemble" ]; then
  assemble
  exit $?
fi

# stitch-uc3 mode: assemble the UC3 live-take reel — splash, UC3 title card,
# trimmed/normalized take, audit transition title, and a freshly-rendered audit
# beat (06b) pinned to the take's request_id. Output: demo/out/uc3-refund-with-audit.mp4.
#
# Usage:
#   bash demo/render.sh stitch-uc3 <take.mp4> <request_id> [trim_seconds]
#
# The take.mp4 is a continuous screen recording of the page-70 refund flow (e.g.
# ffmpeg -f avfoundation -i "3"); request_id is the value the agent printed on
# the banking-UI chat output ("Request ID: …"). Optional trim defaults to 90s.
stitch_uc3() {
  local take="$1" rid="$2" trim="${3:-90}"
  [ -f "$take" ] || { echo "stitch-uc3: take not found: $take" >&2; return 2; }
  [ -n "$rid" ]  || { echo "stitch-uc3: request_id required" >&2; return 2; }
  echo "==> stitch-uc3: take=$take request_id=$rid trim=${trim}s"

  build_splash

  echo "==> UC3 title card"
  bash demo/make-title.sh \
    "Use Case 3 — Out-of-Band Refund Approval" \
    demo/out/title-uc3-take.png \
    "Mobile push · CIBA grant · token exchange · Vault JIT credential · attributed DB write"
  ffmpeg -y -loglevel error -loop 1 -t 2.5 -i demo/out/title-uc3-take.png \
    -vf "fps=30,format=yuv420p" -c:v libx264 -crf 18 -pix_fmt yuv420p \
    demo/out/seg-title-uc3-take.mp4

  echo "==> UC3 take: trim 0..${trim}s and normalize 1280x720"
  ffmpeg -y -loglevel error -t "$trim" -i "$take" \
    -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=#0d1117,fps=30,format=yuv420p" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -an demo/out/seg-take-uc3.mp4

  echo "==> audit transition title"
  bash demo/make-title.sh \
    "Same Request ID — The Audit Story" \
    demo/out/title-stitched-audit.png \
    "audit_correlation view stitches CIBA approval · Vault JIT auth · attributed DB write — on that one id"
  ffmpeg -y -loglevel error -loop 1 -t 2.5 -i demo/out/title-stitched-audit.png \
    -vf "fps=30,format=yuv420p" -c:v libx264 -crf 18 -pix_fmt yuv420p \
    demo/out/seg-title-stitched-audit.mp4

  echo "==> render 06b stitched-audit tape (substitute __REQUEST_ID__ → $rid)"
  local tmp_tape="demo/out/06b-stitched-audit.rendered.tape"
  sed "s|__REQUEST_ID__|$rid|" demo/tapes/06b-stitched-audit.tape > "$tmp_tape"
  vhs "$tmp_tape"
  ffmpeg -y -loglevel error -i demo/out/term-06b.mp4 \
    -filter:v "setpts=PTS/1.5" -an demo/out/term-06b-spd.mp4
  ffmpeg -y -loglevel error -i demo/out/term-06b-spd.mp4 \
    -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=#0d1117,fps=30,format=yuv420p" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p demo/out/seg-06b-term.mp4

  echo "==> concat: splash + UC3 title + take + audit title + audit term"
  { echo "file '$PWD/demo/out/seg-splash.mp4'"
    echo "file '$PWD/demo/out/seg-title-uc3-take.mp4'"
    echo "file '$PWD/demo/out/seg-take-uc3.mp4'"
    echo "file '$PWD/demo/out/seg-title-stitched-audit.mp4'"
    echo "file '$PWD/demo/out/seg-06b-term.mp4'"; } > demo/out/concat-stitched.txt
  ffmpeg -y -loglevel error -f concat -safe 0 -i demo/out/concat-stitched.txt \
    -c:v libx264 -crf 18 -pix_fmt yuv420p demo/out/uc3-refund-with-audit.mp4
  ffmpeg -y -loglevel error -i demo/out/uc3-refund-with-audit.mp4 \
    -vf "fps=12,scale=1280:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse" \
    demo/out/uc3-refund-with-audit.gif

  echo "DONE -> demo/out/uc3-refund-with-audit.mp4 + .gif"
}

if [ "$ONLY" = "stitch-uc3" ]; then
  stitch_uc3 "${2:-}" "${3:-}" "${4:-}"
  exit $?
fi

for b in "${BEATS[@]}"; do
  IFS='|' read -r id title sub tape speed <<< "$b"
  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  build_beat "$id" "$title" "$sub" "$tape" "$speed"
done

# A single-beat run just produces beat-<id>.mp4 for review; skip final assembly.
if [ -n "$ONLY" ]; then
  echo "DONE (single beat) -> demo/out/beat-$ONLY.mp4"
  exit 0
fi

assemble
