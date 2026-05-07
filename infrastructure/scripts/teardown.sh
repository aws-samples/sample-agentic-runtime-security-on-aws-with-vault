#!/usr/bin/env bash
#===============================================================================
# Workshop Teardown — Agentic Runtime Security on AWS
#
# Adapted from ~/git-repos/eks-terraform-stacks/infrastructure/scripts/teardown.sh
#
# Single-command teardown that orchestrates the full workshop cleanup:
#   Phase 0: Preflight checks (AWS creds, tools, cluster detection)
#   Phase 1: Pre-destroy K8s cleanup (test workloads, IVIA, Vault stubs)
#   Phase 2: HCP destroy=true via API (push config, approve plans, wait)
#            Falls back to a manual pause when TFE_TOKEN is not available.
#   Phase 3: Post-destroy orphaned AWS resource cleanup
#            (delegates to cleanup-orphaned-resources.sh — sweeps ENIs, SGs,
#             VPC, NAT/EIP/IGW/RT/subnets, classic + v2 LBs)
#   Phase 4: HCP Stack + variable set + IAM role + OIDC provider deletion
#            Includes retry-with-OIDC-recreation when removing deployments
#            from a Stack whose IAM role / OIDC provider was deleted by a
#            prior teardown attempt.
#
# Single deployment: `eks-usw2` in the canonical workshop region (resolved
# from $AWS_REGION or infrastructure/deployments.tfdeploy.hcl). No 3-region
# loops — Phase 1 of this workshop is single-region by deliberate decision.
#
# Usage: ./scripts/teardown.sh [OPTIONS] [cluster:region ...]
#
# Options:
#   --dry-run              Show what would be done without executing
#   --pre-destroy-only     Phase 0+1 only (K8s cleanup)
#   --post-destroy-only    Phase 0+3+4 only (orphaned AWS + HCP cleanup)
#   --skip-oidc-cleanup    Skip IAM role + OIDC provider deletion in Phase 4
#   --no-wait              Skip pause for HCP manual steps (when TFE_TOKEN unset)
#   --help                 Show this help message
#===============================================================================

set -e

# Disable AWS CLI pager to prevent vi/less from capturing output
export AWS_PAGER=""

#-------------------------------------------------------------------------------
# Script directory + repo root
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

#-------------------------------------------------------------------------------
# Color constants (inline — keep parity with eks-stacks teardown.sh; do NOT
# source common-checks.sh here because that installs an EXIT trap that
# emits a "checks passed" summary, which is wrong for a teardown orchestrator.)
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Workshop conventions
#-------------------------------------------------------------------------------
HCP_ROLE_NAME="hcp-stacks-deploy"
HCP_STACK_NAME="agentic-runtime-security"
# shellcheck disable=SC2034 # reserved for future --project flag wiring (parity with bootstrap.sh)
HCP_PROJECT_NAME="Agentic Runtime Security"
# Variable-set name as configured in infrastructure/deployments.tfdeploy.hcl
# (`store "varset" "config" { name = "agentic-runtime-stacks-config" }`)
HCP_VARSET_NAME="agentic-runtime-stacks-config"
WORKSHOP_TAG="Workshop=agentic-runtime-security"
TFE_API="https://app.terraform.io/api/v2"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
DRY_RUN=false
PRE_DESTROY_ONLY=false
POST_DESTROY_ONLY=false
SKIP_OIDC_CLEANUP=false
NO_WAIT=false
CLUSTER_LIST=()

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
step_header() {
    local step_num="$1"
    local step_name="$2"
    echo ""
    echo -e "${BLUE}--- Step $step_num: $step_name ---${NC}"
}

phase_header() {
    local phase="$1"
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $phase${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_success() { echo -e "${GREEN}  $1${NC}"; }
print_error()   { echo -e "${RED}  $1${NC}"; }
print_info()    { echo -e "${BLUE}  $1${NC}"; }
print_warn()    { echo -e "${YELLOW}  $1${NC}"; }

usage() {
    cat <<USAGE

Usage: $0 [OPTIONS] [cluster:region ...]

Orchestrates the full workshop teardown.

Options:
  --dry-run              Show what would be done without executing
  --pre-destroy-only     Phase 0+1 only (K8s cleanup)
  --post-destroy-only    Phase 0+3+4 only (orphaned AWS + HCP cleanup)
  --skip-oidc-cleanup    Skip IAM role + OIDC provider deletion
  --no-wait              Skip pause for HCP manual steps
  --help                 Show this help message

Default cluster: eks-usw2 (region resolved from \$AWS_REGION or
                 infrastructure/deployments.tfdeploy.hcl).

Examples:
  $0                                # Full teardown
  $0 --dry-run                      # Preview all phases
  $0 --pre-destroy-only             # K8s cleanup only
  $0 --post-destroy-only            # Orphaned resource + HCP cleanup
  $0 eks-usw2:\$AWS_REGION          # Explicit cluster:region
USAGE
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)             usage; exit 0 ;;
        --dry-run)             DRY_RUN=true ;;
        --pre-destroy-only)    PRE_DESTROY_ONLY=true ;;
        --post-destroy-only)   POST_DESTROY_ONLY=true ;;
        --skip-oidc-cleanup)   SKIP_OIDC_CLEANUP=true ;;
        --no-wait)             NO_WAIT=true ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}" >&2
            usage
            exit 1
            ;;
        *)                     CLUSTER_LIST+=("$1") ;;
    esac
    shift
done

