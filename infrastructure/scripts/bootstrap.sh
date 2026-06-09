#!/usr/bin/env bash
#===============================================================================
# Workshop Bootstrap Script
#
# Single-command bootstrap for the Agentic Runtime Security workshop.
# All steps are idempotent — safe to re-run.
#
# Steps:
#   1. Ensure EC2 Spot service-linked role (AWSServiceRoleForEC2Spot)
#   2. Resolve admin principal ARN (assumed-role → IAM role rewrite)
#   3. Seed terraform.tfvars + terraform init in all 3 roots (tier-1/2/3, local state)
#   4. Print success summary
#
# Usage:
#   ./bootstrap.sh [OPTIONS]
#
# Options:
#   --dry-run                Show what would be done without executing
#   --skip-prereq-gate       Skip the "Have you run check-prerequisites.sh?" prompt
#   --help                   Show this help message
#
# Prerequisites (run check-prerequisites.sh first):
#   - aws CLI configured (AWS_PROFILE / env vars / SSO)
#   - jq installed
#===============================================================================

set -e

export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
DRY_RUN=false
SKIP_PREREQ_GATE=false

usage() {
    cat <<USAGE

Usage: $0 [OPTIONS]

Bootstrap the Agentic Runtime Security workshop environment.

Options:
  --dry-run                Show what would be done without executing
  --skip-prereq-gate       Skip the "Have you run check-prerequisites.sh?" prompt
  --help                   Show this help message

Examples:
  $0
  $0 --dry-run

USAGE
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --dry-run)      DRY_RUN=true ;;
        --skip-prereq-gate) SKIP_PREREQ_GATE=true ;;
        -*) echo -e "${RED}Error: Unknown option: $1${NC}"; usage; exit 1 ;;
        *) echo -e "${RED}Error: Unexpected argument: $1${NC}"; usage; exit 1 ;;
    esac
    shift
done

step_header() {
    echo
    echo -e "${BLUE}--- Step $1: $2 ---${NC}"
}

#===============================================================================
# STEP 1: Ensure EC2 Spot Service-Linked Role
#===============================================================================
step_spot_slr() {
    step_header "1/3" "Ensure EC2 Spot Service-Linked Role"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would check/create AWSServiceRoleForEC2Spot${NC}"
        return 0
    fi

    if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
        echo -e "${GREEN}OK: EC2 Spot SLR exists${NC}"
        return 0
    fi

    if aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null 2>&1; then
        echo -e "${GREEN}OK: EC2 Spot SLR created${NC}"
    else
        if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
            echo -e "${GREEN}OK: EC2 Spot SLR exists (race-condition recovery)${NC}"
        else
            echo -e "${RED}Error: Failed to create EC2 Spot SLR (need iam:CreateServiceLinkedRole)${NC}"
            exit 1
        fi
    fi
}

#===============================================================================
# STEP 2: Resolve Admin Principal ARN
#===============================================================================
step_get_admin_arn() {
    step_header "2/3" "Resolve Admin Principal ARN"

    if [ "$DRY_RUN" = true ]; then
        ADMIN_PRINCIPAL_ARN="arn:aws:iam::123456789012:role/dry-run-placeholder"
        AWS_ACCOUNT_ID="123456789012"
        echo -e "${YELLOW}[DRY-RUN] ADMIN_PRINCIPAL_ARN=$ADMIN_PRINCIPAL_ARN${NC}"
        return 0
    fi

    local RAW_ARN
    RAW_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

    if [[ "$RAW_ARN" == *":assumed-role/"* ]]; then
        local ROLE_NAME
        ROLE_NAME=$(echo "$RAW_ARN" | sed 's|.*assumed-role/\([^/]*\)/.*|\1|')
        ADMIN_PRINCIPAL_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
        echo -e "${GREEN}OK: Admin Principal ARN: $ADMIN_PRINCIPAL_ARN${NC}"
        echo -e "${YELLOW}  (rewritten from assumed-role for EKS access entry compatibility)${NC}"
    else
        ADMIN_PRINCIPAL_ARN="$RAW_ARN"
        echo -e "${GREEN}OK: Admin Principal ARN: $ADMIN_PRINCIPAL_ARN${NC}"
    fi
}

