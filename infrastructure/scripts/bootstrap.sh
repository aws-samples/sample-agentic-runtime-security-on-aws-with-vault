#!/usr/bin/env bash
#===============================================================================
# Workshop Bootstrap Script (PREF-04)
#
# Single-command bootstrap that orchestrates the full Agentic Runtime Security
# workshop setup (1 prereq-gate prompt + 8 steps, all idempotent — safe to re-run).
#
# Adapted from ~/git-repos/eks-terraform-stacks/infrastructure/scripts/bootstrap.sh
# (the canonical pattern source). Workshop-specific edits:
#   - STACK_NAME defaults to "agentic-runtime-security" (single deployment "usw2",
#     no region suffix per CONTEXT.md decision: single region us-west-2)
#   - VARSET_NAME defaults to "agentic-runtime-security-config"
#   - HCP_PROJECT defaults to "Agentic Runtime Security"
#   - Step 0 detects HCP free tier (Pitfall §2 — free tier EOL 2026-03-31)
#   - Prereq gate at top of main flow asks "Have you run ./preflight.sh and seen
#     all checks pass? [y/N]" — replaces the old inline IAM verification
#     (plan 01-08 closure of UAT Gap 2/3). preflight.sh is the single
#     pre-flight surface; bootstrap.sh trusts the attendee's confirmation.
#
# Steps:
#   0. Detect HCP free tier (FAIL if free; workshop requires Standard tier)
#   1. Create AWS OIDC provider + IAM role for Stacks
#   2. Ensure EC2 Spot service-linked role
#   3. Resolve admin principal ARN (assumed-role → IAM role rewrite)
#   4. Write hcp-setup/terraform.tfvars from current environment
#   5. Run terraform init + apply in hcp-setup (creates project + variable set)
#   6. Create the HCP Terraform Stack via the HCP API + assign variable set
#   7. Print success summary with next steps
#
# Usage:
#   ./bootstrap.sh <HCP_ORG> [OPTIONS]
#
# Arguments:
#   HCP_ORG                  HCP Terraform organization name (required)
#
# Options:
#   --project NAME           HCP project name (default: "Agentic Runtime Security")
#   --varset-name NAME       Variable set name (default: "agentic-runtime-security-config")
#   --stack-name NAME        HCP Stack name (default: "agentic-runtime-security")
#   --branch NAME            Git branch for VCS connection (default: repo default)
#   --dry-run                Show what would be done without executing
#   --help                   Show this help message
#
# Prerequisites (run preflight.sh first):
#   - terraform CLI authenticated (terraform login)
#   - aws CLI configured (aws configure / AWS_PROFILE / AWS SSO)
#   - jq, curl, git installed
#===============================================================================

set -e

export AWS_PAGER=""

#-------------------------------------------------------------------------------
# Color constants (this script does NOT source common-checks.sh because it
# uses set -e, and we want fail-fast on bootstrap errors, not accumulate-then-
# summarize semantics)
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKING_DIR="infrastructure"
TFE_API="https://app.terraform.io/api/v2"

#-------------------------------------------------------------------------------
# Defaults (workshop-specific per CONTEXT.md)
#-------------------------------------------------------------------------------
HCP_ORG=""
HCP_PROJECT="Agentic Runtime Security"
VARSET_NAME="agentic-runtime-security-config"
STACK_NAME="agentic-runtime-security"
STACK_BRANCH=""
DRY_RUN=false

