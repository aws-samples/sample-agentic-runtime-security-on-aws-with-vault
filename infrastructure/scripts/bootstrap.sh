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
#   --image-source <ghcr|ecr>
#                            Image source mode (default: ghcr). ghcr: no ECR image
#                            URI stamping — GHCR defaults stand. ecr: stamps the five
#                            ECR image URIs into tier-3 tfvars (today's flow).
#                            Env fallback: WORKSHOP_IMAGE_SOURCE.
#   --ghcr-registry-base <base>
#                            GHCR registry base (default: ghcr.io/sharepointoscar).
#                            Persisted to tier-3 tfvars ONLY (tier-1 never receives it).
#                            Env fallback: WORKSHOP_GHCR_REGISTRY_BASE.
#   --help                   Show this help message
#
# Prerequisites (run check-prerequisites.sh first):
#   - aws CLI configured (AWS_PROFILE / env vars / SSO)
#   - jq installed (ecr mode: Docker or Podman also required for build-images.sh)
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
#
# IMAGE_SOURCE resolution order (set -e safe — always bound):
#   1. --image-source flag
#   2. WORKSHOP_IMAGE_SOURCE env var
#   3. Hard default: ghcr
# GHCR_REGISTRY_BASE: --ghcr-registry-base flag → WORKSHOP_GHCR_REGISTRY_BASE env → default
# ghcr.io/sharepointoscar is an image-source URI base, NOT an identity/auth value.
#-------------------------------------------------------------------------------
DRY_RUN=false
SKIP_PREREQ_GATE=false
IMAGE_SOURCE="${WORKSHOP_IMAGE_SOURCE:-ghcr}"
GHCR_REGISTRY_BASE="${WORKSHOP_GHCR_REGISTRY_BASE:-ghcr.io/sharepointoscar}"

usage() {
    cat <<USAGE

Usage: $0 [OPTIONS]

Bootstrap the Agentic Runtime Security workshop environment.

Options:
  --dry-run                Show what would be done without executing
  --skip-prereq-gate       Skip the "Have you run check-prerequisites.sh?" prompt
  --image-source <ghcr|ecr>  Image source mode (default: ghcr)
  --ghcr-registry-base <base> GHCR registry base (default: ghcr.io/sharepointoscar)
  --help                   Show this help message

Examples:
  $0
  $0 --dry-run
  $0 --image-source ecr

USAGE
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --dry-run)           DRY_RUN=true ;;
        --skip-prereq-gate)  SKIP_PREREQ_GATE=true ;;
        --image-source)      IMAGE_SOURCE="$2"; shift ;;
        --ghcr-registry-base) GHCR_REGISTRY_BASE="$2"; shift ;;
        -*) echo -e "${RED}Error: Unknown option: $1${NC}"; usage; exit 1 ;;
        *) echo -e "${RED}Error: Unexpected argument: $1${NC}"; usage; exit 1 ;;
    esac
    shift
done

case "$IMAGE_SOURCE" in
    ghcr|ecr) : ;;
    *) echo -e "${RED}Error: --image-source must be 'ghcr' or 'ecr' (got: '${IMAGE_SOURCE}')${NC}" >&2; exit 1 ;;
