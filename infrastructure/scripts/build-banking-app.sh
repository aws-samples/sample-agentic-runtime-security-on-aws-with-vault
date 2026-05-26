#!/usr/bin/env bash
#===============================================================================
# build-banking-app.sh — Build and push banking app images to ECR
#
# Builds 3 Docker images for the UC2/UC3 banking app and pushes them to a
# single ECR repository with distinct tags:
#   workshop-banking-app:ui    — SvelteKit banking UI (node:22-alpine)
#   workshop-banking-app:agent — Python Strands agent (python:3.12-slim)
#   workshop-banking-app:mcp   — Node.js MCP server (node:22-alpine)
#
# All images are built with --platform linux/amd64 (EKS nodes are x86_64;
# attendees may build from ARM Macs — this flag prevents silent silica mismatches).
#
# Usage:
#   ./build-banking-app.sh [--help] [--dry-run] [--region <region>]
#
# Env-var overrides:
#   WORKSHOP_REGION  — AWS region (overridden by --region flag or resolve-region.sh)
#   ECR_REPO_NAME    — ECR repository name (default: workshop-banking-app)
#   AWS_ACCOUNT_ID   — AWS account ID (auto-resolved via sts get-caller-identity)
#
# Design:
#   - Idempotent: creates ECR repo if not exists, re-pushes all images safely
#   - Self-verifying: print_pass / print_fail per check
#   - No hardcoded region strings (canonical-region contract)
#   - Sources common-checks.sh for consistent output
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT_DESCRIPTION="Banking App ECR build+push (UI + Agent + MCP server)"

# Source common helpers (print_pass, print_fail, FAILURES[], print_summary)
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

# Source region resolution helper
# shellcheck source=resolve-region.sh
source "${SCRIPT_DIR}/resolve-region.sh"

ECR_REPO_NAME="${ECR_REPO_NAME:-workshop-banking-app}"

#-------------------------------------------------------------------------------
# Parse arguments
#-------------------------------------------------------------------------------
DRY_RUN=false
CLI_REGION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<USAGE
build-banking-app.sh — ${SCRIPT_DESCRIPTION}

Usage:
  ./build-banking-app.sh [--help] [--dry-run] [--region <region>]

Options:
  --help          Show this help message
  --dry-run       Show commands without executing (skips Docker build and push)
  --region VALUE  Override AWS region (default: auto-resolved)

Environment variables:
  WORKSHOP_REGION  AWS region override
  ECR_REPO_NAME    ECR repository name (default: workshop-banking-app)
  AWS_ACCOUNT_ID   AWS account ID (auto-resolved if not set)

Images built:
  workshop-banking-app:ui     SvelteKit banking UI       (node:22-alpine, port 5173)
  workshop-banking-app:agent  Python Strands agent       (python:3.12-slim, port 3002)
  workshop-banking-app:mcp    Node.js MCP server         (node:22-alpine, port 3001)

All images: --platform linux/amd64 (EKS x86_64 compatibility)

Examples:
  # Build and push all 3 images
  ./build-banking-app.sh

  # Preview commands without executing
  ./build-banking-app.sh --dry-run

  # Specify region explicitly
  ./build-banking-app.sh --region us-west-2
USAGE
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --region)
            CLI_REGION="${2:?--region requires a value}"
            shift 2
            ;;
        *)
            print_fail "Unknown argument: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Region resolution (no hardcoded region strings)
#-------------------------------------------------------------------------------
if ! resolve_region "${CLI_REGION:-${WORKSHOP_REGION:-}}"; then
    print_fail "Region resolution failed — set WORKSHOP_REGION, --region flag, or terraform.tfvars"
    exit 1
fi
REGION="${RESOLVED_REGION}"
print_info "Region: ${REGION}"

#-------------------------------------------------------------------------------
# AWS account ID
#-------------------------------------------------------------------------------
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    print_info "Resolving AWS account ID..."
    if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
        print_fail "Failed to get AWS account ID (aws sts get-caller-identity)"
        exit 1
    fi
fi
print_pass "AWS account: ${AWS_ACCOUNT_ID}"

#-------------------------------------------------------------------------------
# ECR URI
#-------------------------------------------------------------------------------
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"
print_info "ECR URI: ${ECR_URI}"

