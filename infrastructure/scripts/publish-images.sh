#!/usr/bin/env bash
#===============================================================================
# publish-images.sh — Maintainer-only: build all 5 workshop images and push to
#                     a configurable public GHCR base (bring your own; no default —
#                     e.g. ghcr.io/<githubusername>)
#
# NOT part of the attendee deploy path. Attendees pull pre-built images
# anonymously from the configured GHCR base; they never need a container runtime
# or GHCR credentials (D-02).
#
# The four existing build scripts (build-uc1-agent.sh, build-banking-app.sh,
# build-uc3-agent.sh, build-images.sh) are KEPT as the '--image-source ecr'
# opt-in path. They are NOT called as sub-processes here because each is
# hard-gated on the ECR CLI (describe-repositories / get-login-password), which
# requires a provisioned ECR and valid AWS session. This script inlines the same
# build->tag->push pattern using GHCR variables. The Dockerfile paths and the
# MCP host-side tsc compile (build-banking-app.sh L244-252) are reproduced
# verbatim — there is ONE build definition, no duplicated Dockerfile logic.
#
# CONFIGURABLE BASE (D-15)
#   GHCR_REGISTRY_BASE env (bring your own; no default) or --registry-base
#   flag — e.g. ghcr.io/<githubusername>. The same base drives the consume side
#   (Plan 02 'ghcr_registry_base' Terraform var). Publish base MUST equal consume
#   base — see README.
#
# AUTHENTICATION (never a hardcoded token)
#   GHCR_PAT env — set via 'gh auth refresh -h github.com -s write:packages'
#   then 'export GHCR_PAT=$(gh auth token)', or a classic PAT with write:packages.
#   Pitfall 2: 'gh auth token' may return a token that lacks write:packages;
#   docker login will succeed but docker push will fail with
#   "denied: write_package". Always confirm: 'gh auth status' must list
#   'write:packages' in the scope list before running this script.
#
# VISIBILITY (one-time, UI only — no REST API for container-package visibility)
#   After first push, set each of the 5 packages Public via:
#     https://github.com/users/<GHCR_OWNER>/packages/container/<image>/settings
#     Danger Zone -> Change visibility -> Public
#   The script prints the exact URLs at the end of a real (non-dry-run) publish.
#
# Usage:
#   ./publish-images.sh [--help] [--dry-run] [--registry-base <base>]
#                       [--image <name>]... [--version <tag>]
#
# Default (no --image) publishes all 5 at :v1. To ship a fix to ONE image
# without minting meaningless new versions for the unchanged four:
#   ./publish-images.sh --image banking-ui --version v2
#
# Env-var overrides:
#   GHCR_REGISTRY_BASE  GHCR registry base, e.g. ghcr.io/<githubusername> (required — no default)
#   GHCR_PAT            write:packages token (required for real publish)
#
# Design:
#   - Idempotent: re-running rebuilds (--no-cache) and re-pushes the selected
#     tag overwriting in place — safe to re-run end-to-end (D-12)
#   - Self-verifying: print_pass / print_fail per step
#   - Sources common-checks.sh for detect_container_runtime / container_build /
#     WORKSHOP_CONTAINER_CLI / print_pass / print_fail / FAILURES[]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Suppress the EXIT-trap summary from common-checks.sh (we use set -e; a
# set -e abort would be masked by an "All checks passed" banner). We emit
# the summary manually at the end like the other build-*.sh scripts.
# shellcheck disable=SC2034
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults (arg-parse MUST come before any auth/runtime/login)
#-------------------------------------------------------------------------------
GHCR_REGISTRY_BASE="${GHCR_REGISTRY_BASE:-}"   # bring your own; no default (validated below)
DRY_RUN=false
IMAGE_VERSION="v1"        # tag published this run (default v1); --version overrides
SELECTED_IMAGES=""        # space-separated friendly names; empty = all 5
VERSION_SET=false         # true once --version is parsed (enforces --image pairing)

# The five publishable images, by friendly --image name. bash 3.2-safe: no
# associative arrays (PR #41 removed the bash-4 requirement), a case map instead.
ALL_IMAGES="uc1-agent banking-ui banking-agent banking-mcp uc3-agent"

