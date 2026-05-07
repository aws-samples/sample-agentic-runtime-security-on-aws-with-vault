#!/usr/bin/env bash
#===============================================================================
# Workshop Teardown — Agentic Runtime Security on AWS
#
# Phases:
#   Phase 0: Preflight (AWS creds, tools, cluster detection)
#   Phase 1: K8s pre-destroy cleanup (test workloads, IVIA, Vault)
#            Phase 3 of the workshop has not been built yet, so the IVIA + Vault
#            sub-routines are scaffolded as stubs and skipped if the namespaces
#            don't exist.
#   Phase 2: HCP destroy=true approval (manual pause; automated if TFE_TOKEN set)
#   Phase 3: Post-destroy orphaned-resource cleanup (calls cleanup-orphaned-resources.sh)
#   Phase 4: HCP Stack + variable set + IAM role + OIDC provider deletion
#
# Usage:
#   ./teardown.sh [OPTIONS] [cluster:region ...]
#
# Options:
#   --pre-destroy-only    Phase 0 + 1 only
#   --post-destroy-only   Phase 0 + 3 + 4 only
#   --skip-oidc-cleanup   Skip OIDC + IAM role deletion (keeps them around)
#   --dry-run             Print actions without executing
#   --no-wait             Don't pause for manual HCP destroy approval
#   --help                Show this help
#===============================================================================

set -e
export AWS_PAGER=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

DRY_RUN=false
PRE_DESTROY_ONLY=false
POST_DESTROY_ONLY=false
SKIP_OIDC_CLEANUP=false
NO_WAIT=false
CLUSTER_LIST=()
TFE_API="https://app.terraform.io/api/v2"
HCP_ROLE_NAME="hcp-terraform-stacks-role"

phase_header() { echo; echo -e "${BLUE}================================================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}================================================================${NC}"; }
step_header()  { echo; echo -e "${BLUE}--- Step $1: $2 ---${NC}"; }
print_success(){ echo -e "${GREEN}  $1${NC}"; }
print_error()  { echo -e "${RED}  $1${NC}"; }
print_info()   { echo -e "${BLUE}  $1${NC}"; }
print_warn()   { echo -e "${YELLOW}  $1${NC}"; }

usage() {
    cat <<USAGE

Usage: $0 [OPTIONS] [cluster:region ...]

Options:
  --pre-destroy-only    Phase 0+1 only (K8s cleanup)
  --post-destroy-only   Phase 0+3+4 only (orphaned resources + OIDC)
  --skip-oidc-cleanup   Skip OIDC + IAM role deletion
  --dry-run             Print actions without executing
  --no-wait             Skip manual pause for HCP destroy
  --help                Show this help

Default region: from \$AWS_REGION or infrastructure/deployments.tfdeploy.hcl
USAGE
}

# Argument parsing
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)             usage; exit 0 ;;
        --dry-run)             DRY_RUN=true ;;
        --pre-destroy-only)    PRE_DESTROY_ONLY=true ;;
        --post-destroy-only)   POST_DESTROY_ONLY=true ;;
        --skip-oidc-cleanup)   SKIP_OIDC_CLEANUP=true ;;
        --no-wait)             NO_WAIT=true ;;
        -*)                    echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
        *)                     CLUSTER_LIST+=("$1") ;;
    esac
    shift
done

if [ "$PRE_DESTROY_ONLY" = true ] && [ "$POST_DESTROY_ONLY" = true ]; then
    echo "ERROR: --pre-destroy-only and --post-destroy-only are mutually exclusive" >&2
    exit 1
fi

