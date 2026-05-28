#!/usr/bin/env bash
#===============================================================================
# build-images.sh — Build and push ALL workshop application images to ECR
#
# Thin orchestrator over the three per-component build scripts:
#   build-uc1-agent.sh     → workshop/uc1-agent:latest
#   build-banking-app.sh   → workshop-banking-app:{ui,agent,mcp}
#   build-uc3-agent.sh     → workshop/uc3-agent:latest
#
# Run AFTER `terraform apply` (which creates the ECR repositories). The apply
# provisions the Deployments that reference these images; until the images are
# pushed those pods sit in ImagePullBackOff. This script populates ECR; the
# caller (configure-workshop.sh) then rolls the Deployments so they pull.
#
# All images build with --platform linux/amd64 (delegated to the per-component
# scripts) so ARM Macs produce x86_64 images for the EKS nodes.
#
# Usage:
#   ./build-images.sh [--help] [--dry-run] [--region <region>]
#
# Options:
#   --help          Show this help message
#   --dry-run       Show what each build script would do, build nothing
#   --region VALUE  Override AWS region (default: auto-resolved)
#
# Idempotent: re-running rebuilds and re-pushes :latest safely. Exits nonzero
# if any component build fails (so configure-workshop.sh marks the step failed).
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

DRY_RUN=false
REGION=""

usage() {
    sed -n '2,33p' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   usage ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --region)    REGION="${2:?--region requires a value}"; shift 2 ;;
        *)  print_fail "Unknown option: $1. Use --help for usage."; print_summary; exit 1 ;;
    esac
done

# Pass-through flags assembled once and forwarded to each component script.
PASS_ARGS=()
[[ "$DRY_RUN" == true ]] && PASS_ARGS+=("--dry-run")
[[ -n "$REGION" ]] && PASS_ARGS+=("--region" "$REGION")

echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Build & Push Workshop Application Images${NC}"
echo -e "${BLUE}================================================================${NC}"
if [[ "$DRY_RUN" == true ]]; then
    print_warn "DRY-RUN mode — no images will be built or pushed"
fi

# component-label : build-script
_build_component() {
    local label="$1" script="$2"
    echo ""
    echo -e "${YELLOW}> Building ${label}${NC}"
    if [[ ! -x "${SCRIPT_DIR}/${script}" ]] && [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
        print_fail "${label}" "Missing build script: ${SCRIPT_DIR}/${script}"
        return 1
    fi
    if bash "${SCRIPT_DIR}/${script}" "${PASS_ARGS[@]}"; then
        print_pass "${label} image(s) built and pushed"
        return 0
    fi
    print_fail "${label}" "Re-run: ${SCRIPT_DIR}/${script} ${PASS_ARGS[*]}"
    return 1
}

RC=0
_build_component "UC1 agent"   "build-uc1-agent.sh"   || RC=1
_build_component "Banking app" "build-banking-app.sh" || RC=1
_build_component "UC3 agent"   "build-uc3-agent.sh"   || RC=1

print_summary || RC=1
exit "$RC"