# _image_repo <friendly-name> — echo the GHCR package repo name, or return 1 if
# the name is not one of the five. Single source of truth for name -> repo.
_image_repo() {
    case "$1" in
        uc1-agent)     echo "workshop-uc1-agent" ;;
        banking-ui)    echo "workshop-banking-app-ui" ;;
        banking-agent) echo "workshop-banking-app-agent" ;;
        banking-mcp)   echo "workshop-banking-app-mcp" ;;
        uc3-agent)     echo "workshop-uc3-agent" ;;
        *) return 1 ;;
    esac
}

# _selected <friendly-name> — true if the image should be published this run.
# No --image given => every image is selected (preserves default behavior).
_selected() {
    [[ -z "${SELECTED_IMAGES}" ]] && return 0
    local want="$1" img
    for img in ${SELECTED_IMAGES}; do
        [[ "${img}" = "${want}" ]] && return 0
    done
    return 1
}

#-------------------------------------------------------------------------------
# Argument parsing — resolve before any auth, login, or runtime detection so
# '--help' and '--dry-run' short-circuit cleanly with no network calls
#-------------------------------------------------------------------------------
usage() {
    cat <<USAGE
publish-images.sh — Maintainer-only GHCR publish orchestrator

Builds the workshop images (--platform linux/amd64, --no-cache) and pushes them
to a configurable public GHCR base. NOT part of the attendee deploy path.

By default all 5 images are published at :v1. Use --image to publish a SUBSET
(e.g. only the one image you changed) and --version to bump just that image —
so unchanged images never get a meaningless new tag.

Usage:
  ./publish-images.sh [--help] [--dry-run] [--registry-base <base>]
                      [--image <name>]... [--version <tag>]

Options:
  --help                    Show this help message
  --dry-run                 Print intended build/tag/push for each image without
                            executing any build, push, or login
  --registry-base <base>    GHCR registry base (must start with ghcr.io/);
                            required — no default. E.g. ghcr.io/<githubusername>
  --image <name>            Publish ONLY this image (repeatable). One of:
                            uc1-agent, banking-ui, banking-agent, banking-mcp,
                            uc3-agent. Omit to publish all 5.
  --version <tag>           Tag to publish for the selected image(s); default
                            v1. REQUIRES --image (without it, every image would
                            be bumped to the same tag — fake versioning).

Environment variables:
  GHCR_REGISTRY_BASE  GHCR registry base, e.g. ghcr.io/<githubusername> (required — no default)
  GHCR_PAT            write:packages token (required for real publish; never
                      set a default — must be provided explicitly or via
                      'export GHCR_PAT=\$(gh auth token)')

Images published:
  <base>/workshop-uc1-agent:v1          UC1 Strands agent
  <base>/workshop-banking-app-ui:v1     Banking UI (SvelteKit)
  <base>/workshop-banking-app-agent:v1  Banking Strands agent
  <base>/workshop-banking-app-mcp:v1    Banking MCP server
  <base>/workshop-uc3-agent:v1          UC3 Strands agent

Pitfall: 'gh auth token' may return a token that lacks write:packages.
  Confirm before running: 'gh auth status' must list 'write:packages'.
  If missing: 'gh auth refresh -h github.com -s write:packages'

After first push, set all 5 packages Public via GitHub UI (one-time):
  https://github.com/users/<owner>/packages/container/<image>/settings

Examples:
  # Publish all 5 to your own GHCR base
  export GHCR_PAT=\$(gh auth token)
  ./publish-images.sh --registry-base ghcr.io/<githubusername>

  # Ship a fix to ONE image at the next version (only this image is rebuilt)
  ./publish-images.sh --image banking-ui --version v2

  # Preview without executing
  ./publish-images.sh --dry-run

  # Publish to a fork's namespace
  ./publish-images.sh --registry-base ghcr.io/acmefork

  # Dry-run against a fork's namespace
  ./publish-images.sh --registry-base ghcr.io/acmefork --dry-run
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --registry-base)
            GHCR_REGISTRY_BASE="${2:?--registry-base requires a value}"
            shift 2
            ;;
        --image)
            _img="${2:?--image requires a value}"
            SELECTED_IMAGES="${SELECTED_IMAGES:+${SELECTED_IMAGES} }${_img}"
            shift 2
            ;;
        --version)
            IMAGE_VERSION="${2:?--version requires a value}"
            VERSION_SET=true
            shift 2
            ;;
        *)
            print_fail "Unknown argument: $1 (use --help for usage)" \
                "Run './publish-images.sh --help' for valid options."
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Validate base and derive GHCR_OWNER
# Fail loud before any auth attempt if the base is misconfigured.
# Done after arg-parse so '--dry-run --registry-base invalid' also fails.
#-------------------------------------------------------------------------------
if [[ -z "${GHCR_REGISTRY_BASE}" ]]; then
    print_fail "No GHCR registry base set" \
        "Bring your own — pass --registry-base ghcr.io/<githubusername> or set GHCR_REGISTRY_BASE. There is no default namespace."
    exit 1
