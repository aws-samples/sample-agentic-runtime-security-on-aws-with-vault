#!/usr/bin/env bash
#===============================================================================
# build-uc3-agent.sh — Build and push UC3 privileged-action agent image to ECR
#
# Builds the UC3 Strands agent Docker image and pushes it to ECR:
#   workshop/uc3-agent:latest — Python Strands agent (python:3.12-slim, port 8080)
#
# All images built with --platform linux/amd64 (EKS nodes are x86_64;
# attendees may build from ARM Macs — this flag prevents silent architecture
# mismatches).
#
# Usage:
#   ./build-uc3-agent.sh [--help] [--dry-run] [--region <region>]
#
# Env-var overrides:
#   WORKSHOP_REGION  — AWS region (overridden by --region flag or resolve-region.sh)
#   ECR_REPO_NAME    — ECR repository name (default: workshop/uc3-agent)
#   AWS_ACCOUNT_ID   — AWS account ID (auto-resolved via sts get-caller-identity)
#
# Design:
#   - Idempotent: creates ECR repo if not exists, re-pushes image safely
#   - Self-verifying: print_pass / print_fail per check
#   - No hardcoded region strings (canonical-region contract)
#   - Sources common-checks.sh for consistent attendee output
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC2034  # read by sourced common-checks.sh (suppresses its EXIT-trap summary)
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"
# shellcheck source=resolve-region.sh
source "${SCRIPT_DIR}/resolve-region.sh"

ECR_REPO_NAME="${ECR_REPO_NAME:-workshop/uc3-agent}"
IMAGE_TAG="latest"
AGENT_DIR="${REPO_ROOT}/applications/uc3-agent"
DRY_RUN=false
CLI_REGION=""

#-------------------------------------------------------------------------------
# Parse arguments
#-------------------------------------------------------------------------------

usage() {
    cat <<EOF
build-uc3-agent.sh — UC3 Privileged-Action Agent ECR build+push

Usage:
  ./build-uc3-agent.sh [--help] [--dry-run] [--region <region>]

Options:
  --help          Show this help message
  --dry-run       Show commands without executing (skips Docker build and push)
  --region VALUE  Override AWS region (default: auto-resolved)

Environment variables:
  WORKSHOP_REGION  AWS region override
  ECR_REPO_NAME    ECR repository name (default: workshop/uc3-agent)
  AWS_ACCOUNT_ID   AWS account ID (auto-resolved if not set)

Image built:
  workshop/uc3-agent:latest  Python Strands agent (python:3.12-slim, port 8080)

Built with --platform linux/amd64 (EKS x86_64 compatibility).

Examples:
  # Build and push the UC3 agent image
  ./build-uc3-agent.sh

  # Preview commands without executing
  ./build-uc3-agent.sh --dry-run

  # Specify region explicitly
  ./build-uc3-agent.sh --region us-west-2
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --region)
            CLI_REGION="${2:?--region requires a value}"
            shift 2
            ;;
        *)  print_fail "Unknown option: $1. Use --help for usage."; exit 1 ;;
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
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    print_info "Resolving AWS account ID..."
    if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
        print_fail "Failed to get AWS account ID (aws sts get-caller-identity)"
        exit 1
    fi
fi
print_pass "AWS account: ${AWS_ACCOUNT_ID}"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"
print_info "ECR URI: ${ECR_URI}"

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
print_info "Running pre-flight checks..."

detect_container_runtime || exit 1

command -v aws &>/dev/null || { print_fail "aws CLI not found — install AWS CLI v2"; exit 1; }
print_pass "aws CLI available"

[[ -d "${AGENT_DIR}" ]] || { print_fail "UC3 agent source missing: ${AGENT_DIR}"; exit 1; }
[[ -f "${AGENT_DIR}/Dockerfile" ]] || { print_fail "Dockerfile missing: ${AGENT_DIR}/Dockerfile"; exit 1; }
[[ -f "${AGENT_DIR}/requirements.txt" ]] || { print_fail "requirements.txt missing: ${AGENT_DIR}/requirements.txt"; exit 1; }
[[ -d "${AGENT_DIR}/app" ]] || { print_fail "app/ directory missing: ${AGENT_DIR}/app"; exit 1; }
print_pass "UC3 agent source + Dockerfile present"

#-------------------------------------------------------------------------------
# Verify ECR repository exists (created by Terraform)
#-------------------------------------------------------------------------------
print_info "Verifying ECR repository ${ECR_REPO_NAME} exists (created by Terraform)..."

if aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --output text &>/dev/null; then
    print_pass "ECR repository exists: ${ECR_REPO_NAME}"
else
    print_fail "ECR repository not found: ${ECR_REPO_NAME}. Run 'terraform apply' first."; exit 1
fi

#-------------------------------------------------------------------------------
# Dry-run: show commands and exit
#-------------------------------------------------------------------------------
if [[ "${DRY_RUN}" == true ]]; then
    print_info "[DRY-RUN] Would authenticate to ECR: aws ecr get-login-password | ${WORKSHOP_CONTAINER_CLI} login"
    print_info "[DRY-RUN] Would build:"
    print_info "  container_build --platform linux/amd64 --no-cache --tag ${ECR_URI} ${AGENT_DIR}"
    print_info "[DRY-RUN] Would push: ${WORKSHOP_CONTAINER_CLI} push ${ECR_URI}"
    echo ""
    print_pass "UC3 agent image build+push (dry-run)"
    echo ""
    echo "  ${ECR_URI}"
    echo ""
    print_info "Set in infrastructure/terraform.tfvars:"
    echo "  uc3_agent_image = \"${ECR_URI}\""
    exit 0
fi

#-------------------------------------------------------------------------------
# ECR login
#-------------------------------------------------------------------------------
print_info "Authenticating ${WORKSHOP_CONTAINER_CLI} to ECR..."
aws ecr get-login-password --region "${REGION}" | \
    "${WORKSHOP_CONTAINER_CLI}" login \
        --username AWS \
        --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null 2>&1 || {
    print_fail "ECR login failed"
    exit 1
}
print_pass "ECR login successful"

#-------------------------------------------------------------------------------
# Build
#-------------------------------------------------------------------------------
print_info "Building uc3-agent (--platform linux/amd64, --no-cache)..."
# --no-cache: always rebuild every layer so source/dep changes can never be
# masked by a stale Docker layer cache. Paired with the deployment's
# imagePullPolicy: Always so the cluster always pulls the freshly pushed :latest.
container_build \
    --platform linux/amd64 \
    --no-cache \
    --tag "${ECR_URI}" \
    --file "${AGENT_DIR}/Dockerfile" \
    "${AGENT_DIR}" || {
    print_fail "container build failed for uc3-agent"
    exit 1
}
print_pass "Built ${ECR_URI}"

#-------------------------------------------------------------------------------
# Push
#-------------------------------------------------------------------------------
print_info "Pushing uc3-agent..."
"${WORKSHOP_CONTAINER_CLI}" push "${ECR_URI}" || {
    print_fail "image push failed for uc3-agent"
    exit 1
}
print_pass "Pushed ${ECR_URI}"

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo ""
print_pass "UC3 agent image built and pushed"
echo ""
echo "  ${ECR_URI}"
echo ""
print_info "Set in infrastructure/terraform.tfvars:"
echo "  uc3_agent_image = \"${ECR_URI}\""