#-------------------------------------------------------------------------------
# Helper: run or echo command in dry-run mode
#-------------------------------------------------------------------------------
run() {
    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
print_info "Running pre-flight checks..."

# Docker
if ! command -v docker &>/dev/null; then
    print_fail "docker not found — install Docker Desktop or Docker CLI"
    exit 1
fi
print_pass "docker available"

# AWS CLI
if ! command -v aws &>/dev/null; then
    print_fail "aws CLI not found — install AWS CLI v2"
    exit 1
fi
print_pass "aws CLI available"

# Source directories exist
for dir in \
    "${REPO_ROOT}/applications/banking-app/ui" \
    "${REPO_ROOT}/applications/banking-app/agent" \
    "${REPO_ROOT}/applications/banking-app/mcp-server"; do
    if [ ! -d "${dir}" ]; then
        print_fail "Source directory missing: ${dir}"
        exit 1
    fi
done
print_pass "All 3 service source directories present"

#-------------------------------------------------------------------------------
# Verify ECR repository exists (created by Terraform)
#-------------------------------------------------------------------------------
print_info "Verifying ECR repository ${ECR_REPO_NAME} exists (created by Terraform)..."

if run aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --output text &>/dev/null; then
    print_pass "ECR repository exists: ${ECR_REPO_NAME}"
else
    print_fail "ECR repository not found: ${ECR_REPO_NAME}. Run 'terraform apply' first."
    exit 1
fi

#-------------------------------------------------------------------------------
# ECR login
#-------------------------------------------------------------------------------
print_info "Authenticating Docker to ECR..."
if ! run aws ecr get-login-password --region "${REGION}" | \
    run docker login \
        --username AWS \
        --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"; then
    print_fail "ECR login failed"
    exit 1
fi
print_pass "ECR login successful"

#-------------------------------------------------------------------------------
# Build and push images
#-------------------------------------------------------------------------------

build_and_push() {
    local tag="$1"
    local context_dir="$2"
    local dockerfile="${context_dir}/Dockerfile"
    local image_uri="${ECR_URI}:${tag}"

    print_info "Building ${tag}..."

    if [ ! -f "${dockerfile}" ]; then
        print_fail "Dockerfile not found: ${dockerfile}"
        return 1
    fi

    if run docker buildx build \
        --platform linux/amd64 \
        --no-cache \
        --load \
        --tag "${image_uri}" \
        --file "${dockerfile}" \
        "${context_dir}"; then
        print_pass "Built ${image_uri}"
    else
        print_fail "docker build failed for ${tag}"
        return 1
    fi

    print_info "Pushing ${tag}..."
    if run docker push "${image_uri}"; then
        print_pass "Pushed ${image_uri}"
    else
        print_fail "docker push failed for ${tag}"
        return 1
    fi

    return 0
}

build_and_push "ui"    "${REPO_ROOT}/applications/banking-app/ui"
build_and_push "agent" "${REPO_ROOT}/applications/banking-app/agent"

# MCP server: compile TypeScript on host (tsc OOMs under QEMU emulation on ARM Macs)
print_info "Compiling MCP server TypeScript on host..."
mcp_dir="${REPO_ROOT}/applications/banking-app/mcp-server"
(cd "$mcp_dir" && npm ci --silent 2>/dev/null && npm run build) || {
    print_fail "MCP server TypeScript compilation failed"
    exit 1
}
print_pass "MCP server compiled to dist/"
build_and_push "mcp"   "$mcp_dir"

# Summary is printed automatically by the common-checks.sh EXIT trap

if [ ${#FAILURES[@]} -gt 0 ]; then
    exit 1
fi

echo ""
print_pass "All 3 banking app images built and pushed"
echo ""
echo "  ${ECR_URI}:ui"
echo "  ${ECR_URI}:agent"
echo "  ${ECR_URI}:mcp"
echo ""
print_info "Set these in infrastructure/terraform.tfvars:"
echo "  banking_ui_image    = \"${ECR_URI}:ui\""
echo "  banking_agent_image = \"${ECR_URI}:agent\""
echo "  banking_mcp_image   = \"${ECR_URI}:mcp\""