fi
if [[ "${GHCR_REGISTRY_BASE}" != ghcr.io/* ]]; then
    print_fail "Invalid GHCR_REGISTRY_BASE: '${GHCR_REGISTRY_BASE}'" \
        "Base must start with 'ghcr.io/' (e.g. ghcr.io/<githubusername>)."
    exit 1
fi
GHCR_OWNER="${GHCR_REGISTRY_BASE#ghcr.io/}"

#-------------------------------------------------------------------------------
# Validate --image / --version selection before any auth or build.
#   - every --image name must be one of the five
#   - --version requires --image (else all five would be bumped to one tag,
#     minting meaningless new versions for unchanged images)
#-------------------------------------------------------------------------------
for _img in ${SELECTED_IMAGES}; do
    if ! _image_repo "${_img}" >/dev/null 2>&1; then
        print_fail "Unknown --image '${_img}'" \
            "Valid names: ${ALL_IMAGES// /, }."
        exit 1
    fi
done
if [[ "${VERSION_SET}" = "true" && -z "${SELECTED_IMAGES}" ]]; then
    print_fail "--version requires --image" \
        "Name which image(s) the version applies to, e.g. --image banking-ui --version v2. Without --image, --version would bump all five images to the same tag."
    exit 1
fi

#-------------------------------------------------------------------------------
# Resolve the 5 image URIs from the configured base + selected version (D-03, D-15)
#-------------------------------------------------------------------------------
IMG_UC1="${GHCR_REGISTRY_BASE}/workshop-uc1-agent:${IMAGE_VERSION}"
IMG_BANKING_UI="${GHCR_REGISTRY_BASE}/workshop-banking-app-ui:${IMAGE_VERSION}"
IMG_BANKING_AGENT="${GHCR_REGISTRY_BASE}/workshop-banking-app-agent:${IMAGE_VERSION}"
IMG_BANKING_MCP="${GHCR_REGISTRY_BASE}/workshop-banking-app-mcp:${IMAGE_VERSION}"
IMG_UC3="${GHCR_REGISTRY_BASE}/workshop-uc3-agent:${IMAGE_VERSION}"

#-------------------------------------------------------------------------------
# DRY-RUN — print all intended operations and exit before any auth/login/build.
# Referenced in --dry-run before detect_container_runtime so WORKSHOP_CONTAINER_CLI
# is not required (it is unset at this point under set -u).
#-------------------------------------------------------------------------------
if [ "${DRY_RUN}" = "true" ]; then
    echo ""
    print_info "DRY-RUN: publish-images.sh"
    print_info "GHCR registry base: ${GHCR_REGISTRY_BASE}"
    print_info "GHCR owner (login user): ${GHCR_OWNER}"
    echo ""
    echo "  Would build + push the following image(s) at version ${IMAGE_VERSION}:"
    for img in ${ALL_IMAGES}; do
        _selected "${img}" && echo "    ${GHCR_REGISTRY_BASE}/$(_image_repo "${img}"):${IMAGE_VERSION}"
    done
    echo ""
    echo "  Per image: container_build --platform linux/amd64 --no-cache -> tag -> push"
    echo "  MCP only: npm ci + npm run build in applications/banking-app/mcp-server FIRST"
    echo "  Login: echo \"\${GHCR_PAT}\" | <runtime> login ghcr.io -u ${GHCR_OWNER} --password-stdin"
    echo ""
    print_info "No build, push, or login executed (dry-run)."
    echo ""
    print_info "First publish of a NEW package is Private — set it Public via:"
    for img in ${ALL_IMAGES}; do
        _selected "${img}" && echo "    https://github.com/users/${GHCR_OWNER}/packages/container/$(_image_repo "${img}")/settings"
    done
    echo ""
    exit 0
fi

#-------------------------------------------------------------------------------
# Real publish path — auth, runtime, build, tag, push
#-------------------------------------------------------------------------------

echo ""
print_info "publish-images.sh — Maintainer GHCR publish"
print_info "Registry base : ${GHCR_REGISTRY_BASE}"
print_info "GHCR owner    : ${GHCR_OWNER}"
echo ""
print_info "Pitfall: if push returns 'denied: write_package', your token lacks"
print_info "  write:packages scope. Run: gh auth refresh -h github.com -s write:packages"
print_info "  then: export GHCR_PAT=\$(gh auth token)"
echo ""

# Detect container runtime (sets WORKSHOP_CONTAINER_CLI; print_pass/fail inline)
detect_container_runtime || exit 1

# Authenticate to GHCR — PAT comes ONLY from env or gh auth token, NEVER hardcoded
# Security rule: GHCR_PAT has no literal default — must be provided explicitly.
GHCR_PAT="${GHCR_PAT:-$(gh auth token 2>/dev/null || true)}"
if [[ -z "${GHCR_PAT}" ]]; then
    print_fail "GHCR_PAT is not set and 'gh auth token' returned nothing" \
        "Set GHCR_PAT: run 'gh auth refresh -h github.com -s write:packages' then 'export GHCR_PAT=\$(gh auth token)', or export a classic PAT with write:packages."
    exit 1
fi

print_info "Logging in to ghcr.io as ${GHCR_OWNER}..."
echo "${GHCR_PAT}" | "${WORKSHOP_CONTAINER_CLI}" login ghcr.io -u "${GHCR_OWNER}" --password-stdin || {
    print_fail "GHCR login failed for owner ${GHCR_OWNER}" \
        "Verify GHCR_PAT is valid and has write:packages scope: gh auth status"
    exit 1
}
print_pass "GHCR login: ghcr.io / ${GHCR_OWNER}"

#-------------------------------------------------------------------------------
# _publish_image helper
# Builds to a local intermediate tag, retags to the GHCR URI, pushes.
# All build flags passed through: --platform linux/amd64 --no-cache.
# Arguments: <local-tag> <ghcr-uri> [<extra container_build args...>]
#-------------------------------------------------------------------------------
_publish_image() {
    local local_tag="$1"
    local ghcr_uri="$2"
    shift 2
    # Remaining arguments are build flags + context path (passed to container_build)

    print_info "Building ${local_tag}..."
    container_build \
        --platform linux/amd64 \
        --no-cache \
        --tag "${local_tag}" \
        "$@" || {
        print_fail "Build failed: ${local_tag}" \
            "Check Dockerfile and build context. Re-run to retry (--no-cache always rebuilds)."
        return 1
    }
    print_pass "Built ${local_tag}"

    print_info "Tagging ${local_tag} -> ${ghcr_uri}..."
    "${WORKSHOP_CONTAINER_CLI}" tag "${local_tag}" "${ghcr_uri}" || {
        print_fail "Tag failed: ${local_tag} -> ${ghcr_uri}"
        return 1
    }

    print_info "Pushing ${ghcr_uri}..."
    "${WORKSHOP_CONTAINER_CLI}" push "${ghcr_uri}" || {
        print_fail "Push failed: ${ghcr_uri}" \
            "If 'denied: write_package': token lacks write:packages scope. Run: gh auth refresh -h github.com -s write:packages"
        return 1
    }
    print_pass "Pushed ${ghcr_uri}"
    echo ""
}

#-------------------------------------------------------------------------------
# 1. UC1 agent
#    Source: infrastructure/modules/uc1_agent/agent/Dockerfile
#    (mirrors build-uc1-agent.sh AGENT_DIR + --file pattern)
#-------------------------------------------------------------------------------
if _selected uc1-agent; then
print_info "--- UC1 agent ---"
_publish_image "workshop-uc1-agent-local" "${IMG_UC1}" \
    --file "${REPO_ROOT}/infrastructure/modules/uc1_agent/agent/Dockerfile" \
    "${REPO_ROOT}/infrastructure/modules/uc1_agent/agent"
fi

#-------------------------------------------------------------------------------
# 2. Banking app — UI
#    Source: applications/banking-app/ui
#    (mirrors build-banking-app.sh build_and_push "ui" path)
#-------------------------------------------------------------------------------
if _selected banking-ui; then
print_info "--- Banking app: UI ---"
_publish_image "workshop-banking-app-ui-local" "${IMG_BANKING_UI}" \
    "${REPO_ROOT}/applications/banking-app/ui"
fi

#-------------------------------------------------------------------------------
# 3. Banking app — Agent
#    Source: applications/banking-app/agent
#    (mirrors build-banking-app.sh build_and_push "agent" path)
#-------------------------------------------------------------------------------
if _selected banking-agent; then
print_info "--- Banking app: Agent ---"
_publish_image "workshop-banking-app-agent-local" "${IMG_BANKING_AGENT}" \
    "${REPO_ROOT}/applications/banking-app/agent"
fi

#-------------------------------------------------------------------------------
# 4. Banking app — MCP server
#    Pitfall 3 (build-banking-app.sh L244-252): tsc OOMs under QEMU emulation
#    on ARM Macs. The host-side TypeScript compile MUST run before the Docker
#    build so the Dockerfile's COPY picks up the compiled dist/ output.
#    Omitting this step ships an image with no compiled JS, which crashes on
#    pod start. This reproduces build-banking-app.sh L244-252 verbatim.
#    Source (after compile): applications/banking-app/mcp-server
#-------------------------------------------------------------------------------
if _selected banking-mcp; then
print_info "--- Banking app: MCP server ---"
print_info "Compiling MCP server TypeScript on host (Pitfall 3 — tsc before Docker build)..."
mcp_dir="${REPO_ROOT}/applications/banking-app/mcp-server"
(cd "${mcp_dir}" && npm ci --silent 2>/dev/null && npm run build) || {
    print_fail "MCP server TypeScript compilation failed" \
        "Check Node.js + npm are installed. Run 'npm ci && npm run build' in ${mcp_dir} manually to debug."
    exit 1
}
print_pass "MCP server compiled to dist/"

_publish_image "workshop-banking-app-mcp-local" "${IMG_BANKING_MCP}" \
    "${mcp_dir}"
fi

#-------------------------------------------------------------------------------
# 5. UC3 agent
#    Source: applications/uc3-agent/Dockerfile
#    (mirrors build-uc3-agent.sh AGENT_DIR + --file pattern)
#-------------------------------------------------------------------------------
if _selected uc3-agent; then
print_info "--- UC3 agent ---"
_publish_image "workshop-uc3-agent-local" "${IMG_UC3}" \
    --file "${REPO_ROOT}/applications/uc3-agent/Dockerfile" \
    "${REPO_ROOT}/applications/uc3-agent"
fi

#-------------------------------------------------------------------------------
# Summary — published URIs + one-time visibility step
#-------------------------------------------------------------------------------
echo ""
print_pass "Published image(s) at version ${IMAGE_VERSION} to ${GHCR_REGISTRY_BASE}"
echo ""
for img in ${ALL_IMAGES}; do
    _selected "${img}" && echo "  ${GHCR_REGISTRY_BASE}/$(_image_repo "${img}"):${IMAGE_VERSION}"
done
echo ""
print_info "NEXT STEP — package visibility (UI only — no REST API for container-package visibility):"
print_info "A NEW package's first push is Private; an existing public package keeps its"
print_info "visibility (a new :tag on it is already Public). Set any new package Public at:"
for img in ${ALL_IMAGES}; do
    _selected "${img}" && echo "    https://github.com/users/${GHCR_OWNER}/packages/container/$(_image_repo "${img}")/settings"
done
echo "  -> Danger Zone -> Change package visibility -> Public"
echo ""
print_info "Then verify anonymous access (no docker login session):"
echo "  docker logout ghcr.io"
for img in ${ALL_IMAGES}; do
    _selected "${img}" && echo "  docker manifest inspect ${GHCR_REGISTRY_BASE}/$(_image_repo "${img}"):${IMAGE_VERSION}"
done
echo ""

if [ "${#FAILURES[@]}" -gt 0 ]; then
    exit 1
fi
