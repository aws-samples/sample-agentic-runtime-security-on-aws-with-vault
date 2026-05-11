#!/usr/bin/env bash
#===============================================================================
# Workshop End-to-End Orchestration — Agentic Runtime Security on AWS
#
# Single-command deployment and validation of the entire workshop:
#   Phase 0: Prerequisites (calls check-prerequisites.sh)
#   Phase 1: Bootstrap (calls bootstrap.sh — OIDC + variable set + Stack)
#   Phase 2: Foundation deploy (git push + HCP plan trigger + approve + wait)
#   Phase 3: Configure kubectl (single deployment usw2)
#   Phase 4: Foundation verify (calls test-foundation.sh — EKS + RDS + Bedrock KB)
#   Phase 5: Identity (IVIA) — placeholder, populated when workshop Phase 3 ships
#   Phase 6: Vault — placeholder, populated when workshop Phase 4 ships
#   Phase 7a: Use Case 1 — Non-Personalized Read-Only (ECR build+push, Stacks deploy, verify-uc1.sh)
#   Phase 7b: Use Case 2 — OAuth Personalized Read-Only (placeholder; Phase 5)
#   Phase 7c: Use Case 3 — CIBA Privileged (placeholder; Phase 6)
#   Phase 8: Teardown (calls teardown.sh — unless --skip-teardown)
#
# Usage: ./workshop-e2e.sh <HCP_ORG> [OPTIONS]
#
# Options:
#   --interactive       Pause between phases for manual verification
#   --skip-teardown     Leave deployment running after verification
#   --teardown-only     Skip deployment, run teardown only
#   --nuke              Delete EVERYTHING: AWS resources, OIDC, IAM role,
#                        HCP variable set, AND the HCP Stack itself
#   --cleanup-only      Skip HCP destroy plan — just clean up dangling AWS
#                        resources (ENIs, SGs, EIPs, VPCs) + HCP objects
#                        (OIDC, IAM role, variable set, Stack)
#   --skip-addons       (no-op for now; reserved for future controllers)
#   --skip-prereq-gate  (no-op at this level; passed automatically to
#                        bootstrap.sh in Phase 1 since Phase 0 already runs
#                        check-prerequisites.sh — accepted for CLI symmetry)
#   --dry-run           Show what would be done without executing
#   --project NAME      HCP project name (default: "Agentic Runtime Security")
#   --branch NAME       Git branch to push to (default: "main")
#   --help              Show this help message
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - Terraform CLI installed and authenticated (terraform login)
#   - TFE_TOKEN environment variable set (auto-loaded from credentials file)
#   - kubectl installed
#   - jq installed
#   - Git repository cloned and on the target branch
#   - GitHub VCS connection configured in HCP Terraform org
#
# Examples:
#   # Full lifecycle: bootstrap → deploy → verify → teardown
#   ./scripts/workshop-e2e.sh MyOrg
#
#   # Full lifecycle, pause between phases for manual checks
#   ./scripts/workshop-e2e.sh MyOrg --interactive
#
#   # Deploy and leave running (skip teardown)
#   ./scripts/workshop-e2e.sh MyOrg --skip-teardown
#
#   # Teardown only (foundation must exist)
#   ./scripts/workshop-e2e.sh MyOrg --teardown-only
#
#   # Nuke: destroy foundation via HCP, then clean up everything
#   ./scripts/workshop-e2e.sh MyOrg --nuke
#
#   # Cleanup only: foundation already destroyed, just remove leftovers
#   ./scripts/workshop-e2e.sh MyOrg --cleanup-only
#
#   # Preview what any command would do
#   ./scripts/workshop-e2e.sh MyOrg --nuke --dry-run
#
#   # Use a specific project and branch
#   ./scripts/workshop-e2e.sh MyOrg --project "My Project" --branch main
#===============================================================================

set -e

# Disable AWS CLI pager to prevent vi/less from capturing output
export AWS_PAGER=""

#-------------------------------------------------------------------------------
# Script Directory
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

#-------------------------------------------------------------------------------
# Color Constants (match existing scripts)
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
HCP_ORG=""
HCP_PROJECT="Agentic Runtime Security"
GIT_BRANCH="main"
INTERACTIVE=false
SKIP_TEARDOWN=false
TEARDOWN_ONLY=false
NUKE=false
CLEANUP_ONLY=false
SKIP_ADDONS=false
DRY_RUN=false
TFE_API="https://app.terraform.io/api/v2"

# IAM role name created by bootstrap.sh / setup-aws-oidc.sh
HCP_ROLE_NAME="hcp-stacks-deploy"

# Resolve canonical region + cluster_name from infrastructure/deployments.tfdeploy.hcl.
# No string literals here — only the .hcl file (terraform variables) is the source of truth.
TF_DEPLOY="${PROJECT_ROOT}/infrastructure/deployments.tfdeploy.hcl"
WORKSHOP_REGION="${AWS_REGION:-}"
if [ -z "$WORKSHOP_REGION" ] && [ -f "$TF_DEPLOY" ]; then
    WORKSHOP_REGION=$(grep -E '^\s*region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
CLUSTER_NAME="${CLUSTER_NAME:-}"
if [ -z "$CLUSTER_NAME" ] && [ -f "$TF_DEPLOY" ]; then
    CLUSTER_NAME=$(grep -E '^\s*cluster_name\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

# KB region — Nova 2 Multimodal Embeddings is us-east-1 only.
KB_REGION="${KB_REGION:-}"
if [ -z "$KB_REGION" ] && [ -f "$TF_DEPLOY" ]; then
    KB_REGION=$(grep -E '^\s*kb_region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
KB_REGION="${KB_REGION:-us-east-1}"
if [ -z "$CLUSTER_NAME" ]; then
    echo -e "${RED}Error: could not resolve cluster_name from $TF_DEPLOY${NC}" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
phase_header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

step_header() {
    echo -e "\n${YELLOW}> $1${NC}"
}

print_success() { echo -e "${GREEN}  ✓ $1${NC}"; }
print_error()   { echo -e "${RED}  ✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}  $1${NC}"; }
print_warn()    { echo -e "${YELLOW}  $1${NC}"; }

pause_if_interactive() {
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}  [INTERACTIVE] $1${NC}"
        echo -e "${YELLOW}  Press Enter to continue...${NC}"
        read -r
    fi
}

usage() {
    sed -n '2,71p' "$0"
    exit 0
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)        usage ;;
        --interactive)    INTERACTIVE=true ;;
        --skip-teardown)  SKIP_TEARDOWN=true ;;
        --teardown-only)  TEARDOWN_ONLY=true ;;
        --nuke)           NUKE=true ;;
        --cleanup-only)   CLEANUP_ONLY=true; NUKE=true ;;
        --skip-addons)    SKIP_ADDONS=true ;;
        --skip-prereq-gate)
            # No-op at this level. workshop-e2e.sh ALWAYS passes
            # --skip-prereq-gate to bootstrap.sh internally because Phase 0
            # already ran check-prerequisites.sh. Accepted here for CLI
            # symmetry — users who pass it through from the bootstrap.sh
            # surface get a clean run instead of an "Unknown option" error.
            ;;
        --dry-run)        DRY_RUN=true ;;
        --project)        HCP_PROJECT="$2"; shift ;;
        --branch)         GIT_BRANCH="$2"; shift ;;
        -*)               echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        *)
            if [ -z "$HCP_ORG" ]; then
                HCP_ORG="$1"
            else
                echo -e "${RED}Unexpected argument: $1${NC}"; usage
            fi
            ;;
    esac
    shift
