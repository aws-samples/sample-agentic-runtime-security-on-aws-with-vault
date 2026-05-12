#!/usr/bin/env bash
#===============================================================================
# Workshop Bootstrap Script
#
# Single-command bootstrap for the Agentic Runtime Security workshop.
# All steps are idempotent — safe to re-run.
#
# Steps:
#   0. Detect HCP free tier (FAIL if free; workshop requires Standard tier)
#   1. Ensure EC2 Spot service-linked role
#   2. Resolve admin principal ARN (assumed-role → IAM role rewrite)
#   3. Write hcp-setup/terraform.tfvars (sensitive vars only)
#   4. Run terraform init + apply in hcp-setup (creates project + variable set)
#   5. Create HCP Terraform Workspace (local execution, state-only)
#   6. Generate infrastructure/terraform.tfvars + terraform init
#   7. Print success summary
#
# Usage:
#   ./bootstrap.sh <HCP_ORG> [OPTIONS]
#
# Arguments:
#   HCP_ORG                  HCP Terraform organization name (required)
#
# Options:
#   --project NAME           HCP project name (default: "Agentic Runtime Security")
#   --varset-name NAME       Variable set name (default: "agentic-runtime-stacks-config")
#   --workspace NAME         HCP workspace name (default: "agentic-runtime-security")
#   --dry-run                Show what would be done without executing
#   --skip-prereq-gate       Skip the "Have you run check-prerequisites.sh?" prompt
#   --help                   Show this help message
#
# Prerequisites (run check-prerequisites.sh first):
#   - terraform CLI authenticated (terraform login)
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
TFE_API="https://app.terraform.io/api/v2"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
HCP_ORG=""
HCP_PROJECT="Agentic Runtime Security"
VARSET_NAME="agentic-runtime-stacks-config"
WORKSPACE_NAME="agentic-runtime-security"
DRY_RUN=false
SKIP_PREREQ_GATE=false

usage() {
    cat <<USAGE

Usage: $0 <HCP_ORG> [OPTIONS]

Bootstrap the Agentic Runtime Security workshop environment.

Arguments:
  HCP_ORG                  HCP Terraform organization name (required)

Options:
  --project NAME           HCP project name (default: "Agentic Runtime Security")
  --varset-name NAME       Variable set name (default: "agentic-runtime-stacks-config")
  --workspace NAME         HCP workspace name (default: "agentic-runtime-security")
  --dry-run                Show what would be done without executing
  --skip-prereq-gate       Skip the "Have you run check-prerequisites.sh?" prompt
  --help                   Show this help message

Examples:
  $0 my-org
  $0 my-org --dry-run

USAGE
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
POSITIONAL_SET=false
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --project)      shift; HCP_PROJECT="${1:?--project requires a value}" ;;
        --varset-name)  shift; VARSET_NAME="${1:?--varset-name requires a value}" ;;
        --workspace)    shift; WORKSPACE_NAME="${1:?--workspace requires a value}" ;;
        --dry-run)      DRY_RUN=true ;;
        --skip-prereq-gate) SKIP_PREREQ_GATE=true ;;
        -*) echo -e "${RED}Error: Unknown option: $1${NC}"; usage; exit 1 ;;
        *)
            if [ "$POSITIONAL_SET" = false ]; then
                HCP_ORG="$1"
                POSITIONAL_SET=true
            else
                echo -e "${RED}Error: Unexpected argument: $1${NC}"
                usage; exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$HCP_ORG" ]; then
    echo -e "${RED}Error: HCP_ORG is required${NC}"
    usage
    exit 1
fi

step_header() {
    echo
    echo -e "${BLUE}--- Step $1: $2 ---${NC}"
}