#===============================================================================
# STEP 3: Generate terraform.tfvars (all 3 roots) + terraform init (all 3 roots)
#
# The provisioning order refactor splits the deploy into three local-state roots:
#   tier-1  infrastructure/            core infra (VPC/EKS/RDS/KB/IAM/addons)
#   tier-2  infrastructure/services/   Vault server + IVIA
#   tier-3  infrastructure/workloads/  uc1/uc2/uc3 apps
# Only tier-1 needs admin_principal_arn stamped in. tier-2/tier-3 tfvars carry
# secrets / image URIs the user (or deploy-workshop.sh) fills in later, so
# bootstrap just seeds them from .example when absent and never overwrites.
#===============================================================================
step_generate_tfvars_and_init() {
    step_header "3/3" "Generate terraform.tfvars + terraform init (3 roots)"

    local TIER1_DIR="$PROJECT_ROOT/infrastructure"
    local TIER2_DIR="$PROJECT_ROOT/infrastructure/services"
    local TIER3_DIR="$PROJECT_ROOT/infrastructure/workloads"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would seed terraform.tfvars in tier-1/2/3 from .example${NC}"
        echo -e "${YELLOW}[DRY-RUN] Would stamp admin_principal_arn into tier-1 tfvars${NC}"
        echo -e "${YELLOW}[DRY-RUN] Would run terraform init in all 3 roots${NC}"
        return 0
    fi

    # --- tier-1: seed from .example (if absent) + stamp admin_principal_arn ----
    local T1_FILE="$TIER1_DIR/terraform.tfvars"
    local T1_EXAMPLE="$TIER1_DIR/terraform.tfvars.example"
    if [ -f "$T1_FILE" ]; then
        echo -e "${GREEN}OK: $T1_FILE exists — updating admin_principal_arn${NC}"
    elif [ -f "$T1_EXAMPLE" ]; then
        echo -e "${BLUE}  Copying tier-1 terraform.tfvars.example → terraform.tfvars${NC}"
        cp "$T1_EXAMPLE" "$T1_FILE"
    else
        echo -e "${RED}Error: tier-1 has neither terraform.tfvars nor terraform.tfvars.example${NC}"
        return 1
    fi
    sed -i.bak "s|admin_principal_arn[[:space:]]*=.*|admin_principal_arn = \"${ADMIN_PRINCIPAL_ARN}\"|" "$T1_FILE"
    rm -f "${T1_FILE}.bak"

    # --- tier-2 / tier-3: seed from .example only if absent (never overwrite) --
    local dir
    for dir in "$TIER2_DIR" "$TIER3_DIR"; do
        if [ -f "$dir/terraform.tfvars" ]; then
            echo -e "${GREEN}OK: $dir/terraform.tfvars exists — leaving as-is${NC}"
        elif [ -f "$dir/terraform.tfvars.example" ]; then
            echo -e "${BLUE}  Copying $dir terraform.tfvars.example → terraform.tfvars${NC}"
            cp "$dir/terraform.tfvars.example" "$dir/terraform.tfvars"
        else
            echo -e "${YELLOW}WARN: $dir has no terraform.tfvars.example — skipping seed${NC}"
        fi
    done

    # --- terraform init all 3 roots (bare init, NEVER -upgrade) ---------------
    echo -e "${BLUE}  Running terraform init in all 3 roots (local state)...${NC}"
    terraform -chdir="$TIER1_DIR" init -input=false
    terraform -chdir="$TIER2_DIR" init -input=false
    terraform -chdir="$TIER3_DIR" init -input=false
    echo -e "${GREEN}OK: terraform init complete (tier-1, tier-2, tier-3)${NC}"
}

#===============================================================================
# STEP 4: Success Summary
#===============================================================================
step_summary() {
    step_header "4/4" "Summary"
    echo
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "${GREEN} Bootstrap Complete${NC}"
    echo -e "${GREEN}===============================================================================${NC}"
    echo
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] No changes were made.${NC}"
        echo
    fi
    echo -e "${GREEN}What was created (or verified idempotently):${NC}"
    echo -e "  - EC2 Spot Service-Linked Role"
    echo -e "  - terraform.tfvars in all 3 roots (tier-1/2/3, from .example templates)"
    echo -e "  - terraform init in all 3 roots (local state)"
    echo
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "  1. Fill in secrets/images: ${BLUE}${PROJECT_ROOT}/infrastructure/services/terraform.tfvars${NC} (ICR key)"
    echo -e "  2. Deploy everything: ${BLUE}./infrastructure/scripts/deploy-workshop.sh${NC}"
    echo -e "  3. Or run the full e2e: ${BLUE}./infrastructure/scripts/workshop-e2e.sh --skip-teardown${NC}"
    echo
    echo -e "${GREEN}===============================================================================${NC}"
}

#===============================================================================
# Main flow
#===============================================================================
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE} Agentic Runtime Security — Workshop Bootstrap${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo
[ "$DRY_RUN" = true ] && echo -e "  DRY RUN:       ${YELLOW}yes (no changes will be made)${NC}"

if [ "$DRY_RUN" = false ] && [ "$SKIP_PREREQ_GATE" = false ]; then
    echo
    read -p "$(echo -e "${YELLOW}?${NC}") Have you run ./check-prerequisites.sh and seen all checks pass? [y/N] " -r preflight_ack < /dev/tty
    if [[ ! "$preflight_ack" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${RED}Run ./check-prerequisites.sh first, then return.${NC}"
        exit 1
    fi
    echo
fi

step_spot_slr
step_get_admin_arn
step_generate_tfvars_and_init
step_summary