usage() {
    cat <<USAGE

Usage: $0 <HCP_ORG> [OPTIONS]

Bootstrap the Agentic Runtime Security workshop environment.

Arguments:
  HCP_ORG                  HCP Terraform organization name (required)

Options:
  --project NAME           HCP project name (default: "Agentic Runtime Security")
  --varset-name NAME       Variable set name (default: "agentic-runtime-security-config")
  --stack-name NAME        HCP Stack name (default: "agentic-runtime-security")
  --branch NAME            Git branch for VCS connection (default: repo default)
  --dry-run                Show what would be done without executing
  --help                   Show this help message

Examples:
  $0 my-org
  $0 my-org --project "Agentic Runtime Security" --dry-run

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
        --stack-name)   shift; STACK_NAME="${1:?--stack-name requires a value}" ;;
        --branch)       shift; STACK_BRANCH="${1:?--branch requires a value}" ;;
        --dry-run)      DRY_RUN=true ;;
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
# Resolve TFE_TOKEN from credentials file (used by Steps 0 + 7)
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
# STEP 0: Detect HCP free tier (Pitfall §2)
#
# HCP Terraform free tier was deprecated 2026-03-31. The workshop requires
# Standard (or higher) tier so its Stacks deployments and large variable sets
# fit within plan limits. FAIL if the org is on a free / starter / trial plan.
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

    # The TFE API exposes the plan name under attributes."subscription".plan-name
    # (free / standard / plus / premium). On orgs without subscription metadata
    # the field may be empty; treat empty as a soft warning.
    local plan_name
    plan_name=$(echo "$org_resp" | jq -r '.data.attributes."subscription"."plan-name" // ""' 2>/dev/null)

    if [ -z "$plan_name" ] || [ "$plan_name" = "null" ]; then
        echo -e "${YELLOW}⚠ Could not detect subscription plan — proceeding (verify Standard tier manually at https://app.terraform.io/app/${HCP_ORG}/settings/billing)${NC}"
        return 0
    fi

    case "$plan_name" in
        free|trial|starter|developer)
            echo -e "${RED}✗ HCP Terraform plan is '$plan_name' — workshop requires Standard tier (free tier EOL 2026-03-31)${NC}"
            echo -e "${YELLOW}Fix: upgrade to Standard at https://app.terraform.io/app/${HCP_ORG}/settings/billing${NC}"
            exit 1
            ;;
        *)
            echo -e "${GREEN}✓ HCP plan detected: $plan_name${NC}"
            ;;
    esac
}

#===============================================================================
# NOTE: The former Step 1 (inline IAM verification) was REMOVED in plan 01-08.
# The user's locked design: bootstrap.sh now opens with a single prereq-gate
# prompt at the top of main flow asking "Have you run ./preflight.sh and seen
# all checks pass? [y/N]". Workshop attendees follow instructions — no
# defensive re-check needed. preflight.sh is the single pre-flight surface.
# The 8-step orchestration is renumbered 1-7 (formerly 2-8); step headers
# below use the new numbering.
#===============================================================================

#===============================================================================
# STEP 2: Setup AWS OIDC Provider + IAM Role for HCP Stacks
#
# Workshop pedagogical scope = AdministratorAccess (the workshop teaches the
# 5 control objectives at the workload-identity / data-plane layer; we
# explicitly avoid teaching IAM least-privilege design alongside it). For
# production deployments, the scoped policy in setup-aws-oidc.sh of the
# reference repo can be substituted.
#===============================================================================
step_oidc_setup() {
    step_header "1/7" "Setup AWS OIDC Provider + IAM Role"

    local OIDC_PROVIDER="app.terraform.io"
    local AWS_ACCOUNT_ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    local OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    local ROLE_NAME="hcp-stacks-deploy"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would create OIDC provider ${OIDC_PROVIDER} + IAM role '${ROLE_NAME}' with AdministratorAccess${NC}"
        return 0
    fi

    # OIDC provider — create if missing (409 ignored)
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ OIDC provider exists: ${OIDC_ARN}${NC}"
    else
        echo -e "${YELLOW}Creating OIDC provider for ${OIDC_PROVIDER}...${NC}"
        # Fetch root CA thumbprint dynamically (HCP rotates certs)
        local THUMBPRINT
        THUMBPRINT=$(echo | openssl s_client -servername "$OIDC_PROVIDER" -connect "${OIDC_PROVIDER}:443" -showcerts 2>/dev/null \
            | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' \
            | awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; cert=""} {cert=cert"\n"$0} /END CERTIFICATE/{certs[n]=cert} END{print certs[n]}' \
            | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
            | sed 's/://g' | awk -F= '{print tolower($2)}')
        aws iam create-open-id-connect-provider \
            --url "https://${OIDC_PROVIDER}" \
            --client-id-list "aws.workload.identity" \
            --thumbprint-list "$THUMBPRINT" >/dev/null
        echo -e "${GREEN}✓ OIDC provider created${NC}"
    fi

    # Trust policy — restricts to this HCP_ORG + project + workspace
    local TRUST_POLICY
    TRUST_POLICY=$(jq -n \
        --arg oidc "$OIDC_ARN" \
        --arg org "$HCP_ORG" \
        --arg project "$HCP_PROJECT" \
        '{
          Version: "2012-10-17",
          Statement: [{
            Effect: "Allow",
            Principal: {Federated: $oidc},
            Action: "sts:AssumeRoleWithWebIdentity",
            Condition: {
              StringEquals: {
                "app.terraform.io:aud": "aws.workload.identity"
              },
              StringLike: {
                "app.terraform.io:sub": ("organization:" + $org + ":project:" + $project + ":*")
              }
            }
          }]
        }')

    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ IAM role '${ROLE_NAME}' exists — updating trust policy${NC}"
        aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
    else
        echo -e "${YELLOW}Creating IAM role '${ROLE_NAME}'...${NC}"
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --description "HCP Terraform Stacks deploy role for the Agentic Runtime Security workshop" >/dev/null
        echo -e "${GREEN}✓ IAM role created${NC}"
    fi

    # AdministratorAccess for the workshop (pedagogical scope, NOT production)
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" >/dev/null
    echo -e "${GREEN}✓ AdministratorAccess attached (workshop pedagogical scope)${NC}"
}

