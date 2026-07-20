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

# Workshop Studio's markdown renderer does NOT support inline .svg, so every
# diagram must ship as PNG. The SVGs stay the single editable source of truth
# (assets/*.svg); we rasterize them at build time so the dark theme is preserved
# exactly — #0d1117 is baked into each SVG's full-canvas rect, so the PNG comes
# out dark with no manual conversion and no light-mode surprises. 2x zoom keeps
# text crisp on hi-dpi displays.
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "  ABORT: rsvg-convert not found — install librsvg (brew install librsvg / apt-get install librsvg2-bin)" >&2
    exit 1
fi
rm -f "$DST_DIR"/*.svg   # drop any stale synced SVGs; Workshop Studio serves the PNGs below
for svg in architecture-overview uc1-flow uc2-oauth-flow uc3-ciba-flow audit-correlation verify-vault-split vault-authorization-flow ivia-stack; do
    if [ -f "$SRC_DIR/$svg.svg" ]; then
        rsvg-convert -z 2 -b '#0d1117' -o "$DST_DIR/$svg.png" "$SRC_DIR/$svg.svg"
        echo "  rasterized $svg.svg -> workshop/static/images/$svg.png"
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

# ── Sync the application source trees (uc3-agent + banking-app) for image builds ──
# In `ecr` image-source mode the CodeBuild project builds the Use Case images from
# source, so their Docker build contexts must ride along in the assets bundle. The
# build scripts resolve REPO_ROOT to `.../terraform/`, so applications/ must sit as a
# SIBLING of infrastructure/ at terraform/applications/. (uc1-agent's source lives at
# infrastructure/modules/uc1_agent/agent and already ships via the sync above; only
# uc3-agent + banking-app live under applications/.) Exclude heavy/regenerable build
# artifacts — Docker rebuilds them at image-build time (npm install, pip install).
APP_SRC="$REPO_ROOT/applications"
APP_DST="$REPO_ROOT/workshop/assets/terraform/applications"
mkdir -p "$APP_DST"
rsync -a --delete \
    --exclude='node_modules/' \
    --exclude='__pycache__/' \
    --exclude='.venv/' \
    --exclude='*.pyc' \
    --exclude='.pytest_cache/' \
    --exclude='dist/' \
    --exclude='build/' \
    --exclude='*.log' \
    "$APP_SRC/" "$APP_DST/"
echo "  synced applications/ -> workshop/assets/terraform/applications/ (uc3-agent + banking-app build contexts)"

# Hard secret-leak gate — abort the whole package if any real secret-bearing file
# made it into the assets tree. (.example tfvars are safe; everything else is not.)
# Scans both trees: tfvars/tfstate/.acme-state from infrastructure/, plus a bare .env
# from the app trees (a developer's uncommitted local secrets must never ship).
LEAK="$(find "$REPO_ROOT/workshop/assets/terraform" \( -name '*.tfvars' ! -name '*.tfvars.example' \) -o -name '*.tfstate*' -o -name '.acme-state' -o -name '.env' 2>/dev/null)"
if [ -n "$LEAK" ]; then
    echo "  ABORT: secret-bearing files leaked into workshop/assets/terraform:" >&2
    echo "$LEAK" >&2
    rm -rf "$TF_DST" "$APP_DST"
    exit 1
fi
echo "  secret-leak gate: PASS (no real tfvars/tfstate/.acme-state/.env in assets)"

# Private-key content gate — TLS/SSH private keys are now Terraform-generated at
# deploy time (tls_private_key.*), never committed. This gate enforces that
# invariant durably: it scans the assets tree for actual PEM private-key material
# (the BEGIN banner), so a future accidental re-commit of a *.key/*.pem private
# key can never be published to the S3 assets bucket. Public certs (*.crt, *.pem
# CERTIFICATE, dhparam.pem) do NOT match and ship normally.
KEYLEAK="$(grep -rlE -- '-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----' "$REPO_ROOT/workshop/assets/terraform" 2>/dev/null)"
if [ -n "$KEYLEAK" ]; then
    echo "  ABORT: private-key material leaked into workshop/assets/terraform:" >&2
    echo "$KEYLEAK" >&2
    rm -rf "$TF_DST" "$APP_DST"
    exit 1
fi
echo "  private-key gate: PASS (no PEM private keys in assets — keys are Terraform-generated at deploy)"

# Binary-keystore gate — the PEM content grep above cannot see inside binary
# PKCS#12/JKS/PFX keystores (they hold DER-encoded private keys). iviawrprp1.p12
# was the one committed binary keystore and is now minted at deploy, so NO
# keystore should ship. This filename gate blocks any *.p12/.jks/.pfx/.keystore
# from reaching the assets bucket if one is ever re-committed.
KSLEAK="$(find "$REPO_ROOT/workshop/assets/terraform" \( -name '*.p12' -o -name '*.jks' -o -name '*.pfx' -o -name '*.keystore' \) 2>/dev/null)"
if [ -n "$KSLEAK" ]; then
    echo "  ABORT: binary keystore(s) leaked into workshop/assets/terraform:" >&2
    echo "$KSLEAK" >&2
    rm -rf "$TF_DST" "$APP_DST"
    exit 1
fi
echo "  binary-keystore gate: PASS (no .p12/.jks/.pfx in assets — the WRP p12 is minted at deploy)"

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
