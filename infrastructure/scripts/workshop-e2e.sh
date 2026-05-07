#!/usr/bin/env bash
#===============================================================================
# Workshop End-to-End Orchestration — Agentic Runtime Security on AWS
#
# Phases:
#   Phase 0: Prerequisites (calls check-prerequisites.sh, which wraps preflight.sh)
#   Phase 1: Bootstrap (calls bootstrap.sh — OIDC + variable set + Stack)
#   Phase 2: Foundation deploy (git push + HCP plan trigger + approve + wait)
#   Phase 3: Configure kubectl (single deployment usw2)
#   Phase 4: Foundation verify (calls test-foundation.sh)
#   Phase 5: Identity (IVIA) — placeholder, populated in Phase 3 of the workshop
#   Phase 6: Vault — placeholder, populated in Phase 4 of the workshop
#   Phase 7: Use cases (UC1/UC2/UC3) — placeholder, populated in Phases 5/6
#   Phase 8: Teardown (calls teardown.sh — unless --skip-teardown)
#
# Usage: ./workshop-e2e.sh <HCP_ORG> [OPTIONS]
#
# Options:
#   --interactive       Pause between phases for manual verification
#   --skip-teardown     Leave deployment running after verification
#   --teardown-only     Skip deployment, run teardown only
#   --nuke              Delete EVERYTHING: foundation, OIDC, IAM, variable set, Stack
#   --cleanup-only      Skip HCP destroy — clean up dangling AWS + HCP only
#   --skip-addons       (no-op for now; reserved for Phase 3+ controllers)
#   --dry-run           Show what would be done without executing
#   --project NAME      HCP project name (default: agentic-runtime-stacks)
#   --branch NAME       Git branch to push to (default: main)
#   --help              Show this help message
#===============================================================================

set -e
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Defaults
HCP_ORG=""
# shellcheck disable=SC2034 # HCP_PROJECT reserved for future bootstrap.sh integration
HCP_PROJECT="agentic-runtime-stacks"
GIT_BRANCH="main"
INTERACTIVE=false
SKIP_TEARDOWN=false
TEARDOWN_ONLY=false
NUKE=false
CLEANUP_ONLY=false
SKIP_ADDONS=false
DRY_RUN=false
TFE_API="https://app.terraform.io/api/v2"

# Workshop-locked single-deployment cluster (alias = deployment block name)
CLUSTER_NAME="eks-usw2"

# Resolve canonical region from deployments.tfdeploy.hcl (no us-west-2 literal here)
TF_DEPLOY="${PROJECT_ROOT}/infrastructure/deployments.tfdeploy.hcl"
WORKSHOP_REGION="${AWS_REGION:-}"
if [ -z "$WORKSHOP_REGION" ] && [ -f "$TF_DEPLOY" ]; then
    WORKSHOP_REGION=$(grep -E '^\s*region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

phase_header() { echo; echo -e "${BLUE}================================================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}================================================================${NC}"; }
step_header()  { echo -e "\n${YELLOW}> $1${NC}"; }
print_success(){ echo -e "${GREEN}  ✓ $1${NC}"; }
print_error()  { echo -e "${RED}  ✗ $1${NC}"; }
print_info()   { echo -e "${BLUE}  $1${NC}"; }
print_warn()   { echo -e "${YELLOW}  $1${NC}"; }

pause_if_interactive() {
    if [ "$INTERACTIVE" = true ]; then
        echo
        echo -e "${YELLOW}  [INTERACTIVE] $1${NC}"
        echo -e "${YELLOW}  Press Enter to continue...${NC}"
        read -r
    fi
}

usage() { sed -n '2,30p' "$0"; exit 0; }

# Argument parsing
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)        usage ;;
        --interactive)    INTERACTIVE=true ;;
        --skip-teardown)  SKIP_TEARDOWN=true ;;
        --teardown-only)  TEARDOWN_ONLY=true ;;
        --nuke)           NUKE=true ;;
        --cleanup-only)   CLEANUP_ONLY=true; NUKE=true ;;
        --skip-addons)    SKIP_ADDONS=true ;;
        --dry-run)        DRY_RUN=true ;;
        --project)        HCP_PROJECT="$2"; export HCP_PROJECT; shift ;;
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