if [ "$PRE_DESTROY_ONLY" = true ] && [ "$POST_DESTROY_ONLY" = true ]; then
    echo -e "${RED}Error: --pre-destroy-only and --post-destroy-only are mutually exclusive${NC}" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# Region resolution (canonical-region contract: no region literal here —
# resolve from $AWS_REGION or infrastructure/deployments.tfdeploy.hcl)
#-------------------------------------------------------------------------------
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
        echo -e "${RED}Error: could not resolve region. Set AWS_REGION or pass cluster:region pairs.${NC}" >&2
        exit 1
    fi
    CLUSTER_LIST=("eks-usw2:${DEFAULT_REGION}")
fi

#-------------------------------------------------------------------------------
# TFE token loader (auto-load from ~/.terraform.d/credentials.tfrc.json)
#-------------------------------------------------------------------------------
load_tfe_token() {
    if [ -z "${TFE_TOKEN:-}" ] && [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
        TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' \
            "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null || true)
        export TFE_TOKEN
    fi
}

#===============================================================================
# PHASE 0: Preflight
#===============================================================================
phase_preflight() {
    phase_header "Phase 0: Preflight Checks"

    step_header "0.1" "Verify required tools"
    local missing=0
    for tool in aws kubectl terraform jq curl; do
        if command -v "$tool" &>/dev/null; then
            print_success "$tool found"
        else
            print_error "$tool not found"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        print_error "Install missing tools before proceeding"
        exit 1
    fi

    step_header "0.2" "Verify AWS credentials"
    if aws sts get-caller-identity &>/dev/null; then
        local account_id
        account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        print_success "AWS authenticated (account: $account_id)"
    else
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi

    step_header "0.3" "Verify hcp-setup module"
    if [ -f "$SCRIPT_DIR/hcp-setup/main.tf" ]; then
        print_success "hcp-setup module found"
    else
        print_warn "hcp-setup module not found at $SCRIPT_DIR/hcp-setup/"
        print_info "Stack/varset deletion in Phase 4 will be skipped"
    fi

    step_header "0.4" "Detect active clusters"
    ACTIVE_CLUSTERS=()
    for item in "${CLUSTER_LIST[@]}"; do
        local cluster="${item%%:*}"
        local region="${item##*:}"
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] Would check: $cluster in $region"
            ACTIVE_CLUSTERS+=("$item")
        else
            if aws eks describe-cluster --name "$cluster" --region "$region" &>/dev/null; then
                print_success "$cluster ($region) -- exists"
                ACTIVE_CLUSTERS+=("$item")
            else
                print_warn "$cluster ($region) -- not found, skipping"
            fi
        fi
    done

    echo ""
    print_info "Cluster targeted: ${CLUSTER_LIST[*]}"
    print_info "Active cluster:   ${ACTIVE_CLUSTERS[*]:-none}"
    print_info "Region:           ${DEFAULT_REGION:-<unresolved>}"
    if [ "$DRY_RUN" = true ]; then
        print_warn "DRY RUN MODE -- no changes will be made"
    fi
}

#===============================================================================
# PHASE 1: Pre-destroy K8s cleanup
#
# Karpenter and ArgoCD are OUT of scope for this workshop (see CLAUDE.md) so
# the equivalent eks-stacks blocks are intentionally absent. IVIA + Vault
# placeholders below will be populated when workshop Phase 3/4 ships.
#===============================================================================