done

# HCP_ORG is required unless teardown-only (reads from terraform.tfvars)
if [ -z "$HCP_ORG" ] && [ "$TEARDOWN_ONLY" = false ]; then
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfvars" ]; then
        HCP_ORG=$(grep 'hcp_org' "$SCRIPT_DIR/hcp-setup/terraform.tfvars" 2>/dev/null | awk -F'"' '{print $2}')
    fi
    if [ -z "$HCP_ORG" ]; then
        echo -e "${RED}Error: HCP_ORG is required${NC}"
        echo "Usage: $0 <HCP_ORG> [OPTIONS]"
        exit 1
    fi
fi

if [ "$TEARDOWN_ONLY" = true ] && [ -z "$HCP_ORG" ]; then
    HCP_ORG=$(grep 'hcp_org' "$SCRIPT_DIR/hcp-setup/terraform.tfvars" 2>/dev/null | awk -F'"' '{print $2}')
fi

if [ -z "$WORKSHOP_REGION" ] && [ "$TEARDOWN_ONLY" = false ] && [ "$NUKE" = false ]; then
    echo -e "${RED}Error: could not resolve workshop region${NC}"
    echo "Set AWS_REGION or ensure infrastructure/deployments.tfdeploy.hcl is present."
    exit 1
fi

#===============================================================================
# HCP Terraform API Functions
#===============================================================================

# Ensure TFE_TOKEN is loaded (auto-loads from credentials file if not set)
load_tfe_token() {
    if [ -z "${TFE_TOKEN:-}" ]; then
        if [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
            TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null)
            export TFE_TOKEN
        fi
    fi
    if [ -z "${TFE_TOKEN:-}" ]; then
        print_error "TFE_TOKEN not available"
        return 1
    fi
}

# Find the Stack ID in the HCP organization
# Filters by project if multiple stacks exist
hcp_find_stack() {
    local org="$1"
    load_tfe_token || return 1
    local stack_data

    stack_data=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$org/stacks" 2>/dev/null)

    local stack_count
    stack_count=$(echo "$stack_data" | jq '.data | length' 2>/dev/null)

    if [ "$stack_count" = "0" ] || [ -z "$stack_count" ]; then
        print_error "No stacks found in organization: $org"
        return 1
    fi

    if [ "$stack_count" = "1" ]; then
        echo "$stack_data" | jq -r '.data[0].id'
        return 0
    fi

    # Multiple stacks — try to match by project
    local project_id
    project_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw project_id 2>/dev/null || true)
    if [ -n "$project_id" ]; then
        local matched
        matched=$(echo "$stack_data" | jq -r \
            ".data[] | select(.relationships.project.data.id == \"$project_id\") | .id" 2>/dev/null | head -1)
        if [ -n "$matched" ]; then
            echo "$matched"
            return 0
        fi
    fi

    # Fallback: return first stack
    print_warn "Multiple stacks found, using first one"
    echo "$stack_data" | jq -r '.data[0].id'
}

# Trigger a new stack configuration (equivalent to "Fetch Configuration" in UI)
# Returns the configuration ID
hcp_trigger_plan() {
    local stack_id="$1"
    local response

    response=$(curl -s -X POST \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        -d '{"data":{"attributes":{}}}' \
        "$TFE_API/stacks/$stack_id/stack-configurations?source=fetch" 2>/dev/null)

    local config_id
    config_id=$(echo "$response" | jq -r '.data.id // empty' 2>/dev/null)

    if [ -z "$config_id" ]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].detail // .errors[0].title // "unknown error"' 2>/dev/null)
        print_error "Failed to trigger plan: $error_msg"
        return 1
    fi

    echo "$config_id"
}

# Wait for a stack configuration to reach a plannable/converged state
# Returns the status when done
hcp_wait_for_config() {
    local config_id="$1"
    local target_status="$2"  # "planned" or "converged"
    local timeout="${3:-1800}" # 30 min default
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local cfg_json status err_msg
        cfg_json=$(curl -s \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$config_id" 2>/dev/null)
        status=$(echo "$cfg_json" | jq -r '.data.attributes.status // "unknown"')
        # Some Stacks failure modes (e.g. source-bundle-too-large) populate
        # error-message before transitioning the status to "errored". Bail
        # the moment an error message appears, regardless of status.
        err_msg=$(echo "$cfg_json" | jq -r '.data.attributes."error-message" // empty')

        if [ -n "$err_msg" ]; then
            print_error "Configuration reported error-message: $err_msg"
            print_error "Final status: $status (config_id=$config_id)"
            echo "$status"
            return 1
        fi

        case "$status" in
            "$target_status"|converged|applied|completed)
                echo "$status"
                return 0
                ;;
            # Terminal failure states. The first three are the documented
            # Stacks/Terraform errored states; preparing_failed +
            # creation_failed cover source-bundle / archive-too-large
            # failures observed in practice.
            errored|canceled|abandoned|preparing_failed|creation_failed|discarded)
                print_error "Configuration reached terminal state: $status"
                echo "$status"
                return 1
                ;;
            *)
                if [ $((elapsed % 60)) -eq 0 ]; then
                    print_info "Configuration status: $status (${elapsed}s/${timeout}s)"
                fi
                sleep 15
                elapsed=$((elapsed + 15))
                ;;
        esac
    done

    print_error "Timeout waiting for configuration to reach $target_status"
    return 1
}