#-------------------------------------------------------------------------------
# Resolve TFE_TOKEN from credentials file
#-------------------------------------------------------------------------------
load_tfe_token() {
    if [ -n "${TFE_TOKEN:-}" ]; then return 0; fi
    if [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
        TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' \
            "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null)
        export TFE_TOKEN
    fi
}

#===============================================================================
# STEP 0: Detect HCP free tier
#===============================================================================
step_detect_free_tier() {
    step_header "0/7" "Detect HCP Terraform Subscription Tier"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would query HCP API for org '$HCP_ORG' subscription plan${NC}"
        return 0
    fi

    load_tfe_token
    if [ -z "${TFE_TOKEN:-}" ]; then
        echo -e "${RED}Error: TFE_TOKEN not available — cannot query HCP API${NC}"
        echo -e "${YELLOW}Fix: run 'terraform login' to populate ~/.terraform.d/credentials.tfrc.json${NC}"
        exit 1
    fi

    local org_resp
    org_resp=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$HCP_ORG" 2>/dev/null)

    local plan_name
    plan_name=$(echo "$org_resp" | jq -r '.data.attributes."subscription"."plan-name" // ""' 2>/dev/null)

    if [ -z "$plan_name" ] || [ "$plan_name" = "null" ]; then
        echo -e "${YELLOW}Warning: Could not detect subscription plan — proceeding${NC}"
        return 0
    fi

    case "$plan_name" in
        free|trial|starter|developer)
            echo -e "${RED}Error: HCP Terraform plan is '$plan_name' — workshop requires Standard tier${NC}"
            echo -e "${YELLOW}Fix: upgrade at https://app.terraform.io/app/${HCP_ORG}/settings/billing${NC}"
            exit 1
            ;;
        *)
            echo -e "${GREEN}OK: HCP plan detected: $plan_name${NC}"
            ;;
    esac
}