# Resolve default region
DEFAULT_REGION="${AWS_REGION:-}"
if [ -z "$DEFAULT_REGION" ]; then
    TF_DEPLOY="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
    if [ -f "$TF_DEPLOY" ]; then
        DEFAULT_REGION=$(grep -E '^\s*region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
fi

# Default cluster list — single deployment usw2
if [ ${#CLUSTER_LIST[@]} -eq 0 ]; then
    if [ -z "$DEFAULT_REGION" ]; then
        echo "ERROR: could not resolve region. Set AWS_REGION or pass cluster:region pairs." >&2
        exit 1
    fi
    CLUSTER_LIST=("eks-usw2:${DEFAULT_REGION}")
fi

#===============================================================================
# Phase 0: Preflight
#===============================================================================
phase_preflight() {
    phase_header "Phase 0: Preflight"

    step_header "0.1" "Verify required tools"
    local missing=0
    for tool in aws kubectl; do
        if command -v "$tool" &>/dev/null; then
            print_success "$tool found"
        else
            print_error "$tool not found"; missing=1
        fi
    done
    [ $missing -eq 1 ] && { print_error "Install missing tools"; exit 1; }

    step_header "0.2" "Verify AWS credentials"
    if aws sts get-caller-identity &>/dev/null; then
        local acct
        acct=$(aws sts get-caller-identity --query 'Account' --output text)
        print_success "AWS authenticated (account: ${acct})"
    else
        print_error "AWS credentials not configured. Run 'aws configure'."; exit 1
    fi

    step_header "0.3" "Detect active clusters"
    ACTIVE_CLUSTERS=()
    for item in "${CLUSTER_LIST[@]}"; do
        local cluster="${item%%:*}" region="${item##*:}"
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] Would check: $cluster in $region"
            ACTIVE_CLUSTERS+=("$item"); continue
        fi
        if aws eks describe-cluster --name "$cluster" --region "$region" &>/dev/null; then
            print_success "$cluster ($region) — exists"
            ACTIVE_CLUSTERS+=("$item")
        else
            print_warn "$cluster ($region) — not found, skipping"
        fi
    done
    print_info "Targeted: ${CLUSTER_LIST[*]}"
    print_info "Active:   ${ACTIVE_CLUSTERS[*]:-none}"
}

#===============================================================================
# Phase 1: K8s pre-destroy cleanup
#===============================================================================
cleanup_test_workloads() {
    local cluster="$1"
    print_info "Deleting test workloads on $cluster..."
    kubectl --context "$cluster" delete deployment skiapp --ignore-not-found 2>/dev/null || true
    kubectl --context "$cluster" delete service skiapp --ignore-not-found 2>/dev/null || true
    print_success "Test workloads cleaned up"
}

# IVIA + Vault placeholders — Phase 3 of the workshop has not been authored yet.
# The functions are scaffolded so Phase 3 can populate them without restructuring.
cleanup_ivia_cluster() {
    local cluster="$1"
    if kubectl --context "$cluster" get namespace verify-access &>/dev/null; then
        print_info "Cleaning up IVIA on ${cluster}..."
        # TODO(phase-3): delete IVIA Helm release + verify-access namespace
        kubectl --context "$cluster" delete namespace verify-access --ignore-not-found --timeout=120s 2>/dev/null || true
        print_success "IVIA namespace deleted"
    else
        print_info "IVIA namespace not found on $cluster — skipping"
    fi
}
cleanup_vault_cluster() {
    local cluster="$1"
    if kubectl --context "$cluster" get namespace vault &>/dev/null; then
        print_info "Cleaning up Vault on ${cluster}..."
        # TODO(phase-3): vault operator step-down + helm uninstall before namespace delete
        kubectl --context "$cluster" delete namespace vault --ignore-not-found --timeout=120s 2>/dev/null || true
        print_success "Vault namespace deleted"
    else
        print_info "Vault namespace not found on $cluster — skipping"
    fi
}

phase_pre_destroy() {
    phase_header "Phase 1: Pre-destroy K8s cleanup"

    if [ ${#ACTIVE_CLUSTERS[@]} -eq 0 ]; then
        print_info "No active clusters — skipping K8s cleanup"
        return 0
    fi

    for item in "${ACTIVE_CLUSTERS[@]}"; do
        local cluster="${item%%:*}" region="${item##*:}"
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] Would clean up workloads + IVIA + Vault on $cluster"
            continue
        fi
        step_header "1.x" "Pre-destroy on ${cluster} (${region})"
        aws eks update-kubeconfig --name "$cluster" --region "$region" --alias "$cluster" >/dev/null 2>&1 || {
            print_warn "Could not update kubeconfig for $cluster — skipping K8s cleanup"
            continue
        }
        cleanup_test_workloads "$cluster"
        cleanup_ivia_cluster   "$cluster"
        cleanup_vault_cluster  "$cluster"
    done
}

#===============================================================================
# Phase 2: HCP destroy=true approval (manual pause OR API automation)
#===============================================================================
load_tfe_token() {
    if [ -z "${TFE_TOKEN:-}" ] && [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
        TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' \
            "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null || true)
        export TFE_TOKEN
    fi
}

phase_hcp_destroy() {
    phase_header "Phase 2: HCP destroy=true approval"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would set destroy=true and wait for HCP plan approval"
        return 0
    fi

    load_tfe_token

    local deploy_file="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
    if [ ! -f "$deploy_file" ]; then
        print_warn "No deployments.tfdeploy.hcl — skipping Phase 2"
        return 0
    fi

    step_header "2.1" "Setting destroy=true on all deployments"
    sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*false/destroy = true/g' "$deploy_file"
    rm -f "${deploy_file}.bak"
    print_success "deployments.tfdeploy.hcl updated"

    if [ "$NO_WAIT" = true ]; then
        print_info "--no-wait set; not pausing. Commit/push the change manually and approve in HCP UI."
        return 0
    fi

    step_header "2.2" "Awaiting HCP destroy approval"
    cat <<EOF
  Manual steps:
    1. Commit + push: git commit -am "teardown: destroy=true" && git push
    2. Visit HCP Terraform UI and approve the destroy plan for the Stack
    3. Wait for convergence (status: applied / converged)
    4. Press Enter to continue here (or Ctrl-C to abort)

EOF
    if [ -t 0 ]; then
        read -r -p "  Press Enter when HCP destroy is complete... " _
    else
        print_warn "stdin not a TTY — skipping pause (assume HCP destroy already complete)"
    fi
}

#===============================================================================
# Phase 3: Orphaned AWS resource cleanup
#===============================================================================
phase_post_destroy() {
    phase_header "Phase 3: Orphaned AWS resource cleanup"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run cleanup-orphaned-resources.sh"
        return 0
    fi
    bash "$SCRIPT_DIR/cleanup-orphaned-resources.sh" "${CLUSTER_LIST[@]}" || \
        print_warn "Orphaned resource cleanup had warnings (continuing)"
}

#===============================================================================
# Phase 4: HCP Stack + variable set + IAM + OIDC delete
#===============================================================================
hcp_find_stack_for_org() {
    local org="$1"
    [ -z "${TFE_TOKEN:-}" ] && return 1
    curl -s -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$org/stacks" 2>/dev/null \
        | jq -r '.data[0].id // empty' 2>/dev/null
}

phase_hcp_aws_cleanup() {
    phase_header "Phase 4: HCP Stack + variable set + IAM + OIDC cleanup"
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would delete HCP Stack, variable set, IAM role, OIDC provider"
        return 0
    fi

    load_tfe_token

    # HCP Stack delete
    local hcp_org
    hcp_org=$(grep 'hcp_org' "$SCRIPT_DIR/hcp-setup/terraform.tfvars" 2>/dev/null \
        | awk -F'"' '{print $2}' || true)

    if [ -n "$hcp_org" ] && [ -n "${TFE_TOKEN:-}" ]; then
        step_header "4.1" "Deleting HCP Terraform Stack"
        local stack_id
        stack_id=$(hcp_find_stack_for_org "$hcp_org" || true)
        if [ -n "$stack_id" ]; then
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/stacks/$stack_id" 2>/dev/null)
            case "$code" in
                200|204) print_success "HCP Stack deleted (${stack_id})" ;;
                404)     print_info    "Stack already deleted" ;;
                *)       print_warn    "Stack delete returned HTTP $code — check HCP UI" ;;
            esac
        else
            print_info "No HCP Stack found for org $hcp_org"
        fi
    else
        print_info "No HCP_ORG / TFE_TOKEN available — skipping Stack delete"
    fi

    # Variable set destroy via terraform
    step_header "4.2" "Destroying HCP variable set"
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ]; then
        terraform -chdir="$SCRIPT_DIR/hcp-setup" destroy -auto-approve -input=false >/dev/null 2>&1 \
            && print_success "Variable set destroyed" \
            || print_warn "Variable set destroy had errors (may already be gone)"
    else
        print_info "No terraform state — variable set may already be destroyed"
    fi

    if [ "$SKIP_OIDC_CLEANUP" = true ]; then
        print_info "--skip-oidc-cleanup set — leaving IAM role + OIDC provider intact"
        return 0
    fi

    # IAM + OIDC
    step_header "4.3" "Deleting IAM role + OIDC provider"
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
        aws iam delete-role --role-name "$HCP_ROLE_NAME" 2>/dev/null \
            && print_success "IAM role deleted: $HCP_ROLE_NAME" \
            || print_warn "Could not delete IAM role"
    else
        print_info "IAM role not found — already deleted"
    fi

    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" &>/dev/null; then
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" 2>/dev/null \
            && print_success "OIDC provider deleted" \
            || print_warn "Could not delete OIDC provider"
    else
        print_info "OIDC provider not found — already deleted"
    fi
}

#===============================================================================
# MAIN
#===============================================================================
phase_preflight

if [ "$POST_DESTROY_ONLY" = true ]; then
    phase_post_destroy
    phase_hcp_aws_cleanup
elif [ "$PRE_DESTROY_ONLY" = true ]; then
    phase_pre_destroy
else
    phase_pre_destroy
    phase_hcp_destroy
    phase_post_destroy
    phase_hcp_aws_cleanup
fi

echo
phase_header "Teardown complete"