#===============================================================================
# STEP 3: Ensure EC2 Spot Service-Linked Role
#===============================================================================
step_spot_slr() {
    step_header "2/7" "Ensure EC2 Spot Service-Linked Role"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would check/create AWSServiceRoleForEC2Spot${NC}"
        return 0
    fi

    if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
        echo -e "${GREEN}✓ EC2 Spot SLR exists${NC}"
        return 0
    fi

    if aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ EC2 Spot SLR created${NC}"
    else
        # 409 Conflict (already exists, race condition) — treat as success
        if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
            echo -e "${GREEN}✓ EC2 Spot SLR exists (race-condition recovery)${NC}"
        else
            echo -e "${RED}✗ Failed to create EC2 Spot SLR (need iam:CreateServiceLinkedRole)${NC}"
            exit 1
        fi
    fi
}

#===============================================================================
# STEP 4: Resolve Admin Principal ARN
#
# Identical to reference bootstrap.sh lines 273-304 — assumed-role → IAM role
# rewrite for EKS access entry compatibility.
#===============================================================================
step_get_admin_arn() {
    step_header "3/7" "Resolve Admin Principal ARN"

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
        echo -e "${GREEN}✓ Admin Principal ARN: $ADMIN_PRINCIPAL_ARN${NC}"
        echo -e "${YELLOW}  (rewritten from assumed-role for EKS access entry compatibility)${NC}"
    else
        ADMIN_PRINCIPAL_ARN="$RAW_ARN"
        echo -e "${GREEN}✓ Admin Principal ARN: $ADMIN_PRINCIPAL_ARN${NC}"
    fi
}

#===============================================================================
# STEP 5: Write hcp-setup/terraform.tfvars
#===============================================================================
step_write_tfvars() {
    step_header "4/7" "Write hcp-setup/terraform.tfvars"

    local IAM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/hcp-stacks-deploy"
    local TFVARS_FILE="$SCRIPT_DIR/hcp-setup/terraform.tfvars"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would write $TFVARS_FILE with workshop defaults${NC}"
        return 0
    fi

    cat > "$TFVARS_FILE" <<TFVARS
hcp_org             = "$HCP_ORG"
aws_account_id      = "$AWS_ACCOUNT_ID"
aws_region          = "us-west-2"
iam_role_arn        = "$IAM_ROLE_ARN"
admin_principal_arn = "$ADMIN_PRINCIPAL_ARN"
project_name        = "$HCP_PROJECT"
varset_name         = "$VARSET_NAME"
TFVARS
    echo -e "${GREEN}✓ Written: $TFVARS_FILE${NC}"
}