# Wait for LB-controller-managed AWS resources (NLBs, ALBs, k8s-* SGs) to be
# cleaned up after K8s Service deletion. Without this, VPC delete in Phase 3
# fails with DependencyViolation. Adapted verbatim from eks-stacks.
cleanup_lb_resources_cluster() {
    local cluster="$1"
    local region="$2"

    local vpc_id
    vpc_id=$(aws eks describe-cluster --name "$cluster" --region "$region" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        print_warn "Could not determine VPC ID for $cluster -- skipping LB resource cleanup"
        return 0
    fi

    print_info "Checking for LB-controller-managed AWS resources in VPC $vpc_id..."

    # Wait for LoadBalancers to be deleted (triggered by K8s Service deletion)
    local timeout=180
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local lb_arns
        lb_arns=$(aws elbv2 describe-load-balancers --region "$region" \
            --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null)
        if [ -z "$lb_arns" ] || [ "$lb_arns" = "None" ]; then
            print_success "No LoadBalancers remaining in VPC"
            break
        fi
        if [ $elapsed -eq 0 ]; then
            print_info "LoadBalancers still being deleted by LB controller..."
        fi
        print_info "Waiting for LB deletion... (${elapsed}s/${timeout}s)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    # Force-delete any LoadBalancers that didn't get cleaned up
    local force_deleted=false
    local remaining_lbs
    remaining_lbs=$(aws elbv2 describe-load-balancers --region "$region" \
        --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null)
    if [ -n "$remaining_lbs" ] && [ "$remaining_lbs" != "None" ]; then
        force_deleted=true
        print_warn "Force-deleting orphaned LoadBalancers..."
        for lb_arn in $remaining_lbs; do
            aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$lb_arn" 2>/dev/null || true
            print_info "Deleted: $lb_arn"
        done
        sleep 30
    fi

    # If we force-deleted LBs, restart the LB controller to clear cached state
    if [ "$force_deleted" = true ]; then
        print_info "Restarting AWS Load Balancer Controller to clear stale state..."
        kubectl rollout restart deployment -n kube-system aws-load-balancer-controller 2>/dev/null || true
        kubectl rollout status deployment -n kube-system aws-load-balancer-controller --timeout=120s 2>/dev/null || \
            print_warn "LB controller restart timed out -- continuing anyway"
        print_success "LB controller restarted"
    fi

    # Delete orphaned k8s-* security groups
    local orphan_sgs
    orphan_sgs=$(aws ec2 describe-security-groups --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" --output text 2>/dev/null)
    if [ -n "$orphan_sgs" ] && [ "$orphan_sgs" != "None" ]; then
        print_info "Cleaning up orphaned k8s-* security groups..."

        # Pass 1: strip rules ON the k8s-* SGs themselves
        for sg in $orphan_sgs; do
            local ingress_rules
            ingress_rules=$(aws ec2 describe-security-group-rules --region "$region" \
                --filters "Name=group-id,Values=$sg" \
                --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null)
            if [ -n "$ingress_rules" ] && [ "$ingress_rules" != "None" ]; then
                # shellcheck disable=SC2086
                aws ec2 revoke-security-group-ingress --region "$region" --group-id "$sg" \
                    --security-group-rule-ids $ingress_rules 2>/dev/null || true
            fi
            local egress_rules
            egress_rules=$(aws ec2 describe-security-group-rules --region "$region" \
                --filters "Name=group-id,Values=$sg" \
                --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null)
            if [ -n "$egress_rules" ] && [ "$egress_rules" != "None" ]; then
                # shellcheck disable=SC2086
                aws ec2 revoke-security-group-egress --region "$region" --group-id "$sg" \
                    --security-group-rule-ids $egress_rules 2>/dev/null || true
            fi
        done

        # Pass 2: strip rules in OTHER VPC SGs that reference k8s-* SGs
        local all_vpc_sgs
        all_vpc_sgs=$(aws ec2 describe-security-groups --region "$region" \
            --filters "Name=vpc-id,Values=${vpc_id}" \
            --query "SecurityGroups[].GroupId" --output text 2>/dev/null)
        for sg in $orphan_sgs; do
            for other_sg in $all_vpc_sgs; do
                [ "$other_sg" = "$sg" ] && continue
                local cross_refs
                cross_refs=$(aws ec2 describe-security-group-rules --region "$region" \
                    --filters "Name=group-id,Values=$other_sg" \
                    --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='${sg}'].SecurityGroupRuleId" \
                    --output text 2>/dev/null)
                if [ -n "$cross_refs" ] && [ "$cross_refs" != "None" ]; then
                    print_info "Removing cross-reference rules in $other_sg -> $sg"
                    for rule_id in $cross_refs; do
                        aws ec2 revoke-security-group-ingress --region "$region" \
                            --group-id "$other_sg" --security-group-rule-ids "$rule_id" 2>/dev/null || \
                        aws ec2 revoke-security-group-egress --region "$region" \
                            --group-id "$other_sg" --security-group-rule-ids "$rule_id" 2>/dev/null || true
                    done
                fi
            done
        done

        # Pass 3: delete the k8s-* SGs (dependencies should be cleared now)
        for sg in $orphan_sgs; do
            aws ec2 delete-security-group --region "$region" --group-id "$sg" 2>/dev/null && \
                print_success "Deleted SG: $sg" || \
                print_warn "Could not delete SG: $sg (may still have dependencies)"
        done
    else
        print_success "No orphaned k8s-* security groups found"
    fi
}

# Delete any LoadBalancer Services / test workloads that may have created
# AWS LBs out-of-band. Workshop content does not currently ship test
# workloads, so this is a no-op fast path; left in place so Phase 3/4
# content can extend without restructuring.
cleanup_test_workloads() {
    local cluster="$1"
    print_info "Cleaning up test workloads on ${cluster} (none expected)..."
    # TODO(phase-3/4): delete workshop demo workloads here when they ship
    print_success "Test workload sweep complete"
}

# IVIA placeholder — populated when workshop Phase 3/4 ships the IBM Verify
# Identity Access Helm release + verify-access namespace.
cleanup_ivia_cluster() {
    local cluster="$1"
    if kubectl --context "$cluster" get namespace verify-access &>/dev/null; then
        print_info "Cleaning up IVIA on ${cluster}..."
        # TODO(phase-3/4): helm uninstall + remove CRDs before namespace delete
        kubectl --context "$cluster" delete namespace verify-access --ignore-not-found --timeout=120s 2>/dev/null || true
        print_success "IVIA namespace deleted"
    else
        print_info "IVIA namespace not found on $cluster -- skipping"
    fi
}

# Vault placeholder — populated when workshop Phase 3/4 ships the HashiCorp
# Vault Helm release + vault namespace.
cleanup_vault_cluster() {
    local cluster="$1"
    if kubectl --context "$cluster" get namespace vault &>/dev/null; then
        print_info "Cleaning up Vault on ${cluster}..."
        # TODO(phase-3/4): vault operator step-down + helm uninstall before namespace delete
        kubectl --context "$cluster" delete namespace vault --ignore-not-found --timeout=120s 2>/dev/null || true
        print_success "Vault namespace deleted"
    else
        print_info "Vault namespace not found on $cluster -- skipping"
    fi
}

phase_pre_destroy() {
    phase_header "Phase 1: Pre-Destroy K8s Cleanup"

    if [ ${#ACTIVE_CLUSTERS[@]} -eq 0 ]; then
        print_warn "No active clusters found -- skipping Phase 1"
        return 0
    fi

    step_header "1.1" "Per-cluster K8s cleanup"

    for item in "${ACTIVE_CLUSTERS[@]}"; do
        local cluster="${item%%:*}"
        local region="${item##*:}"

        echo ""
        print_info "=== $cluster ($region) ==="

        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] Would update kubeconfig for $cluster"
            print_info "[DRY-RUN] Would clean up test workloads, IVIA, Vault namespaces"
            print_info "[DRY-RUN] Would wait for LB-controller AWS resources (NLBs, k8s-* SGs)"
            continue
        fi

        # Update kubeconfig for this cluster
        aws eks update-kubeconfig --name "$cluster" --region "$region" --alias "$cluster" >/dev/null 2>&1 || {
            print_warn "Could not update kubeconfig for $cluster -- skipping K8s cleanup"
            continue
        }
        kubectl config use-context "$cluster" >/dev/null 2>&1 || true
        print_success "Kubeconfig updated for $cluster"

        cleanup_test_workloads     "$cluster"
        cleanup_ivia_cluster       "$cluster"
        cleanup_vault_cluster      "$cluster"
        cleanup_lb_resources_cluster "$cluster" "$region"
    done

    echo ""
    print_success "Phase 1 complete"
}

#===============================================================================
# PHASE 2: HCP destroy=true via API (with manual fallback)
#
# Sets destroy=true in the deployment block, pushes the change, triggers a
# plan, approves the destroy plan, and waits for convergence. When TFE_TOKEN
# is unavailable, falls back to a manual pause prompting the user to commit
# and approve via the HCP UI.
#===============================================================================

phase_hcp_destroy() {
    phase_header "Phase 2: HCP Stack Destroy (destroy=true)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would set destroy=true and trigger HCP destroy plan"
        return 0
    fi

    load_tfe_token

    local deploy_file="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
    if [ ! -f "$deploy_file" ]; then
        print_warn "No deployments.tfdeploy.hcl -- skipping Phase 2"
        return 0
    fi

    step_header "2.1" "Set destroy=true on deployment"
    sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*false/destroy          = true/g' "$deploy_file"
    rm -f "${deploy_file}.bak"
    if grep -qE 'destroy[[:space:]]*=[[:space:]]*true' "$deploy_file"; then
        print_success "deployments.tfdeploy.hcl now has destroy=true"
    else
        print_warn "Could not confirm destroy=true edit -- inspect manually"
    fi

    # If we don't have an API token, fall back to manual pause
    if [ -z "${TFE_TOKEN:-}" ]; then
        step_header "2.2" "Manual HCP destroy approval (no TFE_TOKEN)"
        cat <<EOF

  Manual steps:
    1. Commit + push:
         git add infrastructure/deployments.tfdeploy.hcl
         git commit -m "teardown: destroy=true"
         git push
    2. In HCP Terraform UI, approve the destroy plan for stack '${HCP_STACK_NAME}'
    3. Wait for the deployment to converge

EOF
        if [ "$NO_WAIT" = true ]; then
            print_info "--no-wait set; not pausing"
        elif [ -t 0 ]; then
            read -r -p "  Press Enter when HCP destroy is complete... " _
        else
            print_warn "stdin not a TTY -- assuming HCP destroy already complete"
        fi
        return 0
    fi

    #---------------------------------------------------------------------------
    # API-driven path: commit + push + approve + wait for convergence
    #---------------------------------------------------------------------------
    step_header "2.2" "Resolve HCP organization and stack"

    local hcp_org=""
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfvars" ]; then
        hcp_org=$(grep -E '^\s*tfc_organization|^\s*hcp_org' "$SCRIPT_DIR/hcp-setup/terraform.tfvars" 2>/dev/null \
            | head -1 | awk -F'"' '{print $2}')
    fi
    if [ -z "$hcp_org" ] && [ -d "$SCRIPT_DIR/hcp-setup" ]; then
        hcp_org=$(terraform -chdir="$SCRIPT_DIR/hcp-setup" output -raw organization 2>/dev/null || true)
    fi

    if [ -z "$hcp_org" ]; then
        print_warn "Could not resolve HCP org -- skipping API-driven destroy"
        print_info "Approve destroy plan manually in HCP UI for stack '${HCP_STACK_NAME}'"
        return 0
    fi
    print_success "HCP org: $hcp_org"

    local stack_id
    stack_id=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/organizations/$hcp_org/stacks" 2>/dev/null \
        | jq -r --arg n "$HCP_STACK_NAME" '.data[] | select(.attributes.name==$n) | .id' 2>/dev/null \
        | head -1)

    if [ -z "$stack_id" ]; then
        print_warn "Stack '${HCP_STACK_NAME}' not found in org $hcp_org -- skipping"
        return 0
    fi
    print_success "Stack id: $stack_id"

    step_header "2.3" "Commit + push destroy=true config"
    local git_branch
    git_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)

    # Capture pre-push config id so we can detect the new run
    local pre_push_config
    pre_push_config=$(curl -s \
        -H "Authorization: Bearer $TFE_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null \
        | jq -r '.data[0].id // empty' 2>/dev/null)

    if [ -n "$git_branch" ]; then
        git -C "$REPO_ROOT" add "$deploy_file" 2>/dev/null || true
        if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
            git -C "$REPO_ROOT" commit -m "teardown: destroy=true" >/dev/null 2>&1
            git -C "$REPO_ROOT" push origin "$git_branch" >/dev/null 2>&1 \
                && print_success "Pushed destroy=true to $git_branch" \
                || print_warn "Could not push to $git_branch (continuing — HCP may auto-fetch)"
        else
            print_info "Nothing to commit (config already destroy=true) -- triggering API fetch"
            curl -s -X POST \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                -d '{"data":{"attributes":{}}}' \
                "$TFE_API/stacks/$stack_id/stack-configurations?source=fetch" >/dev/null 2>&1
        fi
    else
        print_warn "Not on a git branch -- skipping push"
    fi

    if [ "$NO_WAIT" = true ]; then
        print_info "--no-wait set -- not waiting for destroy convergence"
        return 0
    fi

    step_header "2.4" "Approve destroy plan + wait for convergence"
    print_info "Polling stack-configurations (up to 20 min)..."
    local approved=false
    local wait=0
    local max_wait=1200
    while [ $wait -lt $max_wait ]; do
        local latest
        latest=$(curl -s \
            -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null)
        local status config_id
        status=$(echo "$latest" | jq -r '.data[0].attributes.status // "unknown"' 2>/dev/null)
        config_id=$(echo "$latest" | jq -r '.data[0].id // empty' 2>/dev/null)

        case "$status" in
            planned)
                if [ "$approved" = false ] && [ -n "$config_id" ]; then
                    print_info "Plan ready -- approving destroy..."
                    local groups
                    groups=$(curl -s \
                        -H "Authorization: Bearer $TFE_TOKEN" \
                        -H "Content-Type: application/vnd.api+json" \
                        "$TFE_API/stack-configurations/$config_id/stack-deployment-groups" 2>/dev/null \
                        | jq -r '.data[].id' 2>/dev/null)
                    for gid in $groups; do
                        curl -s -X POST \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            -d '{"reason":"teardown: destroy deployments"}' \
                            "$TFE_API/stack-deployment-groups/$gid/approve-all-plans" >/dev/null 2>&1
                    done
                    approved=true
                    print_success "Destroy plan approved"
                fi
                ;;
            converged|completed)
                if [ "$config_id" != "$pre_push_config" ]; then
                    print_success "Destroy converged"
                    return 0
                fi
                ;;
            errored|failed)
                if [ "$config_id" != "$pre_push_config" ]; then
                    print_warn "Destroy config $status -- inspect HCP UI"
                    return 0
                fi
                ;;
        esac

        sleep 15
        wait=$((wait + 15))
        if [ $((wait % 60)) -eq 0 ]; then
            print_info "Status: $status (${wait}s/${max_wait}s)"
        fi
    done
    print_warn "Timeout waiting for destroy convergence -- continuing"
}