# Approve all deployment groups for a configuration
hcp_approve_config() {
    local config_id="$1"

    local groups_data
    groups_data=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/stack-configurations/$config_id/stack-deployment-groups" 2>/dev/null)

    local group_ids
    group_ids=$(echo "$groups_data" | jq -r '.data[].id' 2>/dev/null)

    if [ -z "$group_ids" ]; then
        print_warn "No deployment groups found to approve"
        return 0
    fi

    for group_id in $group_ids; do
        local group_name
        group_name=$(echo "$groups_data" | jq -r ".data[] | select(.id == \"$group_id\") | .attributes.name // .id" 2>/dev/null)

        curl -s -X POST \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d '{"reason":"workshop-e2e automated approval"}' \
            "$TFE_API/stack-deployment-groups/$group_id/approve-all-plans" >/dev/null 2>&1

        print_success "Approved deployment group: $group_name"
    done
}

# Get the latest config ID for a stack (used to detect new configs after push)
hcp_get_latest_config() {
    local stack_id="$1"
    curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null \
        | jq -r '.data[0].id // empty' 2>/dev/null
}

# Wait for a NEW VCS-triggered config (different from old_config_id) to appear,
# then approve and wait for convergence.
# Use this after a git push instead of hcp_trigger_plan to avoid competing configs.
hcp_wait_for_vcs_plan() {
    local stack_id="$1"
    local old_config_id="$2"
    local timeout="${3:-1800}"
    local elapsed=0

    step_header "Waiting for VCS-triggered plan to appear..."

    local config_id=""
    while [ $elapsed -lt $timeout ]; do
        config_id=$(hcp_get_latest_config "$stack_id")

        if [ -n "$config_id" ] && [ "$config_id" != "$old_config_id" ]; then
            break
        fi

        sleep 10
        elapsed=$((elapsed + 10))
        if [ $((elapsed % 30)) -eq 0 ]; then
            print_info "Waiting for new config (${elapsed}s/${timeout}s)"
        fi
        config_id=""
    done

    if [ -z "$config_id" ]; then
        print_error "Timeout waiting for VCS-triggered config"
        return 1
    fi

    print_success "New configuration detected: $config_id"

    step_header "Waiting for plan to complete..."
    hcp_wait_for_config "$config_id" "planned" "$timeout" || {
        local final_status
        final_status=$(curl -s \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$config_id" 2>/dev/null \
            | jq -r '.data.attributes.status // "unknown"')
        if [ "$final_status" = "converged" ]; then
            print_success "Configuration converged (no changes needed)"
            return 0
        fi
        return 1
    }

    step_header "Approving all deployment groups..."
    hcp_approve_config "$config_id" || return 1

    step_header "Waiting for apply to complete..."
    hcp_wait_for_config "$config_id" "converged" "$timeout" || return 1
    print_success "VCS-triggered deploy complete"
}

# Full cycle: trigger plan → wait for planned → approve → wait for converged
hcp_deploy_and_wait() {
    local stack_id="$1"
    local description="$2"
    local timeout="${3:-1800}"

    step_header "Triggering plan: $description"
    local config_id
    config_id=$(hcp_trigger_plan "$stack_id") || return 1
    print_success "Configuration created: $config_id"

    step_header "Waiting for plan to complete..."
    hcp_wait_for_config "$config_id" "planned" "$timeout" || {
        local final_status
        final_status=$(curl -s \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$config_id" 2>/dev/null \
            | jq -r '.data.attributes.status // "unknown"')
        if [ "$final_status" = "converged" ]; then
            print_success "Configuration converged (no changes needed)"
            return 0
        fi
        return 1
    }

    step_header "Approving all deployment groups..."
    hcp_approve_config "$config_id" || return 1

    step_header "Waiting for apply to complete..."
    hcp_wait_for_config "$config_id" "converged" "$timeout" || return 1
    print_success "$description complete"
}

#===============================================================================
# Git Helper
#===============================================================================

GIT_PUSHED=false  # set to true when git_commit_and_push actually pushes

git_commit_and_push() {
    local message="$1"
    local files=("${@:2}")
    GIT_PUSHED=false

    cd "$PROJECT_ROOT"
    git add "${files[@]}"

    if git diff --cached --quiet; then
        print_info "No changes to commit (already up to date)"
        return 0
    fi

    git commit -m "$message" >/dev/null 2>&1
    git push origin "$GIT_BRANCH" >/dev/null 2>&1
    GIT_PUSHED=true
    print_success "Committed and pushed: $message"
}

#===============================================================================
# PHASE 0: Prerequisites
#===============================================================================
phase_prerequisites() {
    phase_header "Phase 0: Prerequisites"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: check-prerequisites.sh"
        return 0
    fi

    bash "$SCRIPT_DIR/check-prerequisites.sh" || {
        print_error "Prerequisites check failed. Fix the issues above and retry."
        exit 1
    }

    if ! command -v jq &>/dev/null; then
        print_error "jq is required for HCP API interaction"
        exit 1
    fi
    print_success "jq found"

    load_tfe_token || {
        print_error "TFE_TOKEN not set and could not load from ~/.terraform.d/credentials.tfrc.json"
        print_info "Run: terraform login"
        exit 1
    }
    print_success "TFE_TOKEN loaded"

    local current_branch
    current_branch=$(git -C "$PROJECT_ROOT" branch --show-current)
    if [ "$current_branch" != "$GIT_BRANCH" ]; then
        print_error "Expected branch '$GIT_BRANCH' but on '$current_branch'"
        print_info "Switch with: git checkout $GIT_BRANCH"
        exit 1
    fi
    print_success "On branch: $GIT_BRANCH"
}

#===============================================================================
# PHASE 1: Bootstrap (OIDC + Variable Set + Stack)
#===============================================================================
phase_bootstrap() {
    phase_header "Phase 1: Bootstrap (OIDC + Variable Set + Stack)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: bootstrap.sh $HCP_ORG --project \"$HCP_PROJECT\" --branch $GIT_BRANCH --skip-prereq-gate"
        return 0
    fi

    # Always verify OIDC provider + IAM role exist (teardown deletes them)
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local oidc_arn="arn:aws:iam::${account_id}:oidc-provider/app.terraform.io"

    local needs_oidc=false
    if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" &>/dev/null; then
        print_warn "OIDC provider not found — will recreate"
        needs_oidc=true
    fi
    if ! aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
        print_warn "IAM role $HCP_ROLE_NAME not found — will recreate"
        needs_oidc=true
    fi

    if [ "$needs_oidc" = true ]; then
        step_header "Recreating OIDC provider + IAM role..."
        bash "$SCRIPT_DIR/setup-aws-oidc.sh" "$HCP_ORG" || {
            print_error "OIDC setup failed"
            exit 1
        }
        print_success "OIDC provider + IAM role created"
    else
        print_success "OIDC provider + IAM role exist"
    fi

    # Check if variable set already configured
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfvars" ] && \
       [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ]; then
        print_info "Verifying variable set is current..."
        terraform -chdir="$SCRIPT_DIR/hcp-setup" apply -auto-approve -input=false >/dev/null 2>&1 || {
            print_warn "Variable set refresh failed — re-running bootstrap"
            bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG" --project "$HCP_PROJECT" --branch "$GIT_BRANCH" --skip-prereq-gate
            return $?
        }
        print_success "Variable set verified"

        # Ensure Stack exists even when variable set was already configured
        step_header "Verifying HCP Stack exists..."
        local stack_id
        stack_id=$(hcp_find_stack "$HCP_ORG" 2>/dev/null) && {
            print_success "Stack found (ID: $stack_id)"
            return 0
        }
        print_warn "Stack not found — running bootstrap to create it"
    fi

    bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG" --project "$HCP_PROJECT" --branch "$GIT_BRANCH" --skip-prereq-gate
}

#===============================================================================
# PHASE 2: Foundation Deploy
#===============================================================================
phase_deploy_foundation() {
    phase_header "Phase 2: Foundation Deploy (EKS + RDS + Bedrock KB)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would set destroy=false on usw2 deployment"
        print_info "[DRY-RUN] Would commit, push, and trigger HCP plan via API"
        return 0
    fi

    # If a prior deploy failed, run `./scripts/teardown.sh --aws-only` first.
    # The deploy phase no longer auto-cleans — one tool, one job.

    # Find the stack
    step_header "Finding HCP Terraform Stack..."
    local stack_id
    stack_id=$(hcp_find_stack "$HCP_ORG") || {
        print_error "Could not find Stack in HCP Terraform"
        print_info "Create a Stack via bootstrap.sh first:"
        print_info "  $SCRIPT_DIR/bootstrap.sh $HCP_ORG"
        exit 1
    }
    print_success "Stack found: $stack_id"

    # Enable foundation deployment
    step_header "Setting destroy=false on usw2 deployment..."
    local deploy_file="$PROJECT_ROOT/infrastructure/deployments.tfdeploy.hcl"

    sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*true/destroy = false/g' "$deploy_file"
    rm -f "${deploy_file}.bak"

    # Capture current config ID before push so we can detect the new one
    local old_config_id
    old_config_id=$(hcp_get_latest_config "$stack_id")

    git_commit_and_push "deploy: enable foundation (usw2) for e2e" \
        "infrastructure/deployments.tfdeploy.hcl"

    if [ "$GIT_PUSHED" = true ]; then
        # Wait for VCS-triggered plan (don't create a competing API config)
        hcp_wait_for_vcs_plan "$stack_id" "$old_config_id" 2400 || {
            print_error "Foundation deploy failed. Check HCP Terraform UI for details."
            exit 1
        }
    else
        # No git change — trigger plan via API (e.g., re-run after cancel)
        hcp_deploy_and_wait "$stack_id" "Foundation deploy (usw2)" 2400 || {
            print_error "Foundation deploy failed. Check HCP Terraform UI for details."
            exit 1
        }
    fi

    pause_if_interactive "Foundation plan triggered. Wait for HCP apply to converge before continuing."
}

#===============================================================================
# PHASE 3: Configure kubectl (single deployment usw2)
#===============================================================================
phase_configure_kubectl() {
    phase_header "Phase 3: Configure kubectl (single deployment usw2)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would configure kubectl for $CLUSTER_NAME ($WORKSHOP_REGION)"
        return 0
    fi

    if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$WORKSHOP_REGION" \
            --alias "$CLUSTER_NAME" >/dev/null 2>&1; then
        print_success "$CLUSTER_NAME ($WORKSHOP_REGION) — kubeconfig updated"
    else
        print_warn "$CLUSTER_NAME ($WORKSHOP_REGION) — could not update kubeconfig"
    fi

    step_header "Verifying cluster connectivity..."
    local node_count
    node_count=$(kubectl --context "$CLUSTER_NAME" get nodes --no-headers 2>/dev/null \
        | wc -l | tr -d ' ')
    if [ "${node_count:-0}" -gt 0 ] 2>/dev/null; then
        print_success "$CLUSTER_NAME — $node_count nodes ready"
    else
        print_error "$CLUSTER_NAME — no nodes found"
    fi

    pause_if_interactive "kubectl configured."
}

#===============================================================================
# PHASE 4: Foundation Verify (EKS + RDS + Bedrock KB)
#===============================================================================
phase_verify_foundation() {
    phase_header "Phase 4: Foundation Verify (EKS + RDS + Bedrock KB)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: test-foundation.sh"
        return 0
    fi

    # Resolve DB instance + KB id from env or fall back to AWS discovery
    local db_id="${WORKSHOP_DB_INSTANCE_ID:-}"
    local kb_id="${WORKSHOP_KB_ID:-}"

    if [ -z "$db_id" ]; then
        db_id=$(aws rds describe-db-instances --region "$WORKSHOP_REGION" \
            --query "DBInstances[?contains(TagList[?Key=='Workshop'].Value | [0], 'agentic-runtime-security')].DBInstanceIdentifier | [0]" \
            --output text 2>/dev/null)
        [ "$db_id" = "None" ] && db_id=""
    fi
    if [ -z "$kb_id" ]; then
        kb_id=$(aws bedrock-agent list-knowledge-bases --region "$KB_REGION" \
            --query 'knowledgeBaseSummaries[0].knowledgeBaseId' --output text 2>/dev/null)
        [ "$kb_id" = "None" ] && kb_id=""
    fi

    if [ -z "$db_id" ] || [ -z "$kb_id" ]; then
        print_warn "Could not auto-discover DB instance or KB id"
        print_warn "Set WORKSHOP_DB_INSTANCE_ID and WORKSHOP_KB_ID env vars and rerun"
        print_warn "Skipping test-foundation.sh"
        return 0
    fi

    bash "$SCRIPT_DIR/test-foundation.sh" \
        --cluster-name "$CLUSTER_NAME" \
        --db-instance-id "$db_id" \
        --knowledge-base-id "$kb_id" \
        --region "$KB_REGION" \
        || print_warn "Foundation verification reported failures (see above)"

    pause_if_interactive "Foundation verification complete."
}

#===============================================================================
# PHASE 5: Identity (IVIA) — verify IVIA pods + OIDC discovery
#===============================================================================
phase_identity() {
    phase_header "Phase 5: Identity (IVIA)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would check IVIA pods running and OIDC discovery endpoint"
        return 0
    fi

    local ivia_ns="verify-access"
    local vault_ns="vault"
    local oidc_url="https://isvaop.verify-access.svc.cluster.local:8436/.well-known/openid-configuration"

    # Check IVIA pods
    local running_ivia
    running_ivia=$(kubectl get pods -n "${ivia_ns}" --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${running_ivia:-0}" -ge 1 ]; then
        print_success "IVIA: ${running_ivia} pod(s) Running in ${ivia_ns}"
    else
        print_warn "IVIA: no pods Running in ${ivia_ns} — IVIA may still be starting"
    fi

    # Check OIDC discovery via vault-0 (in-cluster path)
    local ivia_issuer
    ivia_issuer=$(kubectl exec -n "${vault_ns}" vault-0 -- \
        curl -sk "${oidc_url}" 2>/dev/null \
        | jq -r '.issuer // empty' 2>/dev/null || echo "")
    if [ -n "${ivia_issuer}" ]; then
        print_success "IVIA OIDC discovery: issuer = ${ivia_issuer}"
    else
        print_warn "IVIA OIDC discovery: issuer not reachable (IVIA may still be initializing)"
    fi

    pause_if_interactive "IVIA verification complete."
}

#===============================================================================
# PHASE 6: Vault — init (two-phase bootstrap) + verify
# Step 1: vault-init.sh — initialize Vault, save root token + recovery keys
# Step 2: vault-enable-config.sh — enable Wave 5-6, push to main, trigger Stacks
# Step 3: Wait for second Stacks deploy to complete
# Step 4: test-vault-verify.sh — verify pods, seal status, Raft peers, audit
#===============================================================================
phase_vault() {
    phase_header "Phase 6: Vault"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: vault-init.sh"
        print_info "[DRY-RUN] Would store vault_token in HCP variable set"
        print_info "[DRY-RUN] Would run: vault-enable-config.sh"
        print_info "[DRY-RUN] Would wait for second Stacks deploy"
        print_info "[DRY-RUN] Would run: test-vault-verify.sh"
        return 0
    fi

    # Step 1: Initialize Vault
    step_header "Initializing Vault (two-phase bootstrap Phase 1)..."
    bash "$SCRIPT_DIR/vault-init.sh" \
        || { print_error "vault-init.sh failed"; return 1; }

    # Step 2: Store vault_token in HCP variable set
    local root_token
    root_token=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || true)
    if [ -z "$root_token" ]; then
        print_error "Could not read root_token from ~/vault-init.json"
        return 1
    fi

    step_header "Storing vault_token in HCP variable set..."
    local org stack_id varset_id
    org="${HCP_ORG:-}"
    if [ -z "$org" ]; then
        print_warn "HCP_ORG not set — cannot auto-store vault_token."
        print_info "Manually add vault_token=${root_token} to the HCP variable set."
        pause_if_interactive "Press Enter after storing vault_token in HCP..."
    else
        stack_id=$(get_stack_id "$org")
        varset_id=$(curl -s \
            -H "Authorization: Bearer $(terraform stacks token 2>/dev/null || echo '')" \
            "$TFE_API/organizations/$org/varsets?search%5Bname%5D=$VARSET_NAME" 2>/dev/null \
            | jq -r '.data[0].id // empty' || true)
        if [ -n "$varset_id" ]; then
            curl -s -X POST \
                -H "Authorization: Bearer $(terraform stacks token 2>/dev/null || echo '')" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/varsets/$varset_id/relationships/vars" \
                -d "{\"data\":{\"type\":\"vars\",\"attributes\":{\"key\":\"vault_token\",\"value\":\"$root_token\",\"category\":\"terraform\",\"sensitive\":true}}}" \
                >/dev/null 2>&1 \
                && print_success "vault_token stored in HCP variable set" \
                || print_warn "Failed to auto-store vault_token — add manually to HCP"
        else
            print_warn "Could not find variable set — add vault_token manually to HCP"
            pause_if_interactive "Press Enter after storing vault_token in HCP..."
        fi
    fi

    # Step 3: Enable vault_config and trigger second Stacks deploy
    step_header "Enabling vault_config (two-phase bootstrap Phase 2)..."
    bash "$SCRIPT_DIR/vault-enable-config.sh" \
        || { print_error "vault-enable-config.sh failed"; return 1; }

    # Step 4: Wait for second Stacks deploy
    if [ -n "${org:-}" ] && [ -n "${stack_id:-}" ]; then
        wait_for_plan "$org" "$stack_id"
        approve_deployment_groups "$stack_id"
        wait_for_apply "$org" "$stack_id"
    else
        print_info "Approve the Stacks plan in HCP Terraform UI."
        pause_if_interactive "Press Enter after the second Stacks run completes..."
    fi

    # Step 5: Verify Vault
    step_header "Verifying Vault configuration..."
    bash "$SCRIPT_DIR/test-vault-verify.sh" \
        || print_warn "Vault verification reported failures (see above)"

    pause_if_interactive "Vault verification complete."
}

#===============================================================================
# PHASE 7a: Use Case 1 — Non-Personalized Read-Only
#===============================================================================
phase_uc1() {
    phase_header "Phase 7a: Use Case 1 — Non-Personalized Read-Only"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would create ECR repo, build+push UC1 agent image"
        print_info "[DRY-RUN] Would update uc1_agent_image in deployments.tfdeploy.hcl"
        print_info "[DRY-RUN] Would trigger Stacks plan+apply, then run verify-uc1.sh"
        return 0
    fi

    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local ecr_repo="workshop/uc1-agent"
    local image_tag="latest"
    local ecr_uri="${account_id}.dkr.ecr.${WORKSHOP_REGION}.amazonaws.com/${ecr_repo}:${image_tag}"
    local agent_dir="$PROJECT_ROOT/infrastructure/modules/uc1_agent/agent"

    # Step 1: Create ECR repository (idempotent)
    step_header "Creating ECR repository (if needed)..."
    if aws ecr describe-repositories --repository-names "$ecr_repo" \
            --region "$WORKSHOP_REGION" &>/dev/null; then
        print_success "ECR repo exists: $ecr_repo"
    else
        aws ecr create-repository --repository-name "$ecr_repo" \
            --region "$WORKSHOP_REGION" \
            --image-scanning-configuration scanOnPush=true \
            --output text --query 'repository.repositoryUri' >/dev/null 2>&1
        print_success "ECR repo created: $ecr_repo"
    fi

    # Step 2: Build the UC1 agent container image
    step_header "Building UC1 agent container image..."
    docker build -t "${ecr_repo}:${image_tag}" "$agent_dir" || {
        print_error "Docker build failed"
        return 1
    }
    print_success "Image built: ${ecr_repo}:${image_tag}"

    # Step 3: Authenticate to ECR and push
    step_header "Pushing image to ECR..."
    aws ecr get-login-password --region "$WORKSHOP_REGION" \
        | docker login --username AWS --password-stdin \
            "${account_id}.dkr.ecr.${WORKSHOP_REGION}.amazonaws.com" >/dev/null 2>&1

    docker tag "${ecr_repo}:${image_tag}" "$ecr_uri"
    docker push "$ecr_uri" >/dev/null 2>&1 || {
        print_error "Docker push failed"
        return 1
    }
    print_success "Image pushed: $ecr_uri"

    # Step 4: Update uc1_agent_image in deployments.tfdeploy.hcl
    step_header "Updating uc1_agent_image in deployments.tfdeploy.hcl..."
    local deploy_file="$PROJECT_ROOT/infrastructure/deployments.tfdeploy.hcl"
    local current_image
    current_image=$(grep 'uc1_agent_image' "$deploy_file" | sed -E 's/.*"([^"]+)".*/\1/')

    if [ "$current_image" = "$ecr_uri" ]; then
        print_info "uc1_agent_image already set to $ecr_uri"
    else
        sed -i.bak "s|uc1_agent_image *= *\"[^\"]*\"|uc1_agent_image = \"${ecr_uri}\"|" "$deploy_file"
        rm -f "${deploy_file}.bak"
        print_success "uc1_agent_image = $ecr_uri"
    fi

    # Step 5: Find Stack and trigger deploy
    step_header "Finding HCP Terraform Stack..."
    local stack_id
    stack_id=$(hcp_find_stack "$HCP_ORG") || {
        print_error "Could not find Stack in HCP Terraform"
        return 1
    }
    print_success "Stack found: $stack_id"

    local old_config_id
    old_config_id=$(hcp_get_latest_config "$stack_id")

    git_commit_and_push "deploy: set uc1_agent_image for UC1 agent deployment" \
        "infrastructure/deployments.tfdeploy.hcl"

    if [ "$GIT_PUSHED" = true ]; then
        step_header "Waiting for VCS-triggered deploy (UC1 agent)..."
        hcp_wait_for_vcs_plan "$stack_id" "$old_config_id" 1800 || {
            print_error "UC1 deploy failed. Check HCP Terraform UI for details."
            return 1
        }
    else
        step_header "Triggering Stacks plan (UC1 agent)..."
        hcp_deploy_and_wait "$stack_id" "UC1 agent deploy" 1800 || {
            print_error "UC1 deploy failed. Check HCP Terraform UI for details."
            return 1
        }
    fi
    print_success "UC1 agent deployed via Stacks"

    # Step 6: Wait for pod readiness
    step_header "Waiting for UC1 agent pod to be ready..."
    local uc1_ready=false
    local wait_elapsed=0
    while [ $wait_elapsed -lt 120 ]; do
        if kubectl get pods -n uc1 -l app=uc1-agent --no-headers 2>/dev/null | grep -q Running; then
            uc1_ready=true
            break
        fi
        sleep 10
        wait_elapsed=$((wait_elapsed + 10))
        if [ $((wait_elapsed % 30)) -eq 0 ]; then
            print_info "Waiting for UC1 pod (${wait_elapsed}s/120s)..."
        fi
    done

    if [ "$uc1_ready" = true ]; then
        print_success "UC1 agent pod is Running"
    else
        print_warn "UC1 agent pod not Running after 120s — verify-uc1.sh will report details"
    fi

    # Step 7: Verify
    pause_if_interactive "About to verify UC1 deployment"
    bash "$SCRIPT_DIR/verify-uc1.sh" 2>&1 || print_warn "UC1 verification had warnings"
    print_success "UC1 verification complete"
}

#===============================================================================
# PHASE 7b: Use Case 2 — OAuth Personalized Read-Only (placeholder)
#===============================================================================
phase_uc2_placeholder() {
    phase_header "Phase 7b: Use Case 2 — OAuth Personalized Read-Only"
    print_info "[Phase 7b — placeholder; populated when Phase 5 (UC2) ships]"
    return 0
}

#===============================================================================
# PHASE 7c: Use Case 3 — CIBA Privileged (placeholder)
#===============================================================================
phase_uc3_placeholder() {
    phase_header "Phase 7c: Use Case 3 — CIBA Privileged"
    print_info "[Phase 7c — placeholder; populated when Phase 6 (UC3) ships]"
    return 0
}

#===============================================================================
# PHASE 8: Teardown
#===============================================================================
phase_teardown() {
    phase_header "Phase 8: Teardown"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: teardown.sh (full nuke: AWS + HCP)"
        return 0
    fi

    pause_if_interactive "About to start teardown. This will destroy all workshop resources."

    bash "$SCRIPT_DIR/teardown.sh" 2>&1 || print_warn "Teardown had warnings"
    print_success "Teardown complete"
}

#===============================================================================
# NUKE: Delete everything — AWS resources, OIDC, IAM, HCP variable set, Stack
#===============================================================================
phase_nuke() {
    if [ "$CLEANUP_ONLY" = true ]; then
        phase_header "NUKE: Cleanup Only (skip HCP destroy)"
        print_info "Cleaning up dangling AWS resources + HCP objects."
        print_info "EKS cluster assumed already destroyed."
    else
        phase_header "NUKE: Delete Everything"
        print_warn "This will delete ALL resources: foundation (EKS/RDS/KB), VPC, OIDC provider,"
        print_warn "IAM role, HCP variable set, AND the HCP Terraform Stack."
    fi
    echo ""

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would check cluster existence, destroy if needed, then cleanup"
        return 0
    fi

    load_tfe_token || { print_error "TFE_TOKEN required for nuke"; exit 1; }

    # Determine region for cluster check (same resolution as main flow, plus AWS_REGION)
    local nuke_region="$WORKSHOP_REGION"
    if [ -z "$nuke_region" ]; then
        nuke_region="${AWS_REGION:-}"
    fi

    # ─── Step 1: Check cluster existence ─────────────────────────────────
    step_header "Checking EKS cluster existence..."
    local cluster_active=false
    if [ -n "$nuke_region" ] && \
       aws eks describe-cluster --name "$CLUSTER_NAME" --region "$nuke_region" &>/dev/null; then
        print_error "$CLUSTER_NAME ($nuke_region) — ACTIVE"
        cluster_active=true
    else
        print_success "$CLUSTER_NAME — gone (or no region resolved)"
    fi

    # ─── Step 2: HCP destroy (only if cluster exists AND not --cleanup-only) ─
    if [ "$cluster_active" = true ] && [ "$CLEANUP_ONLY" = true ]; then
        print_error "Cluster still ACTIVE but --cleanup-only was specified."
        print_info "Use --nuke (without --cleanup-only) to trigger HCP destroy first."
        exit 1
    fi

    if [ "$cluster_active" = true ]; then
        # Ensure OIDC + variable set BEFORE git push so the VCS-triggered
        # plan has valid credentials when it runs
        step_header "Ensuring HCP prerequisites exist for destroy..."
        local account_id
        account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
        local oidc_arn="arn:aws:iam::${account_id}:oidc-provider/app.terraform.io"

        if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" &>/dev/null || \
           ! aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
            print_info "OIDC or IAM role missing — recreating via setup-aws-oidc.sh..."
            bash "$SCRIPT_DIR/setup-aws-oidc.sh" "$HCP_ORG" 2>&1 || {
                print_error "OIDC setup failed"; exit 1
            }
            print_success "OIDC + IAM role ready"
        else
            print_success "OIDC + IAM role exist"
        fi

        if [ ! -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ]; then
            print_info "Variable set state missing — recreating via bootstrap..."
            bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG" --project "$HCP_PROJECT" --branch "$GIT_BRANCH" --skip-prereq-gate 2>&1 || {
                print_error "Bootstrap failed"; exit 1
            }
            print_success "Variable set recreated"
        else
            terraform -chdir="$SCRIPT_DIR/hcp-setup" apply -auto-approve -input=false >/dev/null 2>&1 && \
                print_success "Variable set verified" || {
                print_info "Variable set refresh failed — recreating..."
                bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG" --project "$HCP_PROJECT" --branch "$GIT_BRANCH" --skip-prereq-gate 2>&1 || {
                    print_error "Bootstrap failed"; exit 1
                }
            }
        fi

        local stack_id
        stack_id=$(hcp_find_stack "$HCP_ORG") || {
            print_warn "Could not find Stack — may already be deleted"
            stack_id=""
        }

        # Capture current config before push so we detect the new VCS-triggered one
        local old_config_id=""
        if [ -n "$stack_id" ]; then
            old_config_id=$(hcp_get_latest_config "$stack_id")
        fi

        # Now push destroy=true — the VCS webhook triggers a plan with valid OIDC
        step_header "Setting destroy=true on usw2 deployment..."
        local deploy_file="$PROJECT_ROOT/infrastructure/deployments.tfdeploy.hcl"
        sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*false/destroy = true/g' "$deploy_file"
        rm -f "${deploy_file}.bak"
        git_commit_and_push "nuke: set destroy=true on usw2" \
            "infrastructure/deployments.tfdeploy.hcl"

        # Wait for plan — VCS-triggered if we pushed, API-triggered otherwise
        if [ -n "$stack_id" ]; then
            if [ "$GIT_PUSHED" = true ]; then
                hcp_wait_for_vcs_plan "$stack_id" "$old_config_id" 2400 || {
                    print_warn "HCP destroy did not fully converge — continuing with cleanup"
                }
            else
                hcp_deploy_and_wait "$stack_id" "Destroy foundation" 2400 || {
                    print_warn "HCP destroy did not fully converge — continuing with cleanup"
                }
            fi
        fi

        # Verify cluster is actually gone
        step_header "Verifying EKS cluster is destroyed..."
        cluster_active=false
        if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$nuke_region" &>/dev/null; then
            print_error "$CLUSTER_NAME ($nuke_region) — still ACTIVE"
            cluster_active=true
        else
            print_success "$CLUSTER_NAME ($nuke_region) — gone"
        fi

        if [ "$cluster_active" = true ]; then
            print_error "Cluster still exists — HCP destroy did not complete"
            print_info "Recreating OIDC + role and retrying..."

            bash "$SCRIPT_DIR/setup-aws-oidc.sh" "$HCP_ORG" 2>&1 || {
                print_error "OIDC recreation failed"; exit 1
            }
            print_success "OIDC + IAM role recreated"

            if [ -n "$stack_id" ]; then
                hcp_deploy_and_wait "$stack_id" "Destroy retry (with valid OIDC)" 2400 || {
                    print_warn "Retry did not fully converge"
                }
            fi

            step_header "Re-verifying cluster after retry..."
            if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$nuke_region" &>/dev/null; then
                print_error "$CLUSTER_NAME ($nuke_region) — still ACTIVE after retry"
                print_info "Manual cleanup required in AWS Console."
                print_info "Fix OIDC, then rerun: $0 --nuke"
                exit 1
            else
                print_success "$CLUSTER_NAME ($nuke_region) — gone"
            fi
        fi

        print_success "EKS cluster confirmed destroyed"
    else
        print_success "EKS cluster already destroyed — skipping HCP plan"
    fi

    # ─── Step 3: Cleanup (always runs) ───────────────────────────────────
    # Find stack ID for cleanup steps (if not already found above)
    if [ -z "${stack_id+x}" ]; then
        local stack_id
        stack_id=$(hcp_find_stack "$HCP_ORG") || {
            print_warn "Could not find Stack — may already be deleted"
            stack_id=""
        }
    fi

    # 3a: AWS resource sweep (everything tagged Workshop=*)
    step_header "Sweeping AWS workshop resources..."
    bash "$SCRIPT_DIR/teardown.sh" --aws-only 2>&1 || \
        print_warn "AWS sweep had warnings"

    # 3b: Delete HCP Stack via API
    if [ -n "$stack_id" ]; then
        step_header "Deleting HCP Terraform Stack..."
        local delete_response
        delete_response=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stacks/$stack_id" 2>/dev/null)
        if [ "$delete_response" = "204" ] || [ "$delete_response" = "200" ]; then
            print_success "HCP Stack deleted"
        elif [ "$delete_response" = "404" ]; then
            print_info "Stack already deleted"
        else
            print_warn "Stack deletion returned HTTP $delete_response — check HCP UI"
            print_info "Manual delete: Stack > Settings > Destruction and Deletion > Delete stack"
        fi
    fi

    # 3c: Destroy HCP variable set via terraform
    step_header "Destroying HCP variable set..."
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ]; then
        terraform -chdir="$SCRIPT_DIR/hcp-setup" destroy -auto-approve -input=false >/dev/null 2>&1 && \
            print_success "HCP variable set destroyed" || \
            print_warn "Variable set destroy had errors (may already be gone)"
    else
        print_info "No terraform state found — variable set may already be destroyed"
    fi

    # 3d: Delete IAM role + OIDC provider
    step_header "Deleting IAM role and OIDC provider..."
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local oidc_arn="arn:aws:iam::${account_id}:oidc-provider/app.terraform.io"

    if aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
        local policies
        policies=$(aws iam list-attached-role-policies --role-name "$HCP_ROLE_NAME" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
        for policy in $policies; do
            aws iam detach-role-policy --role-name "$HCP_ROLE_NAME" --policy-arn "$policy" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$HCP_ROLE_NAME" 2>/dev/null && \
            print_success "IAM role deleted: $HCP_ROLE_NAME" || \
            print_warn "Could not delete IAM role"
    else
        print_info "IAM role not found — already deleted"
    fi

    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" &>/dev/null; then
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" 2>/dev/null && \
            print_success "OIDC provider deleted" || \
            print_warn "Could not delete OIDC provider"
    else
        print_info "OIDC provider not found — already deleted"
    fi

    # 3e: Clean up local state
    step_header "Cleaning up local state..."
    rm -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" "$SCRIPT_DIR/hcp-setup/terraform.tfstate.backup" 2>/dev/null
    print_success "Local terraform state removed"

    echo ""
    print_success "NUKE COMPLETE — all resources deleted"
    print_info "To redeploy from scratch: $0 <HCP_ORG> --interactive --skip-teardown"
}

#===============================================================================
# MAIN
#===============================================================================

echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Agentic Runtime Security Workshop — End-to-End${NC}"
echo -e "${BLUE}================================================================${NC}"

if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN MODE — no changes will be made"
fi

if [ "$INTERACTIVE" = true ]; then
    print_info "Interactive mode — will pause between phases"
fi

if [ "$SKIP_ADDONS" = true ]; then
    print_info "--skip-addons: no-op for now (no controllers in scope)"
fi

# Nuke mode — delete everything
if [ "$NUKE" = true ]; then
    phase_nuke
    echo ""
    exit 0
fi

# Teardown-only mode
if [ "$TEARDOWN_ONLY" = true ]; then
    phase_teardown
    echo ""
    exit 0
fi

# Full e2e flow
phase_prerequisites
phase_bootstrap
phase_deploy_foundation
phase_configure_kubectl
phase_verify_foundation
phase_identity
phase_vault
phase_uc1
phase_uc2_placeholder
phase_uc3_placeholder

if [ "$SKIP_TEARDOWN" = false ]; then
    phase_teardown
else
    echo ""
fi

echo ""
phase_header "Workshop E2E Complete"
if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN — no changes were made"
elif [ "$SKIP_TEARDOWN" = true ]; then
    print_success "All phases passed — deployment left running"
else
    print_success "All phases passed — resources destroyed"
fi
echo ""