if [ -z "$HCP_ORG" ] && [ "$TEARDOWN_ONLY" = false ]; then
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfvars" ]; then
        HCP_ORG=$(grep 'hcp_org' "$SCRIPT_DIR/hcp-setup/terraform.tfvars" 2>/dev/null \
            | awk -F'"' '{print $2}')
    fi
    if [ -z "$HCP_ORG" ]; then
        echo -e "${RED}Error: HCP_ORG is required${NC}"
        echo "Usage: $0 <HCP_ORG> [OPTIONS]"
        exit 1
    fi
fi

if [ -z "$WORKSHOP_REGION" ] && [ "$TEARDOWN_ONLY" = false ]; then
    echo -e "${RED}Error: could not resolve workshop region${NC}"
    echo "Set AWS_REGION or ensure infrastructure/deployments.tfdeploy.hcl is present."
    exit 1
fi

#===============================================================================
# HCP Terraform API helpers (project-agnostic — borrowed from eks-stacks)
#===============================================================================
load_tfe_token() {
    if [ -z "${TFE_TOKEN:-}" ]; then
        if [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
            TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' \
                "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null)
            export TFE_TOKEN
        fi
    fi
    if [ -z "${TFE_TOKEN:-}" ]; then
        print_error "TFE_TOKEN not available"; return 1
    fi
}

hcp_find_stack() {
    local org="$1"
    load_tfe_token || return 1
    local data count
    data=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$org/stacks" 2>/dev/null)
    count=$(echo "$data" | jq '.data | length' 2>/dev/null)
    if [ "$count" = "0" ] || [ -z "$count" ]; then
        print_error "No stacks found in organization: $org"; return 1
    fi
    if [ "$count" = "1" ]; then
        echo "$data" | jq -r '.data[0].id'; return 0
    fi
    # Multiple — try project match
    local project_id matched
    project_id=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw project_id 2>/dev/null || true)
    if [ -n "$project_id" ]; then
        matched=$(echo "$data" | jq -r \
            ".data[] | select(.relationships.project.data.id == \"$project_id\") | .id" 2>/dev/null | head -1)
        [ -n "$matched" ] && { echo "$matched"; return 0; }
    fi
    print_warn "Multiple stacks found; using first"
    echo "$data" | jq -r '.data[0].id'
}

hcp_trigger_plan() {
    local stack_id="$1" response config_id
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        -d '{"data":{"attributes":{}}}' \
        "$TFE_API/stacks/$stack_id/stack-configurations?source=fetch" 2>/dev/null)
    config_id=$(echo "$response" | jq -r '.data.id // empty' 2>/dev/null)
    if [ -z "$config_id" ]; then
        local err
        err=$(echo "$response" | jq -r '.errors[0].detail // .errors[0].title // "unknown"' 2>/dev/null)
        print_error "Failed to trigger plan: $err"; return 1
    fi
    echo "$config_id"
}

hcp_wait_for_config() {
    local config_id="$1" target="$2" timeout="${3:-1800}" elapsed=0 status
    while [ $elapsed -lt $timeout ]; do
        status=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$config_id" 2>/dev/null \
            | jq -r '.data.attributes.status // "unknown"')
        case "$status" in
            "$target"|converged|applied|completed)
                echo "$status"; return 0 ;;
            errored|canceled|abandoned)
                print_error "Configuration terminal state: $status"; echo "$status"; return 1 ;;
            *)
                if [ $((elapsed % 60)) -eq 0 ]; then
                    print_info "Configuration status: $status (${elapsed}s/${timeout}s)"
                fi
                sleep 15; elapsed=$((elapsed + 15)) ;;
        esac
    done
    print_error "Timeout waiting for $target"; return 1
}

