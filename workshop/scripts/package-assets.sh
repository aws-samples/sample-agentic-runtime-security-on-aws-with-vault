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

for svg in architecture-overview uc1-flow uc2-oauth-flow uc3-ciba-flow audit-correlation verify-vault-split vault-authorization-flow ivia-stack; do
    if [ -f "$SRC_DIR/$svg.svg" ]; then
        cp "$SRC_DIR/$svg.svg" "$DST_DIR/$svg.svg"
        echo "  copied $svg.svg -> workshop/static/images/"
    else
        echo "  SKIP: $SRC_DIR/$svg.svg not found (run excalidraw-to-svg.py first)"
    fi
done

# Sync Workshop Studio join screenshots (canonical source: assets/ws-*.png).
# Referenced in workshop content as /images/ws-*.png via Hugo's static path.
for png in ws-otp-signin ws-email-passcode ws-open-console; do
    if [ -f "$SRC_DIR/$png.png" ]; then
        cp "$SRC_DIR/$png.png" "$DST_DIR/$png.png"
        echo "  copied $png.png -> workshop/static/images/"
    else
        echo "  SKIP: $SRC_DIR/$png.png not found"
    fi
done

# ── Sync the tier-1 Terraform provisioning tree into the Workshop Studio assets ──
# The CFN wrapper's CodeBuild project sources workshop/assets/ from S3 and runs
# `deploy-workshop.sh --tier 1` against terraform/infrastructure/. We copy the WHOLE
# infrastructure/ tree (single source of truth stays infrastructure/) so the proven
# scripts work unchanged; the copy is gitignored (.gitignore) and regenerated here.
#
# SECURITY (deny-by-default): infrastructure/ on a deployed machine holds REAL secrets
# in gitignored files — terraform.tfvars (acme_email/ICR key/MMFA secret), *.tfstate
# (resource secrets), .acme-state. NONE may ship to the assets bucket. We exclude all
# generated/stateful/secret artifacts and KEEP only HCL, *.tfvars.example, the provider
# lock files, and scripts/. A hard gate below aborts if any secret leaks through.
TF_SRC="$REPO_ROOT/infrastructure"
TF_DST="$REPO_ROOT/workshop/assets/terraform/infrastructure"
mkdir -p "$TF_DST"
rsync -a --delete \
    --exclude='.terraform/' \
    --exclude='*.tfstate' \
    --exclude='*.tfstate.*' \
    --exclude='*.backup' \
    --exclude='terraform.tfvars' \
    --exclude='.acme-state' \
    --exclude='.deploy-id' \
    --exclude='logs/' \
    --exclude='*.log' \
    "$TF_SRC/" "$TF_DST/"
echo "  synced infrastructure/ -> workshop/assets/terraform/infrastructure/ (HCL + *.example + lock + scripts)"

# Hard secret-leak gate — abort the whole package if any real secret-bearing file
# made it into the assets tree. (.example tfvars are safe; everything else is not.)
LEAK="$(find "$REPO_ROOT/workshop/assets/terraform" \( -name '*.tfvars' ! -name '*.tfvars.example' \) -o -name '*.tfstate*' -o -name '.acme-state' 2>/dev/null)"
if [ -n "$LEAK" ]; then
    echo "  ABORT: secret-bearing files leaked into workshop/assets/terraform:" >&2
    echo "$LEAK" >&2
    rm -rf "$TF_DST"
    exit 1
fi
echo "  secret-leak gate: PASS (no real tfvars/tfstate/.acme-state in assets)"

# Buildspec lint — two failure classes CodeBuild only reports at DOWNLOAD_SOURCE,
# after a stack is already CREATE_IN_PROGRESS (and will hang on the callback):
#   (1) a ': ' (colon-space) in an unquoted echo parses as a YAML mapping, not a string;
#   (2) an invalid phase name (only install/pre_build/build/post_build are allowed —
#       `finally` is a nested block inside a phase, never a top-level phase).
# yq catches both here, before publish/sim.
BS="$REPO_ROOT/workshop/assets/buildspec/buildspec.yml"
if command -v yq >/dev/null 2>&1; then
    BAD="$(yq '[.phases[] | (.commands[], .finally[])] | map(select(tag != "!!str")) | length' "$BS" 2>/dev/null)"
    if [ "${BAD:-0}" -ne 0 ]; then
        echo "  ABORT: buildspec has $BAD non-string command(s) — colon-space in an echo?" >&2
        yq '[.phases[] | (.commands[], .finally[])] | .[] | select(tag != "!!str")' "$BS" >&2
        exit 1
    fi
    BADPHASE="$(yq '.phases | keys | map(select(. != "install" and . != "pre_build" and . != "build" and . != "post_build")) | join(",")' "$BS" 2>/dev/null)"
    if [ -n "$BADPHASE" ]; then
        echo "  ABORT: buildspec has invalid phase name(s): $BADPHASE (finally is a nested block, not a phase)" >&2
        exit 1
    fi
    echo "  buildspec lint: PASS (commands are strings; phases valid)"
else
    echo "  buildspec lint: SKIP (yq not installed)"
fi