#===============================================================================
# STEP 1: Ensure EC2 Spot Service-Linked Role
#===============================================================================
step_spot_slr() {
    step_header "1/7" "Ensure EC2 Spot Service-Linked Role"

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
    step_header "2/7" "Resolve Admin Principal ARN"

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
# STEP 3: Write hcp-setup/terraform.tfvars (sensitive vars only)
#===============================================================================
step_write_hcp_tfvars() {
    step_header "3/7" "Write hcp-setup/terraform.tfvars"

    local TFVARS_FILE="$SCRIPT_DIR/hcp-setup/terraform.tfvars"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would write $TFVARS_FILE${NC}"
        return 0
    fi

    cat > "$TFVARS_FILE" <<TFVARS
hcp_org              = "$HCP_ORG"
aws_account_id       = "$AWS_ACCOUNT_ID"
project_name         = "$HCP_PROJECT"
varset_name          = "$VARSET_NAME"
icr_entitlement_key  = "${ICR_ENTITLEMENT_KEY:-}"
simple_ad_admin_password = "${SIMPLE_AD_ADMIN_PASSWORD:-WorkshopAdmin1!}"
TFVARS
    echo -e "${GREEN}OK: Written: $TFVARS_FILE${NC}"
}

#===============================================================================
# STEP 4: terraform init + apply in hcp-setup
#===============================================================================
step_terraform_apply() {
    step_header "4/7" "Terraform init + apply (HCP project + variable set)"

    local HCP_SETUP_DIR="$SCRIPT_DIR/hcp-setup"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would run: terraform -chdir=$HCP_SETUP_DIR init && apply -auto-approve${NC}"
        return 0
    fi

    echo -e "${YELLOW}Running terraform init...${NC}"
    terraform -chdir="$HCP_SETUP_DIR" init -input=false

    echo
    echo -e "${YELLOW}Running terraform apply...${NC}"
    terraform -chdir="$HCP_SETUP_DIR" apply -auto-approve -input=false
}

#===============================================================================
# STEP 5: Create HCP Terraform Workspace (local execution, no VCS)
#===============================================================================
step_create_workspace() {
    step_header "5/7" "Create HCP Terraform Workspace (local execution)"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would create workspace '$WORKSPACE_NAME' (local execution)${NC}"
        return 0
    fi

    load_tfe_token
    if [ -z "${TFE_TOKEN:-}" ]; then
        echo -e "${RED}Error: TFE_TOKEN not available — cannot create Workspace${NC}"
        echo -e "${YELLOW}Fix: run 'terraform login' first${NC}"
        return 1
    fi

    local project_id
    project_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw project_id 2>/dev/null)
    if [ -z "$project_id" ]; then
        echo -e "${RED}Error: Could not resolve project_id from terraform output${NC}"
        return 1
    fi

    # Check if workspace exists
    echo -e "${BLUE}  Checking workspace '$WORKSPACE_NAME'...${NC}"
    local ws_check_resp ws_check_code ws_existing_id
    ws_check_resp=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$HCP_ORG/workspaces/$WORKSPACE_NAME" 2>/dev/null)
    ws_check_code=$(echo "$ws_check_resp" | tail -1)
    ws_existing_id=$(echo "$ws_check_resp" | sed '$d' | jq -r '.data.id // empty' 2>/dev/null)

    if [ "$ws_check_code" = "200" ] && [ -n "$ws_existing_id" ]; then
        echo -e "${GREEN}OK: Workspace '$WORKSPACE_NAME' already exists (id=${ws_existing_id})${NC}"

        # Ensure execution mode is local
        local current_mode
        current_mode=$(echo "$ws_check_resp" | sed '$d' | jq -r '.data.attributes."execution-mode" // "remote"' 2>/dev/null)
        if [ "$current_mode" != "local" ]; then
            echo -e "${YELLOW}  Updating execution mode from '$current_mode' to 'local'...${NC}"
            curl -s -X PATCH \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                -d '{"data":{"type":"workspaces","attributes":{"execution-mode":"local"}}}' \
                "$TFE_API/workspaces/$ws_existing_id" >/dev/null 2>&1
            echo -e "${GREEN}OK: Execution mode set to local${NC}"
        fi
    else
        echo -e "${BLUE}  Exec mode:   local${NC}"

        local create_payload
        create_payload=$(jq -n \
            --arg name "$WORKSPACE_NAME" \
            --arg project_id "$project_id" \
            '{
                data: {
                    type: "workspaces",
                    attributes: {
                        name: $name,
                        description: "Agentic Runtime Security on AWS — local execution, HCP state backend",
                        "execution-mode": "local",
                        "auto-apply": false
                    },
                    relationships: {
                        project: { data: { type: "projects", id: $project_id } }
                    }
                }
            }')

        local resp http_code body
        resp=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d "$create_payload" \
            "$TFE_API/organizations/$HCP_ORG/workspaces" 2>/dev/null)
        http_code=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')

        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            local ws_id
            ws_id=$(echo "$body" | jq -r '.data.id // empty')
            echo -e "${GREEN}OK: Workspace created (id=${ws_id})${NC}"
        else
            local err
            err=$(echo "$body" | jq -r '.errors[0].detail // .errors[0].title // empty')
            echo -e "${RED}Error: Workspace creation failed (HTTP $http_code): $err${NC}"
            return 1
        fi
    fi

    # Assign variable set to workspace
    local varset_id
    varset_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw varset_id 2>/dev/null)
    if [ -n "$varset_id" ]; then
        echo -e "${BLUE}  Assigning variable set to workspace...${NC}"
        local ws_id_for_varset="${ws_existing_id:-$ws_id}"
        curl -s -X POST \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d "$(jq -n --arg wsid "$ws_id_for_varset" '{data:[{type:"workspaces",id:$wsid}]}')" \
            "$TFE_API/varsets/$varset_id/relationships/workspaces" >/dev/null 2>&1 || true
        echo -e "${GREEN}OK: Variable set assigned${NC}"
    fi
}