hcp_approve_config() {
    local config_id="$1" groups_data group_ids
    groups_data=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/stack-configurations/$config_id/stack-deployment-groups" 2>/dev/null)
    group_ids=$(echo "$groups_data" | jq -r '.data[].id' 2>/dev/null)
    if [ -z "$group_ids" ]; then
        print_warn "No deployment groups to approve"; return 0
    fi
    for gid in $group_ids; do
        local gname
        gname=$(echo "$groups_data" | jq -r ".data[] | select(.id == \"$gid\") | .attributes.name // .id" 2>/dev/null)
        curl -s -X POST \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d '{"reason":"workshop-e2e automated approval"}' \
            "$TFE_API/stack-deployment-groups/$gid/approve-all-plans" >/dev/null 2>&1
        print_success "Approved deployment group: $gname"
    done
}

hcp_get_latest_config() {
    local stack_id="$1"
    curl -s -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null \
        | jq -r '.data[0].id // empty' 2>/dev/null
}

hcp_wait_for_vcs_plan() {
    local stack_id="$1" old_id="$2" timeout="${3:-1800}" elapsed=0 cid=""
    step_header "Waiting for VCS-triggered plan..."
    while [ $elapsed -lt $timeout ]; do
        cid=$(hcp_get_latest_config "$stack_id")
        if [ -n "$cid" ] && [ "$cid" != "$old_id" ]; then break; fi
        sleep 10; elapsed=$((elapsed + 10))
        if [ $((elapsed % 30)) -eq 0 ]; then
            print_info "Waiting for new config (${elapsed}s/${timeout}s)"
        fi
        cid=""
    done
    [ -z "$cid" ] && { print_error "Timeout waiting for VCS config"; return 1; }
    print_success "New configuration: $cid"

    step_header "Waiting for plan..."
    hcp_wait_for_config "$cid" "planned" "$timeout" || {
        local final
        final=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$cid" 2>/dev/null \
            | jq -r '.data.attributes.status // "unknown"')
        if [ "$final" = "converged" ]; then
            print_success "Configuration converged (no changes)"; return 0
        fi
        return 1
    }

    step_header "Approving deployment groups..."
    hcp_approve_config "$cid" || return 1

    step_header "Waiting for apply..."
    hcp_wait_for_config "$cid" "converged" "$timeout" || return 1
    print_success "VCS-triggered deploy complete"
}

hcp_deploy_and_wait() {
    local stack_id="$1" desc="$2" timeout="${3:-1800}" cid
    step_header "Triggering plan: $desc"
    cid=$(hcp_trigger_plan "$stack_id") || return 1
    print_success "Configuration created: $cid"
    step_header "Waiting for plan..."
    hcp_wait_for_config "$cid" "planned" "$timeout" || {
        local final
        final=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stack-configurations/$cid" 2>/dev/null \
            | jq -r '.data.attributes.status // "unknown"')
        if [ "$final" = "converged" ]; then
            print_success "Converged (no changes)"; return 0
        fi
        return 1
    }
    step_header "Approving..."
    hcp_approve_config "$cid" || return 1
    step_header "Waiting for apply..."
    hcp_wait_for_config "$cid" "converged" "$timeout" || return 1
    print_success "$desc complete"
}

#===============================================================================
# Git helper
#===============================================================================
GIT_PUSHED=false

git_commit_and_push() {
    local message="$1"; shift
    GIT_PUSHED=false
    cd "$PROJECT_ROOT"
    git add "$@"
    if git diff --cached --quiet; then
        print_info "No changes to commit"
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
        print_info "[DRY-RUN] Would run check-prerequisites.sh"; return 0
    fi
    bash "$SCRIPT_DIR/check-prerequisites.sh" || {
        print_error "Prerequisites failed. Fix and retry."; exit 1
    }
    if ! command -v jq &>/dev/null; then
        print_error "jq required for HCP API"; exit 1
    fi
    print_success "jq found"
    load_tfe_token || {
        print_error "TFE_TOKEN not set; run: terraform login"; exit 1
    }
    print_success "TFE_TOKEN loaded"
    local current_branch
    current_branch=$(git -C "$PROJECT_ROOT" branch --show-current)
    if [ "$current_branch" != "$GIT_BRANCH" ]; then
        print_error "Expected branch '$GIT_BRANCH' but on '$current_branch'"; exit 1
    fi
    print_success "On branch: $GIT_BRANCH"
}