#===============================================================================
# STEP 6: terraform init + apply in hcp-setup
#===============================================================================
step_terraform_apply() {
    step_header "5/7" "Terraform init + apply (HCP project + variable set)"

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
# STEP 7: Create HCP Terraform Stack + assign variable set
#
# 1) Idempotency check: GET /organizations/$ORG/stacks?filter[name]=$STACK_NAME.
#    Skip if data.length > 0.
# 2) Auto-detect VCS provider (OAuth client OR GitHub App installation).
# 3) Parse repo identifier from `git remote get-url origin`.
# 4) POST /stacks with vcs-repo + working-directory=infrastructure +
#    project relationship.
# 5) Assign variable set to stack: POST /varsets/$VS/relationships/stacks
#    (422 means already assigned — treat as success).
#===============================================================================
step_create_stack() {
    step_header "6/7" "Create HCP Terraform Stack"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would create Stack '$STACK_NAME' with VCS connection${NC}"
        return 0
    fi

    load_tfe_token
    if [ -z "${TFE_TOKEN:-}" ]; then
        echo -e "${RED}TFE_TOKEN not available — cannot create Stack${NC}"
        echo -e "${YELLOW}Fix: run 'terraform login' first${NC}"
        return 1
    fi

    # Resolve project_id and varset_id from terraform output of Step 6
    local project_id
    local varset_id
    project_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw project_id 2>/dev/null)
    varset_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw varset_id 2>/dev/null)

    if [ -z "$project_id" ]; then
        echo -e "${RED}Could not resolve project_id from terraform output${NC}"
        return 1
    fi

    # Idempotency: check if a Stack with this name already exists in the org
    local stack_data existing_stack_id
    stack_data=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$HCP_ORG/stacks" 2>/dev/null)
    existing_stack_id=$(echo "$stack_data" | jq -r --arg n "$STACK_NAME" \
        '.data[] | select(.attributes.name == $n) | .id // empty' 2>/dev/null | head -1)

    local stack_id="$existing_stack_id"
    if [ -n "$existing_stack_id" ]; then
        echo -e "${GREEN}✓ Stack '$STACK_NAME' already exists (id=${existing_stack_id}) — skipping creation${NC}"
    else
        # Detect VCS provider — try OAuth client first, fall back to GitHub App
        local oauth_token_id="" github_app_id=""
        local oauth_data
        oauth_data=$(curl -s \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/organizations/$HCP_ORG/oauth-clients" 2>/dev/null)
        oauth_token_id=$(echo "$oauth_data" | jq -r '
            [.data[] | select(.attributes["service-provider"] == "github")] |
            .[0].relationships["oauth-tokens"].data[0].id // empty
        ' 2>/dev/null)

        if [ -z "$oauth_token_id" ]; then
            local ghapp_data
            ghapp_data=$(curl -s \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/organizations/$HCP_ORG/github-app-installations" 2>/dev/null)
            github_app_id=$(echo "$ghapp_data" | jq -r '.data[0].id // empty' 2>/dev/null)
        fi

        if [ -z "$oauth_token_id" ] && [ -z "$github_app_id" ]; then
            echo -e "${RED}✗ No GitHub VCS connection in org '$HCP_ORG'${NC}"
            echo -e "${YELLOW}Fix: HCP Terraform > Settings > VCS Providers — add GitHub OAuth or GitHub App${NC}"
            return 1
        fi

        # Resolve repo identifier from origin remote
        local git_url repo_identifier repo_http_url
        git_url=$(git -C "$SCRIPT_DIR/../.." remote get-url origin 2>/dev/null) || {
            echo -e "${RED}✗ Could not resolve git origin URL${NC}"
            return 1
        }
        repo_identifier=$(echo "$git_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
        repo_http_url="https://github.com/$repo_identifier"

        echo -e "${BLUE}  Repository: $repo_identifier${NC}"
        echo -e "${BLUE}  Branch:     ${STACK_BRANCH:-<repo default>}${NC}"
        echo -e "${BLUE}  Working dir: $WORKING_DIR${NC}"

        # Build VCS json + create payload
        local vcs_json
        if [ -n "$oauth_token_id" ]; then
            vcs_json=$(jq -n \
                --arg id "$repo_identifier" \
                --arg branch "$STACK_BRANCH" \
                --arg url "$repo_http_url" \
                --arg oauth "$oauth_token_id" \
                '{
                    "identifier": $id,
                    "display-identifier": $id,
                    "branch": $branch,
                    "repository-http-url": $url,
                    "service-provider": "github",
                    "oauth-token-id": $oauth
                }')
        else
            vcs_json=$(jq -n \
                --arg id "$repo_identifier" \
                --arg branch "$STACK_BRANCH" \
                --arg url "$repo_http_url" \
                --arg ghapp "$github_app_id" \
                '{
                    "identifier": $id,
                    "display-identifier": $id,
                    "branch": $branch,
                    "repository-http-url": $url,
                    "service-provider": "github",
                    "github-app-installation-id": $ghapp
                }')
        fi

        local create_payload
        create_payload=$(jq -n \
            --arg name "$STACK_NAME" \
            --arg wd "$WORKING_DIR" \
            --argjson vcs "$vcs_json" \
            --arg project_id "$project_id" \
            '{
                data: {
                    type: "stacks",
                    attributes: {
                        name: $name,
                        description: "Agentic Runtime Security on AWS — Stacks deployment (single region us-west-2)",
                        "working-directory": $wd,
                        "vcs-repo": $vcs
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
            "$TFE_API/stacks" 2>/dev/null)
        http_code=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')

        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            stack_id=$(echo "$body" | jq -r '.data.id // empty')
            echo -e "${GREEN}✓ Stack created (id=${stack_id})${NC}"
        elif [ "$http_code" = "422" ] && echo "$body" | jq -r '.errors[0].detail // empty' | grep -qi already; then
            echo -e "${GREEN}✓ Stack already exists (422 already-exists path)${NC}"
        else
            local err
            err=$(echo "$body" | jq -r '.errors[0].detail // .errors[0].title // empty')
            echo -e "${RED}✗ Stack creation failed (HTTP $http_code): $err${NC}"
            return 1
        fi
    fi

    # Assign variable set to stack
    if [ -z "$stack_id" ] || [ -z "$varset_id" ]; then
        echo -e "${YELLOW}⚠ stack_id or varset_id missing — assign variable set manually in HCP UI${NC}"
        return 0
    fi

    local assign_code
    assign_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        -d "{\"data\":[{\"type\":\"stacks\",\"id\":\"$stack_id\"}]}" \
        "$TFE_API/varsets/$varset_id/relationships/stacks" 2>/dev/null)

    case "$assign_code" in
        200|201|204) echo -e "${GREEN}✓ Variable set assigned to Stack${NC}" ;;
        422)         echo -e "${GREEN}✓ Variable set already assigned to Stack (422)${NC}" ;;
        *)           echo -e "${YELLOW}⚠ Variable set assignment returned HTTP $assign_code — assign manually in HCP UI${NC}" ;;
    esac
}

#===============================================================================
# STEP 8: Success Summary
#===============================================================================
step_summary() {
    step_header "7/7" "Summary"
    echo
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "${GREEN} ✓ Bootstrap Complete${NC}"
    echo -e "${GREEN}===============================================================================${NC}"
    echo
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] No changes were made.${NC}"
        echo
    fi
    echo -e "  Organization:  ${YELLOW}$HCP_ORG${NC}"
    echo -e "  Project:       ${YELLOW}$HCP_PROJECT${NC}"
    echo -e "  Variable Set:  ${YELLOW}$VARSET_NAME${NC}"
    echo -e "  Stack:         ${YELLOW}$STACK_NAME${NC}"
    echo -e "  Region:        ${YELLOW}us-west-2${NC} (single deployment 'usw2')"
    echo
    echo -e "${GREEN}What was created (or verified idempotently):${NC}"
    echo -e "  - AWS OIDC provider for app.terraform.io"
    echo -e "  - IAM role 'hcp-stacks-deploy' with AdministratorAccess (workshop scope)"
    echo -e "  - EC2 Spot Service-Linked Role"
    echo -e "  - HCP project '$HCP_PROJECT'"
    echo -e "  - Variable set '$VARSET_NAME'"
    echo -e "  - HCP Stack '$STACK_NAME' (working dir: $WORKING_DIR)"
    echo
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "  1. Review the Stack: ${BLUE}https://app.terraform.io/app/${HCP_ORG}/stacks${NC}"
    echo -e "  2. Push code to trigger the first plan, then approve to deploy"
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
echo -e "  Variable Set:  ${YELLOW}$VARSET_NAME${NC}"
echo -e "  Stack:         ${YELLOW}$STACK_NAME${NC}"
[ "$DRY_RUN" = true ] && echo -e "  Mode:          ${YELLOW}DRY RUN${NC}"

#-------------------------------------------------------------------------------
# Prereq gate (replaces the former inline Step 1 IAM verification)
#
# Workshop is human-driven: attendees follow instructions. We don't
# defensively re-run preflight here; we just confirm the attendee has run it.
# Skipped in --dry-run mode (no real action, gate is moot).
#-------------------------------------------------------------------------------
if [ "$DRY_RUN" = false ]; then
    echo
    read -p "$(echo -e "${YELLOW}?${NC}") Have you run ./preflight.sh and seen all checks pass? [y/N] " -r preflight_ack < /dev/tty
    if [[ ! "$preflight_ack" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${RED}Run ./preflight.sh first, then return.${NC}"
        exit 1
    fi
    echo
fi

step_detect_free_tier
step_oidc_setup
step_spot_slr
step_get_admin_arn
step_write_tfvars
step_terraform_apply
step_create_stack
step_summary