#===============================================================================
# STEP 6: Generate infrastructure/terraform.tfvars + terraform init
#===============================================================================
step_generate_tfvars_and_init() {
    step_header "6/7" "Generate terraform.tfvars + terraform init"

    local TFVARS_FILE="$PROJECT_ROOT/infrastructure/terraform.tfvars"
    local TFVARS_EXAMPLE="$PROJECT_ROOT/infrastructure/terraform.tfvars.example"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would generate $TFVARS_FILE from .example${NC}"
        echo -e "${YELLOW}[DRY-RUN] Would run: TF_CLOUD_ORGANIZATION=$HCP_ORG terraform init${NC}"
        return 0
    fi

    if [ -f "$TFVARS_FILE" ]; then
        echo -e "${GREEN}OK: $TFVARS_FILE already exists — updating admin_principal_arn${NC}"
        sed -i.bak "s|admin_principal_arn[[:space:]]*=.*|admin_principal_arn = \"${ADMIN_PRINCIPAL_ARN}\"|" "$TFVARS_FILE"
        rm -f "${TFVARS_FILE}.bak"
    elif [ -f "$TFVARS_EXAMPLE" ]; then
        echo -e "${BLUE}  Copying terraform.tfvars.example → terraform.tfvars${NC}"
        cp "$TFVARS_EXAMPLE" "$TFVARS_FILE"
        sed -i.bak "s|admin_principal_arn[[:space:]]*=.*|admin_principal_arn = \"${ADMIN_PRINCIPAL_ARN}\"|" "$TFVARS_FILE"
        rm -f "${TFVARS_FILE}.bak"
        echo -e "${GREEN}OK: Generated $TFVARS_FILE${NC}"
    else
        echo -e "${RED}Error: Neither terraform.tfvars nor terraform.tfvars.example found${NC}"
        return 1
    fi

    echo -e "${BLUE}  Running terraform init (connecting to HCP workspace for state)...${NC}"
    export TF_CLOUD_ORGANIZATION="$HCP_ORG"
    terraform -chdir="$PROJECT_ROOT/infrastructure" init -input=false
    echo -e "${GREEN}OK: terraform init complete — state backend connected${NC}"
}

#===============================================================================
# STEP 7: Success Summary
#===============================================================================
step_summary() {
    step_header "7/7" "Summary"
    echo
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "${GREEN} Bootstrap Complete${NC}"
    echo -e "${GREEN}===============================================================================${NC}"
    echo
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] No changes were made.${NC}"
        echo
    fi
    echo -e "  Organization:  ${YELLOW}$HCP_ORG${NC}"
    echo -e "  Project:       ${YELLOW}$HCP_PROJECT${NC}"
    echo -e "  Variable Set:  ${YELLOW}$VARSET_NAME${NC}"
    echo -e "  Workspace:     ${YELLOW}$WORKSPACE_NAME${NC}"
    echo -e "  Exec Mode:     ${YELLOW}local${NC}"
    echo
    echo -e "${GREEN}What was created (or verified idempotently):${NC}"
    echo -e "  - EC2 Spot Service-Linked Role"
    echo -e "  - HCP project '$HCP_PROJECT'"
    echo -e "  - Variable set '$VARSET_NAME' (sensitive vars only)"
    echo -e "  - HCP Workspace '$WORKSPACE_NAME' (local execution, state-only)"
    echo -e "  - infrastructure/terraform.tfvars (from .example template)"
    echo
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "  1. Review terraform.tfvars: ${BLUE}${PROJECT_ROOT}/infrastructure/terraform.tfvars${NC}"
    echo -e "  2. Deploy: ${BLUE}cd infrastructure && TF_CLOUD_ORGANIZATION=$HCP_ORG terraform apply${NC}"
    echo -e "  3. Or run the full e2e: ${BLUE}./infrastructure/scripts/workshop-e2e.sh $HCP_ORG --skip-teardown${NC}"
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
echo -e "  Organization:  ${YELLOW}$HCP_ORG${NC}"
echo -e "  Project:       ${YELLOW}$HCP_PROJECT${NC}"
echo -e "  Workspace:     ${YELLOW}$WORKSPACE_NAME${NC}"
echo -e "  Exec Mode:     ${YELLOW}local${NC}"
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

step_detect_free_tier
step_spot_slr
step_get_admin_arn
step_write_hcp_tfvars
step_terraform_apply
step_create_workspace
step_generate_tfvars_and_init
step_summary