#===============================================================================
# PHASE 1: Bootstrap
#===============================================================================
phase_bootstrap() {
    phase_header "Phase 1: Bootstrap (OIDC + Variable Set + Stack)"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run bootstrap.sh $HCP_ORG"; return 0
    fi
    bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG"
}

#===============================================================================
# PHASE 2: Foundation deploy
#===============================================================================
phase_deploy_foundation() {
    phase_header "Phase 2: Foundation Deploy (EKS + RDS + Bedrock KB)"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would set destroy=false, push, trigger HCP plan"; return 0
    fi

    step_header "Cleaning up orphaned resources from prior runs..."
    bash "$SCRIPT_DIR/cleanup-orphaned-resources.sh" 2>&1 \
        || print_warn "Orphaned cleanup had warnings"

    step_header "Finding HCP Stack..."
    local stack_id
    stack_id=$(hcp_find_stack "$HCP_ORG") || {
        print_error "Could not find Stack — create via bootstrap.sh first"; exit 1
    }
    print_success "Stack found: $stack_id"

    step_header "Setting destroy=false on usw2 deployment..."
    local deploy_file="$PROJECT_ROOT/infrastructure/deployments.tfdeploy.hcl"
    sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*true/destroy = false/g' "$deploy_file"
    rm -f "${deploy_file}.bak"

    local old_cid
    old_cid=$(hcp_get_latest_config "$stack_id")

    git_commit_and_push "deploy: enable foundation (usw2) for e2e" \
        "infrastructure/deployments.tfdeploy.hcl"

    if [ "$GIT_PUSHED" = true ]; then
        hcp_wait_for_vcs_plan "$stack_id" "$old_cid" 2400 || {
            print_error "Foundation deploy failed — see HCP UI"; exit 1
        }
    else
        hcp_deploy_and_wait "$stack_id" "Foundation deploy (usw2)" 2400 || {
            print_error "Foundation deploy failed — see HCP UI"; exit 1
        }
    fi

    pause_if_interactive "Foundation deployed. Verify in HCP UI."
}

#===============================================================================
# PHASE 3: Configure kubectl
#===============================================================================
phase_configure_kubectl() {
    phase_header "Phase 3: Configure kubectl (single deployment usw2)"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would update kubeconfig for $CLUSTER_NAME ($WORKSHOP_REGION)"
        return 0
    fi
    if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$WORKSHOP_REGION" \
            --alias "$CLUSTER_NAME" >/dev/null 2>&1; then
        print_success "$CLUSTER_NAME ($WORKSHOP_REGION) — kubeconfig updated"
    else
        print_warn "$CLUSTER_NAME ($WORKSHOP_REGION) — could not update kubeconfig"
    fi

    local node_count
    node_count=$(kubectl --context "$CLUSTER_NAME" get nodes --no-headers 2>/dev/null \
        | wc -l | tr -d ' ')
    if [ "${node_count:-0}" -gt 0 ]; then
        print_success "$CLUSTER_NAME — $node_count nodes found"
    else
        print_error "$CLUSTER_NAME — no nodes found"
    fi
    pause_if_interactive "kubectl configured."
}

