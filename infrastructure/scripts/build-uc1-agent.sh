#!/usr/bin/env bash
#===============================================================================
# build-uc1-agent.sh — Build and push UC1 agent image to ECR
#
# Builds the UC1 non-personalized agent Docker image and pushes it to ECR:
#   workshop/uc1-agent:latest — Python Strands agent (python:3.12-slim)
#
# All images built with --platform linux/amd64 (EKS nodes are x86_64;
# attendees may build from ARM Macs).
#
# Usage:
#   ./build-uc1-agent.sh [--help] [--dry-run] [--region <region>]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"
# shellcheck source=resolve-region.sh
source "${SCRIPT_DIR}/resolve-region.sh"

ECR_REPO_NAME="${ECR_REPO_NAME:-workshop/uc1-agent}"
IMAGE_TAG="latest"
AGENT_DIR="${REPO_ROOT}/infrastructure/modules/uc1_agent/agent"
DRY_RUN=false

usage() {
    cat <<EOF
build-uc1-agent.sh — UC1 Agent ECR build+push

Usage:
  ./build-uc1-agent.sh [--help] [--dry-run] [--region <region>]

Options:
  --help          Show this help message
  --dry-run       Show commands without executing
  --region VALUE  Override AWS region (default: auto-resolved)

Image built:
  workshop/uc1-agent:latest  Python Strands agent (python:3.12-slim)

Built with --platform linux/amd64 (EKS x86_64 compatibility).
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --region)
            export WORKSHOP_REGION="${2:?--region requires a value}"
            shift 2
            ;;
        *)  print_fail "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

REGION="${WORKSHOP_REGION:-}"
if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region 2>/dev/null || echo "")
fi
if [[ -z "$REGION" ]]; then
    print_fail "Cannot determine AWS region. Set WORKSHOP_REGION or use --region."; exit 1
fi
print_info "Region: ${REGION}"

print_info "Resolving AWS account ID..."
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
        print_fail "Failed to get AWS account ID"; exit 1
    fi
fi
print_pass "AWS account: ${AWS_ACCOUNT_ID}"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"
print_info "ECR URI: ${ECR_URI}"

print_info "Running pre-flight checks..."
command -v docker &>/dev/null || { print_fail "docker not found"; exit 1; }
print_pass "docker available"
command -v aws &>/dev/null || { print_fail "aws CLI not found"; exit 1; }
print_pass "aws CLI available"
[[ -d "${AGENT_DIR}" ]] || { print_fail "Agent source missing: ${AGENT_DIR}"; exit 1; }
[[ -f "${AGENT_DIR}/Dockerfile" ]] || { print_fail "Dockerfile missing: ${AGENT_DIR}/Dockerfile"; exit 1; }
print_pass "Agent source + Dockerfile present"

print_info "Ensuring ECR repository ${ECR_REPO_NAME} exists..."
if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" --output text &>/dev/null; then
    print_pass "ECR repository exists: ${ECR_REPO_NAME}"
else
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would create ECR repository: ${ECR_REPO_NAME}"
    else
        print_info "Creating ECR repository: ${ECR_REPO_NAME}"
        aws ecr create-repository \
            --repository-name "${ECR_REPO_NAME}" \
            --region "${REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --output text --query "repository.repositoryUri" >/dev/null 2>&1
    fi
    print_pass "ECR repository ready: ${ECR_REPO_NAME}"
fi

if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY-RUN] Would build: docker build --platform linux/amd64 -t ${ECR_URI} ${AGENT_DIR}"
    print_info "[DRY-RUN] Would push: docker push ${ECR_URI}"
    print_pass "UC1 agent image built and pushed (dry-run)"
    echo ""
    echo "  ${ECR_URI}"
    echo ""
    print_info "Set in your Stacks deployment:"
    echo "  uc1_agent_image = \"${ECR_URI}\""
    exit 0
fi

print_info "Authenticating Docker to ECR..."
aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null 2>&1 || {
    print_fail "ECR login failed"; exit 1
}
print_pass "ECR login successful"

print_info "Building uc1-agent (--platform linux/amd64)..."
docker buildx build \
    --platform linux/amd64 \
    --load \
    --tag "${ECR_URI}" \
    --file "${AGENT_DIR}/Dockerfile" \
    "${AGENT_DIR}" || { print_fail "docker build failed"; exit 1; }
print_pass "Built ${ECR_URI}"

print_info "Pushing uc1-agent..."
docker push "${ECR_URI}" || { print_fail "docker push failed"; exit 1; }
print_pass "Pushed ${ECR_URI}"

echo ""
print_pass "UC1 agent image built and pushed"
echo ""
echo "  ${ECR_URI}"
echo ""
print_info "Set in your Stacks deployment:"
echo "  uc1_agent_image = \"${ECR_URI}\""