#===============================================================================
# PHASE 3: Post-destroy orphaned AWS resource cleanup
#===============================================================================
phase_post_destroy() {
    phase_header "Phase 3: Post-Destroy (Orphaned Resource Cleanup)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: cleanup-orphaned-resources.sh ${CLUSTER_LIST[*]}"
        return 0
    fi

    print_info "Running orphaned resource cleanup..."
    echo ""

    # cleanup-orphaned-resources.sh requires Bash 4+ (associative arrays)
    local bash_cmd="bash"
    if [[ "$(uname)" == "Darwin" ]] && [[ -x /opt/homebrew/bin/bash ]]; then
        bash_cmd="/opt/homebrew/bin/bash"
    fi

    if $bash_cmd "$SCRIPT_DIR/cleanup-orphaned-resources.sh" "${CLUSTER_LIST[@]}"; then
        print_success "Orphaned resource cleanup complete"
    else
        print_warn "Orphaned resource cleanup finished with errors"
        print_info "Re-run cleanup-orphaned-resources.sh or clean up manually"
    fi
}

#===============================================================================
# PHASE 4: HCP Stack + variable set + IAM role + OIDC provider deletion
#
# Includes retry-with-OIDC-recreation: if a previous teardown deleted the
# IAM role / OIDC provider while a Stack still has deployments, HCP cannot
# run the destroy plan needed to remove them. Detect that case and re-run
# setup-aws-oidc.sh to recreate the credentials before pushing destroy=true.
#===============================================================================