esac

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
        echo -e "${YELLOW}[DRY-RUN] Would stamp admin_principal_arn + image_source=${IMAGE_SOURCE} into tier-1 tfvars${NC}"
        echo -e "${YELLOW}[DRY-RUN] Would stamp image_source=${IMAGE_SOURCE} + ghcr_registry_base=${GHCR_REGISTRY_BASE} into tier-3 tfvars${NC}"
        if [ "$IMAGE_SOURCE" = "ecr" ]; then
            echo -e "${YELLOW}[DRY-RUN] Would stamp derived ECR image URIs into tier-3 tfvars (ecr mode)${NC}"
        else
            echo -e "${YELLOW}[DRY-RUN] ECR image URI stamping skipped (ghcr mode — GHCR defaults stand)${NC}"
        fi
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

    # --- tier-1: persist image_source (controls module.ecr count) ---------------
    # image_source is declared in tier-1 (module.ecr count gate) AND tier-3.
    # We persist it here so partial re-runs (deploy-workshop.sh --tier N) hold the
    # mode set at full-run time without requiring the flag to be repeated.
    # ghcr_registry_base is tier-3 ONLY — never written to tier-1 (undeclared var).
    if grep -qE '^[[:space:]]*image_source[[:space:]]*=' "$T1_FILE" 2>/dev/null; then
        sed -i.bak "s|image_source[[:space:]]*=.*|image_source = \"${IMAGE_SOURCE}\"|" "$T1_FILE"
    else
        echo "image_source = \"${IMAGE_SOURCE}\"" >> "$T1_FILE"
    fi
    rm -f "${T1_FILE}.bak"
    echo -e "${GREEN}OK: tier-1 image_source = ${IMAGE_SOURCE}${NC}"

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

    # --- tier-3: persist image_source + ghcr_registry_base ----------------------
    # ghcr_registry_base: tier-3 ONLY (tier-1 does NOT declare it — writing it
    # to tier-1 would set an undeclared var and break the apply; Plan 02 contract).
    local T3_FILE="$TIER3_DIR/terraform.tfvars"
    if [ -f "$T3_FILE" ]; then
        if grep -qE '^[[:space:]]*image_source[[:space:]]*=' "$T3_FILE" 2>/dev/null; then
            sed -i.bak "s|image_source[[:space:]]*=.*|image_source = \"${IMAGE_SOURCE}\"|" "$T3_FILE"
        else
            echo "image_source = \"${IMAGE_SOURCE}\"" >> "$T3_FILE"
        fi
        rm -f "${T3_FILE}.bak"
        echo -e "${GREEN}OK: tier-3 image_source = ${IMAGE_SOURCE}${NC}"

        if grep -qE '^[[:space:]]*ghcr_registry_base[[:space:]]*=' "$T3_FILE" 2>/dev/null; then
            sed -i.bak "s|ghcr_registry_base[[:space:]]*=.*|ghcr_registry_base = \"${GHCR_REGISTRY_BASE}\"|" "$T3_FILE"
        else
            echo "ghcr_registry_base = \"${GHCR_REGISTRY_BASE}\"" >> "$T3_FILE"
        fi
        rm -f "${T3_FILE}.bak"
        echo -e "${GREEN}OK: tier-3 ghcr_registry_base = ${GHCR_REGISTRY_BASE}${NC}"
    fi

    # --- tier-3: stamp the five derived ECR image URIs (ecr mode only) ----------
    # In ghcr mode the GHCR-derived locals in workloads/main.tf stand — no image
    # URI stamping needed. In ecr mode: account ID from Step 2 (live caller identity),
    # region from tier-1 tfvars. Idempotent: placeholders are only filled once;
    # already-real values are left as-is (the grep -q guard is the idempotency gate).
    if [ "$IMAGE_SOURCE" = "ecr" ] && [ -f "$T3_FILE" ]; then
        # Only the image-URI lines carry placeholders; the instructional comment
        # mentions <account>/<region> in prose, so we scope both the check and
        # the substitution to lines containing "dkr.ecr" — never touch comments.
        if grep -E 'dkr\.ecr' "$T3_FILE" | grep -q '<account>\|<region>'; then
            local REGION
            REGION=$(grep -E '^[[:space:]]*region[[:space:]]*=' "$T1_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
            if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$REGION" ]; then
                echo -e "${RED}Error: cannot stamp tier-3 image URIs (account='${AWS_ACCOUNT_ID}', region='${REGION}')${NC}"
                return 1
            fi
            sed -i.bak "/dkr\.ecr/ { s|<account>|${AWS_ACCOUNT_ID}|g; s|<region>|${REGION}|g; }" "$T3_FILE"
            rm -f "${T3_FILE}.bak"
            echo -e "${GREEN}OK: stamped tier-3 ECR image URIs (account ${AWS_ACCOUNT_ID}, region ${REGION})${NC}"
        else
            echo -e "${GREEN}OK: tier-3 image URIs already resolved — leaving as-is${NC}"
        fi
    elif [ "$IMAGE_SOURCE" != "ecr" ]; then
        echo -e "${GREEN}OK: ECR image URI stamping skipped (${IMAGE_SOURCE} mode — GHCR defaults stand)${NC}"
    fi

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
    echo -e "  - admin_principal_arn + image_source=${IMAGE_SOURCE} stamped into tier-1"
    echo -e "  - image_source=${IMAGE_SOURCE} + ghcr_registry_base=${GHCR_REGISTRY_BASE} stamped into tier-3"
    if [ "$IMAGE_SOURCE" = "ecr" ]; then
        echo -e "  - ECR image URIs stamped into tier-3 (ecr mode)"
    else
        echo -e "  - ECR image URI stamping skipped (ghcr mode — GHCR defaults stand)"
    fi
    echo -e "  - terraform init in all 3 roots (local state)"
    echo
    echo -e "${GREEN}Next steps (deploy one tier at a time):${NC}"
    echo -e "  Each tier prompts for the inputs it needs — no manual tfvars edit (Tier 1: Let's Encrypt email · Tier 2: ICR entitlement key + IVIA MMFA secret)."
    echo -e "  1. Core infra (VPC/EKS/RDS/KB):   ${BLUE}./infrastructure/scripts/deploy-workshop.sh --tier 1${NC}"
    echo -e "  2. Vault + IVIA:                  ${BLUE}./infrastructure/scripts/deploy-workshop.sh --tier 2${NC}"
    echo -e "  3. Workloads (Use Cases 1-3):     ${BLUE}./infrastructure/scripts/deploy-workshop.sh --tier 3${NC}"
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
echo -e "  Image source:  ${YELLOW}${IMAGE_SOURCE}${NC}"
if [ "$IMAGE_SOURCE" = "ghcr" ]; then
    echo -e "  GHCR base:     ${YELLOW}${GHCR_REGISTRY_BASE}${NC}"
fi
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