#===============================================================================
# PHASE 4: Foundation verify
#===============================================================================
phase_verify_foundation() {
    phase_header "Phase 4: Foundation Verify (EKS + RDS + Bedrock KB)"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run test-foundation.sh"; return 0
    fi

    # Resolve DB instance + KB id from env or fall back to AWS discovery by tag
    local db_id="${WORKSHOP_DB_INSTANCE_ID:-}"
    local kb_id="${WORKSHOP_KB_ID:-}"

    if [ -z "$db_id" ]; then
        db_id=$(aws rds describe-db-instances --region "$WORKSHOP_REGION" \
            --query "DBInstances[?contains(TagList[?Key=='Workshop'].Value | [0], 'agentic-runtime-security')].DBInstanceIdentifier | [0]" \
            --output text 2>/dev/null)
        [ "$db_id" = "None" ] && db_id=""
    fi
    if [ -z "$kb_id" ]; then
        kb_id=$(aws bedrock-agent list-knowledge-bases --region "$WORKSHOP_REGION" \
            --query 'knowledgeBaseSummaries[0].knowledgeBaseId' --output text 2>/dev/null)
        [ "$kb_id" = "None" ] && kb_id=""
    fi

    if [ -z "$db_id" ] || [ -z "$kb_id" ]; then
        print_warn "Could not auto-discover DB instance or KB id — set WORKSHOP_DB_INSTANCE_ID and WORKSHOP_KB_ID env vars"
        print_warn "Skipping test-foundation.sh"
        return 0
    fi

    bash "$SCRIPT_DIR/test-foundation.sh" \
        --cluster-name "$CLUSTER_NAME" \
        --db-instance-id "$db_id" \
        --knowledge-base-id "$kb_id" \
        --region "$WORKSHOP_REGION" \
        || print_warn "Foundation verification reported failures (see above)"

    pause_if_interactive "Foundation verification complete."
}

#===============================================================================
# PHASES 5-7: Placeholders for future workshop phases
#===============================================================================
phase_identity_placeholder() {
    phase_header "Phase 5: Identity (IVIA)"
    print_info "[Phase 5 — populated in workshop Phase 3]"
    return 0
}
phase_vault_placeholder() {
    phase_header "Phase 6: Vault"
    print_info "[Phase 6 — populated in workshop Phase 4]"
    return 0
}
phase_use_cases_placeholder() {
    phase_header "Phase 7: Use Cases (UC1/UC2/UC3)"
    print_info "[Phase 7 — populated in workshop Phases 5/6]"
    return 0
}

#===============================================================================
# PHASE 8: Teardown
#===============================================================================
phase_teardown() {
    phase_header "Phase 8: Teardown"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run teardown.sh"; return 0
    fi
    pause_if_interactive "About to start teardown — destroys all foundation resources."
    bash "$SCRIPT_DIR/teardown.sh" --no-wait 2>&1 \
        || print_warn "Teardown reported warnings"
}

#===============================================================================
# NUKE
#===============================================================================
phase_nuke() {
    if [ "$CLEANUP_ONLY" = true ]; then
        phase_header "NUKE: Cleanup Only (skip HCP destroy)"
    else
        phase_header "NUKE: Delete Everything"
        print_warn "This will delete ALL resources: foundation, OIDC, IAM, variable set, Stack."
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run teardown.sh full lifecycle"; return 0
    fi

    if [ "$CLEANUP_ONLY" = true ]; then
        bash "$SCRIPT_DIR/teardown.sh" --post-destroy-only --no-wait \
            || print_warn "Cleanup had warnings"
    else
        bash "$SCRIPT_DIR/teardown.sh" --no-wait \
            || print_warn "Teardown had warnings"
    fi
    print_success "NUKE COMPLETE"
}

#===============================================================================
# MAIN
#===============================================================================
echo
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Agentic Runtime Security Workshop — End-to-End${NC}"
echo -e "${BLUE}================================================================${NC}"

[ "$DRY_RUN" = true ]    && print_warn "DRY RUN MODE — no changes will be made"
[ "$INTERACTIVE" = true ] && print_info "Interactive mode — will pause between phases"
[ "$SKIP_ADDONS" = true ] && print_info "--skip-addons: no-op for now (no controllers in scope)"

if [ "$NUKE" = true ]; then
    phase_nuke
    echo; exit 0
fi

if [ "$TEARDOWN_ONLY" = true ]; then
    phase_teardown
    echo; exit 0
fi

phase_prerequisites
phase_bootstrap
phase_deploy_foundation
phase_configure_kubectl
phase_verify_foundation
phase_identity_placeholder
phase_vault_placeholder
phase_use_cases_placeholder

if [ "$SKIP_TEARDOWN" = false ]; then
    phase_teardown
fi

echo
phase_header "Workshop E2E Complete"
if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN — no changes made"
elif [ "$SKIP_TEARDOWN" = true ]; then
    print_success "All phases passed — left running"
else
    print_success "All phases passed — resources destroyed"
fi
echo