phase_oidc_cleanup() {
    phase_header "Phase 4: HCP Stack + Variable Set + IAM + OIDC Cleanup"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would delete HCP Stack, variable set, IAM role, OIDC provider"
        return 0
    fi

    load_tfe_token

    local hcp_setup_dir="$SCRIPT_DIR/hcp-setup"
    local stack_deleted=false

    #---------------------------------------------------------------------------
    # Step 4.1: Delete HCP Stack via API
    #---------------------------------------------------------------------------
    step_header "4.1" "Delete HCP Terraform Stack"

    if [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not available -- skipping Stack deletion"
        print_info "Set with: export TFE_TOKEN=\$(jq -r '.credentials[\"app.terraform.io\"].token' ~/.terraform.d/credentials.tfrc.json)"
    else
        # Resolve org
        local hcp_org=""
        if [ -f "$hcp_setup_dir/terraform.tfvars" ]; then
            hcp_org=$(grep -E '^\s*tfc_organization|^\s*hcp_org' "$hcp_setup_dir/terraform.tfvars" 2>/dev/null \
                | head -1 | awk -F'"' '{print $2}')
        fi
        if [ -z "$hcp_org" ] && [ -d "$hcp_setup_dir" ]; then
            hcp_org=$(terraform -chdir="$hcp_setup_dir" output -raw organization 2>/dev/null || true)
        fi

        if [ -z "$hcp_org" ]; then
            print_warn "Could not determine HCP org -- skipping Stack deletion"
            print_info "Delete manually: HCP Terraform > Stack > Settings > Destruction and Deletion"
        else
            local stack_id
            stack_id=$(curl -s \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/organizations/$hcp_org/stacks" 2>/dev/null \
                | jq -r --arg n "$HCP_STACK_NAME" '.data[] | select(.attributes.name==$n) | .id' 2>/dev/null \
                | head -1)

            if [ -z "$stack_id" ]; then
                stack_deleted=true
                print_info "No HCP Stack '${HCP_STACK_NAME}' found -- already deleted"
            else
                # Check for deployments still attached to the Stack
                local deploy_count
                deploy_count=$(curl -s \
                    -H "Authorization: Bearer $TFE_TOKEN" \
                    -H "Content-Type: application/vnd.api+json" \
                    "$TFE_API/stacks/$stack_id/stack-deployments" 2>/dev/null \
                    | jq '.data | length' 2>/dev/null)

                if [ "${deploy_count:-0}" -gt 0 ]; then
                    print_info "$deploy_count deployment(s) still attached -- removing before Stack delete"

                    # Retry-with-OIDC-recreation: HCP needs valid credentials to
                    # process the destroy plan that removes deployments.
                    local account_id_pre
                    account_id_pre=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
                    local oidc_arn_pre="arn:aws:iam::${account_id_pre}:oidc-provider/app.terraform.io"

                    if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn_pre" &>/dev/null || \
                       ! aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
                        print_info "OIDC/IAM credentials missing -- recreating for deployment removal..."
                        if [ -x "$SCRIPT_DIR/setup-aws-oidc.sh" ]; then
                            bash "$SCRIPT_DIR/setup-aws-oidc.sh" "$hcp_org" 2>&1 || {
                                print_error "OIDC setup failed"
                                return 1
                            }
                            print_success "OIDC + IAM role recreated"
                        else
                            print_warn "setup-aws-oidc.sh not found -- cannot recreate OIDC"
                        fi
                    fi

                    # Ensure variable set exists (HCP needs the store block)
                    if [ -f "$hcp_setup_dir/terraform.tfvars" ]; then
                        print_info "Ensuring variable set exists..."
                        terraform -chdir="$hcp_setup_dir" init -input=false >/dev/null 2>&1 || true
                        terraform -chdir="$hcp_setup_dir" apply -auto-approve -input=false >/dev/null 2>&1 \
                            && print_success "Variable set ready" \
                            || print_warn "Variable set apply had issues (continuing)"
                    fi

                    # Push destroy=true config so HCP runs a valid destroy plan
                    local deploy_file="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
                    if [ -f "$deploy_file" ]; then
                        sed -i.bak 's/destroy[[:space:]]*=[[:space:]]*false/destroy          = true/g' "$deploy_file"
                        rm -f "${deploy_file}.bak"
                    fi

                    local git_branch
                    git_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)

                    local pre_push_config
                    pre_push_config=$(curl -s \
                        -H "Authorization: Bearer $TFE_TOKEN" \
                        -H "Content-Type: application/vnd.api+json" \
                        "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null \
                        | jq -r '.data[0].id // empty' 2>/dev/null)

                    if [ -n "$git_branch" ] && [ -f "$deploy_file" ]; then
                        git -C "$REPO_ROOT" add "$deploy_file" 2>/dev/null || true
                        if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
                            git -C "$REPO_ROOT" commit -m "teardown: destroy=true" >/dev/null 2>&1
                            git -C "$REPO_ROOT" push origin "$git_branch" >/dev/null 2>&1 || true
                            print_success "Pushed destroy=true to $git_branch"
                        else
                            print_info "Triggering config fetch via API..."
                            curl -s -X POST \
                                -H "Authorization: Bearer $TFE_TOKEN" \
                                -H "Content-Type: application/vnd.api+json" \
                                -d '{"data":{"attributes":{}}}' \
                                "$TFE_API/stacks/$stack_id/stack-configurations?source=fetch" >/dev/null 2>&1
                        fi
                    fi

                    # Wait for destroy plan to converge (approve along the way)
                    print_info "Waiting for destroy config to converge (up to 12 min)..."
                    local dep_wait=0
                    local approved_destroy=false
                    while [ $dep_wait -lt 720 ]; do
                        local latest_config
                        latest_config=$(curl -s \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=1" 2>/dev/null)
                        local config_status config_id
                        config_status=$(echo "$latest_config" | jq -r '.data[0].attributes.status // "unknown"' 2>/dev/null)
                        config_id=$(echo "$latest_config" | jq -r '.data[0].id // empty' 2>/dev/null)

                        case "$config_status" in
                            planned)
                                if [ "$approved_destroy" = false ] && [ -n "$config_id" ]; then
                                    print_info "Plans ready -- approving..."
                                    local groups
                                    groups=$(curl -s \
                                        -H "Authorization: Bearer $TFE_TOKEN" \
                                        -H "Content-Type: application/vnd.api+json" \
                                        "$TFE_API/stack-configurations/$config_id/stack-deployment-groups" 2>/dev/null \
                                        | jq -r '.data[].id' 2>/dev/null)
                                    for gid in $groups; do
                                        curl -s -X POST \
                                            -H "Authorization: Bearer $TFE_TOKEN" \
                                            -H "Content-Type: application/vnd.api+json" \
                                            -d '{"reason":"teardown: destroy deployments"}' \
                                            "$TFE_API/stack-deployment-groups/$gid/approve-all-plans" >/dev/null 2>&1
                                    done
                                    approved_destroy=true
                                    print_success "Destroy plans approved"
                                fi
                                ;;
                            converged|completed)
                                if [ "$config_id" != "$pre_push_config" ]; then
                                    print_success "Destroy config converged"
                                    break
                                fi
                                ;;
                            errored|failed)
                                if [ "$config_id" != "$pre_push_config" ]; then
                                    print_warn "Config $config_status -- deployment removal may not complete"
                                    break
                                fi
                                ;;
                        esac

                        sleep 15
                        dep_wait=$((dep_wait + 15))
                        if [ $((dep_wait % 60)) -eq 0 ]; then
                            print_info "Config status: $config_status (${dep_wait}s/720s)"
                        fi
                    done

                    # Now remove deployment blocks entirely
                    print_info "Removing deployment blocks from config..."
                    if [ -f "$deploy_file" ]; then
                        cat > "$deploy_file" <<'MINIMAL_HCL'
# Teardown: deployment blocks removed for Stack deletion
identity_token "aws" {
  audience = ["aws.workload.identity"]
}
MINIMAL_HCL
                    fi

                    if [ -n "$git_branch" ] && [ -f "$deploy_file" ]; then
                        git -C "$REPO_ROOT" add "$deploy_file" 2>/dev/null || true
                        if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
                            git -C "$REPO_ROOT" commit -m "teardown: remove deployment blocks" >/dev/null 2>&1
                            git -C "$REPO_ROOT" push origin "$git_branch" >/dev/null 2>&1 || true
                            print_success "Pushed empty config to $git_branch"
                        fi
                    fi

                    # Wait for deployments to disappear
                    print_info "Waiting for deployment records to be removed (up to 5 min)..."
                    dep_wait=0
                    while [ $dep_wait -lt 300 ]; do
                        deploy_count=$(curl -s \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stacks/$stack_id/stack-deployments" 2>/dev/null \
                            | jq '.data | length' 2>/dev/null)
                        if [ "${deploy_count:-0}" -eq 0 ]; then
                            print_success "All deployments removed from Stack"
                            break
                        fi
                        sleep 15
                        dep_wait=$((dep_wait + 15))
                        if [ $((dep_wait % 60)) -eq 0 ]; then
                            print_info "$deploy_count deployment(s) remaining (${dep_wait}s/300s)"
                        fi
                    done
                fi

                # Delete the Stack
                print_info "Deleting Stack '${HCP_STACK_NAME}'..."
                local delete_response
                delete_response=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                    -H "Authorization: Bearer $TFE_TOKEN" \
                    -H "Content-Type: application/vnd.api+json" \
                    "$TFE_API/stacks/$stack_id" 2>/dev/null)

                case "$delete_response" in
                    200|204)
                        stack_deleted=true
                        print_success "HCP Stack delete initiated"
                        ;;
                    404)
                        stack_deleted=true
                        print_info "Stack already deleted"
                        ;;
                    422)
                        # Stack has active runs -- disconnect VCS, cancel runs, retry
                        print_warn "Stack has active runs -- force-cleaning..."
                        curl -s -X PATCH \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            -d '{"data":{"type":"stacks","attributes":{"vcs-repo":null}}}' \
                            "$TFE_API/stacks/$stack_id" >/dev/null 2>&1
                        print_info "VCS disconnected"

                        local config_ids
                        config_ids=$(curl -s \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=20" 2>/dev/null \
                            | jq -r '.data[].id' 2>/dev/null)
                        for cid in $config_ids; do
                            curl -s \
                                -H "Authorization: Bearer $TFE_TOKEN" \
                                -H "Content-Type: application/vnd.api+json" \
                                "$TFE_API/stack-configurations/$cid/stack-deployment-runs" 2>/dev/null \
                                | jq -r '.data[] | select(.attributes.status != "abandoned" and .attributes.status != "failed" and .attributes.status != "succeeded") | .id' 2>/dev/null \
                                | while read -r rid; do
                                    [ -n "$rid" ] && curl -s -X POST \
                                        -H "Authorization: Bearer $TFE_TOKEN" \
                                        -H "Content-Type: application/vnd.api+json" \
                                        "$TFE_API/stack-deployment-runs/$rid/cancel" >/dev/null 2>&1
                                done
                        done
                        print_info "All pending runs canceled"

                        sleep 5
                        delete_response=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stacks/$stack_id" 2>/dev/null)
                        if [ "$delete_response" = "204" ] || [ "$delete_response" = "200" ] || [ "$delete_response" = "404" ]; then
                            stack_deleted=true
                            print_success "HCP Stack deleted"
                        else
                            print_warn "Stack deletion still returned HTTP $delete_response"
                            print_info "Delete manually: HCP Terraform > Stack > Settings > Destruction and Deletion"
                        fi
                        ;;
                    *)
                        print_warn "Stack deletion returned HTTP $delete_response"
                        print_info "Delete manually: HCP Terraform > Stack > Settings > Destruction and Deletion"
                        ;;
                esac

                # Wait for Stack to be fully gone
                if [ "$stack_deleted" = true ] && [ -n "$stack_id" ]; then
                    print_info "Waiting for Stack to be fully deleted (up to 2 min)..."
                    local stack_wait=0
                    while [ $stack_wait -lt 120 ]; do
                        local check_response
                        check_response=$(curl -s -o /dev/null -w "%{http_code}" \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stacks/$stack_id" 2>/dev/null)
                        if [ "$check_response" = "404" ]; then
                            print_success "Stack fully deleted"
                            break
                        fi
                        sleep 5
                        stack_wait=$((stack_wait + 5))
                    done
                fi
            fi
        fi
    fi

    #---------------------------------------------------------------------------
    # Step 4.2: Destroy HCP variable set + project (terraform destroy)
    # Project must be empty (no Stack) for this to succeed.
    #---------------------------------------------------------------------------
    step_header "4.2" "Destroy HCP variable set '${HCP_VARSET_NAME}'"

    if [ "$stack_deleted" = false ]; then
        print_warn "Stack not deleted -- skipping variable set destroy"
        print_info "Re-run teardown after Stack is deleted"
    elif [ ! -f "$hcp_setup_dir/terraform.tfstate" ]; then
        print_info "No terraform.tfstate in hcp-setup/ -- skipping variable set destroy"
    elif [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not set -- skipping variable set destroy"
    else
        print_info "Running terraform destroy in hcp-setup/..."
        if terraform -chdir="$hcp_setup_dir" destroy -auto-approve -input=false; then
            print_success "Variable set + project destroyed"
        else
            print_error "terraform destroy failed in hcp-setup/"
            print_info "Run manually: cd $hcp_setup_dir && terraform destroy"
        fi
    fi

    #---------------------------------------------------------------------------
    # Step 4.3: Delete IAM role + Step 4.4: Delete OIDC provider
    #---------------------------------------------------------------------------
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)

    if [ -z "$account_id" ]; then
        print_error "Could not retrieve AWS Account ID -- skipping IAM/OIDC cleanup"
        return 1
    fi

    local oidc_provider_arn="arn:aws:iam::${account_id}:oidc-provider/app.terraform.io"

    if [ "$SKIP_OIDC_CLEANUP" = true ]; then
        print_info "--skip-oidc-cleanup set -- leaving IAM role + OIDC provider intact"
        return 0
    fi

    step_header "4.3" "Delete IAM role: $HCP_ROLE_NAME"
    if [ "$stack_deleted" = false ]; then
        print_warn "Stack not deleted -- keeping IAM role (HCP needs it for destroy plans)"
    elif aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
        print_info "Detaching policies from $HCP_ROLE_NAME..."
        local attached_policies
        attached_policies=$(aws iam list-attached-role-policies --role-name "$HCP_ROLE_NAME" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
        for policy in $attached_policies; do
            aws iam detach-role-policy --role-name "$HCP_ROLE_NAME" --policy-arn "$policy" 2>/dev/null || true
            print_success "Detached $policy"
        done

        # Inline policies
        local inline_policies
        inline_policies=$(aws iam list-role-policies --role-name "$HCP_ROLE_NAME" \
            --query 'PolicyNames[]' --output text 2>/dev/null)
        for inline in $inline_policies; do
            aws iam delete-role-policy --role-name "$HCP_ROLE_NAME" --policy-name "$inline" 2>/dev/null || true
        done

        if aws iam delete-role --role-name "$HCP_ROLE_NAME" 2>/dev/null; then
            print_success "IAM role deleted: $HCP_ROLE_NAME"
        else
            print_error "Could not delete role $HCP_ROLE_NAME -- inspect for remaining dependencies"
        fi
    else
        print_info "IAM role $HCP_ROLE_NAME not found -- skipping"
    fi

    step_header "4.4" "Delete OIDC provider: app.terraform.io"
    if [ "$stack_deleted" = false ]; then
        print_warn "Stack not deleted -- keeping OIDC provider"
    elif aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_provider_arn" &>/dev/null; then
        print_warn "If other HCP Terraform stacks in this account use this OIDC provider, recreate with setup-aws-oidc.sh"
        if aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_provider_arn" 2>/dev/null; then
            print_success "OIDC provider deleted"
        else
            print_error "Could not delete OIDC provider"
        fi
    else
        print_info "OIDC provider not found -- skipping"
    fi

    echo ""
    print_success "Phase 4 complete: HCP Stack, variable set, IAM role, and OIDC provider cleaned up"
}

#===============================================================================
# MAIN
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Agentic Runtime Security Workshop -- Teardown${NC}"
echo -e "${BLUE}================================================================${NC}"

# Phase 0 always runs
phase_preflight

if [ "$PRE_DESTROY_ONLY" = true ]; then
    phase_pre_destroy
elif [ "$POST_DESTROY_ONLY" = true ]; then
    phase_post_destroy
    phase_oidc_cleanup
else
    phase_pre_destroy
    phase_hcp_destroy
    phase_post_destroy
    phase_oidc_cleanup
fi

#===============================================================================
# Final Summary
#===============================================================================
echo ""
phase_header "Teardown Summary"

if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN -- no changes were made"
    print_info "Run without --dry-run to execute"
elif [ "$PRE_DESTROY_ONLY" = true ]; then
    print_success "Phase 1 complete: K8s resources cleaned"
    echo ""
    print_info "Next steps:"
    echo "    1. Set destroy=true in deployments.tfdeploy.hcl, commit + push"
    echo "    2. Approve destroy plan in HCP Terraform"
    echo "    3. Run: ./scripts/teardown.sh --post-destroy-only"
elif [ "$POST_DESTROY_ONLY" = true ] && [ "$SKIP_OIDC_CLEANUP" = true ]; then
    print_success "Phase 3 complete: orphaned AWS resources cleaned up"
    print_info "Phase 4 partial (--skip-oidc-cleanup): IAM role + OIDC provider preserved"
elif [ "$POST_DESTROY_ONLY" = true ]; then
    print_success "Phase 3+4 complete: orphaned resources, Stack, variable set, OIDC cleaned up"
elif [ "$NO_WAIT" = true ]; then
    print_success "Teardown phases 1+3 dispatched (--no-wait)"
    echo ""
    print_info "Verify HCP Terraform destroy plan completed before re-running for Phase 4"
else
    print_success "Teardown complete -- all resources cleaned up (including HCP Stack)"
    echo ""
    print_info "Workshop tag scope: ${WORKSHOP_TAG}"
fi

echo ""
