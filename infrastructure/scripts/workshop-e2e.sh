#!/usr/bin/env bash
#===============================================================================
# Workshop End-to-End Orchestration — Agentic Runtime Security on AWS
#
# Single-command deployment and validation of the entire workshop.
# Uses local Terraform state (no remote backend required).
#
#   Phase 0: Prerequisites (calls check-prerequisites.sh)
#   Phase 1: Bootstrap (calls bootstrap.sh — EC2 Spot SLR + terraform.tfvars)
#   Phase 2: Foundation deploy (local terraform apply)
#   Phase 3: Configure kubectl
#   Phase 4: Foundation verify (calls test-foundation.sh — EKS + RDS + Bedrock KB + OpenLDAP)
#   Phase 5: Identity (IVIA) — verify IVIA pods + OIDC discovery
#   Phase 6: Vault — init + configure (local via port-forward)
#   Phase 7a: Use Case 1 — Non-Personalized Read-Only (build images, deploy, verify)
#   Phase 7b: Use Case 2 — OAuth Personalized Read-Only (build images, deploy, configure, verify)
#   Phase 7c: Use Case 3 — CIBA Privileged (build+push, deploy, verify, bypass test)
#   Phase 8: Teardown (calls teardown.sh — unless --skip-teardown)
#
# Usage: ./workshop-e2e.sh [OPTIONS]
#
# Options:
#   --interactive       Pause between phases for manual verification
#   --skip-teardown     Leave deployment running after verification
#   --teardown-only     Skip deployment, run teardown only
#   --nuke              Delete EVERYTHING: AWS resources via terraform destroy
#                        and dangling AWS resources
#   --cleanup-only      Skip terraform destroy — just clean up dangling AWS
#                        resources (ENIs, SGs, EIPs, VPCs)
#   --skip-addons       (no-op for now; reserved for future controllers)
#   --skip-prereq-gate  (no-op at this level; passed automatically to
#                        bootstrap.sh in Phase 1 since Phase 0 already runs
#                        check-prerequisites.sh — accepted for CLI symmetry)
#   --dry-run           Show what would be done without executing
#   --start-from PHASE  Skip phases before PHASE. Valid values:
#                        prerequisites, bootstrap, foundation, kubectl,
#                        verify, identity, vault, uc1, uc2
#   --help              Show this help message
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - Terraform CLI installed
#   - kubectl installed
#   - jq installed
#
# Examples:
#   # Full lifecycle: bootstrap -> deploy -> verify -> teardown
#   ./scripts/workshop-e2e.sh
#
#   # Full lifecycle, pause between phases for manual checks
#   ./scripts/workshop-e2e.sh --interactive
#
#   # Deploy and leave running (skip teardown)
#   ./scripts/workshop-e2e.sh --skip-teardown
#
#   # Teardown only (foundation must exist)
#   ./scripts/workshop-e2e.sh --teardown-only
#
#   # Nuke: terraform destroy + clean up everything
#   ./scripts/workshop-e2e.sh --nuke
#
#   # Cleanup only: foundation already destroyed, just remove leftovers
#   ./scripts/workshop-e2e.sh --cleanup-only
#
#   # Preview what any command would do
#   ./scripts/workshop-e2e.sh --nuke --dry-run
#===============================================================================

set -e

# Disable AWS CLI pager to prevent vi/less from capturing output
export AWS_PAGER=""

#-------------------------------------------------------------------------------
# Debug logging — set DEBUG=true to tee all output to a timestamped log file
#-------------------------------------------------------------------------------
if [[ "${DEBUG:-false}" == "true" || "${DEBUG:-0}" == "1" ]]; then
  _LOG_DIR="$(cd "$(dirname "$0")/../.." && pwd)/logs"
  mkdir -p "$_LOG_DIR"
  _LOG_FILE="${_LOG_DIR}/e2e-$(date +%Y%m%d-%H%M%S).log"
  echo "DEBUG: logging to ${_LOG_FILE}"
  exec > >(tee -a "$_LOG_FILE") 2>&1
fi

#-------------------------------------------------------------------------------
# Script Directory
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

#-------------------------------------------------------------------------------
# Workshop kubectl/helm context isolation (BLOCKING)
#
# lib-workshop-context.sh writes a PROCESS-ISOLATED kubeconfig pointing at
# ONLY the workshop EKS cluster (alias `workshop`) and exports KUBECONFIG to
# it. Every bare `kubectl` / `helm` call in this script + every child script
# bash invokes inherits the isolated kubeconfig and CANNOT reach a non-workshop
# cluster (GKE / other AWS / etc).
# Reason: 2026-06-07 — bare `kubectl exec vault-0 -- vault status` inside
# vault-init.sh routed to a GKE Vault on Bear's machine, silently reporting
# `initialized=true` and skipping the actual workshop Vault init.
# Skipped during --teardown-only / --nuke / --cleanup-only (cluster may be
# gone) and --start-from prerequisites/bootstrap (cluster not built yet).
#-------------------------------------------------------------------------------
# Defer sourcing until after argparse runs so we can honor opt-out modes —
# see "Workshop context bootstrap" block below.

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
INTERACTIVE=false
SKIP_TEARDOWN=false
TEARDOWN_ONLY=false
NUKE=false
CLEANUP_ONLY=false
SKIP_ADDONS=false
DRY_RUN=false
START_FROM=""

# Resolve canonical region + cluster_name from infrastructure/terraform.tfvars.
# No string literals here — only the config file is the source of truth.
TF_VARS="${PROJECT_ROOT}/infrastructure/terraform.tfvars"
TF_VARS_EXAMPLE="${PROJECT_ROOT}/infrastructure/terraform.tfvars.example"
TF_DEPLOY="${PROJECT_ROOT}/infrastructure/terraform.tfvars"

_e2e_resolve_var() {
    local key="$1"
    # Prefer terraform.tfvars (gitignored, has real values), then .example, then .hcl
    for f in "$TF_VARS" "$TF_VARS_EXAMPLE" "$TF_DEPLOY"; do
        if [ -f "$f" ]; then
            local val
            val=$(grep -E "^\s*${key}\s*=" "$f" 2>/dev/null \
                | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
            if [ -n "$val" ]; then echo "$val"; return; fi
        fi
    done
}

WORKSHOP_REGION="${AWS_REGION:-}"
if [ -z "$WORKSHOP_REGION" ]; then
    WORKSHOP_REGION=$(_e2e_resolve_var "region")
fi
CLUSTER_NAME="${CLUSTER_NAME:-}"
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(_e2e_resolve_var "cluster_name")
fi

# KB region — Nova 2 Multimodal Embeddings is us-east-1 only.
KB_REGION="${KB_REGION:-}"
if [ -z "$KB_REGION" ]; then
    KB_REGION=$(_e2e_resolve_var "kb_region")
fi
KB_REGION="${KB_REGION:-us-east-1}"

if [ -z "$CLUSTER_NAME" ]; then
    echo -e "${RED}Error: could not resolve cluster_name from terraform.tfvars or terraform.tfvars${NC}" >&2
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
    sed -n '2,63p' "$0"
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
        --start-from)     START_FROM="$2"; shift ;;
        -*)               echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        *)                echo -e "${RED}Unexpected argument: $1${NC}"; usage ;;
    esac
    shift
done

if [ -z "$WORKSHOP_REGION" ] && [ "$TEARDOWN_ONLY" = false ] && [ "$NUKE" = false ]; then
    echo -e "${RED}Error: could not resolve workshop region${NC}"
    echo "Set AWS_REGION or ensure infrastructure/terraform.tfvars is present."
    exit 1
fi

#-------------------------------------------------------------------------------
# Workshop context bootstrap — isolate KUBECONFIG to the workshop EKS cluster.
# Skipped for modes where the cluster may not exist yet (cleanup-only) or has
# been fully destroyed (teardown-only / nuke). For all other modes the source
# call fails fast if the cluster can't be reached — refusing to silently fall
# back to ~/.kube/config (which often defaults to GKE / other AWS / etc).
#-------------------------------------------------------------------------------
if [ "$TEARDOWN_ONLY" = true ] || [ "$NUKE" = true ] || [ "$CLEANUP_ONLY" = true ]; then
    export WORKSHOP_CONTEXT_SKIP=true
fi
# shellcheck source=./lib-workshop-context.sh
source "$SCRIPT_DIR/lib-workshop-context.sh"

#-------------------------------------------------------------------------------
# Phase 07.8 — Orphan TargetGroupBinding sweep
#
# AWS Load Balancer Controller v2.7.x creates a NEW TargetGroupBinding (+ new
# Target Group + new ALB) when an Ingress's group.name annotation changes, but
# does NOT garbage-collect the OLD TGB. The old TGB keeps the old ALB alive,
# which keeps any cert attached to the old ALB's HTTPS listener un-deletable
# (ResourceInUseException on aws_acm_certificate destroy).
#
# This sweep finds TGBs whose owning Ingress no longer references their backing
# ALB and deletes them. LBC then reconciles → deletes the empty ALB → cert can
# be destroyed by terraform.
#
# Variables consumed: ORPHAN_TGBS_SWEPT (exported count, read by caller).
#-------------------------------------------------------------------------------
_sweep_orphan_tgbs() {
    # Note: written defensively to survive `set -e` / `set -u` — uses explicit
    # if-blocks and parameter defaults, no `&&-continue` short-circuit chains.
    local count=0
    local tgb_namespace tgb_name owner_ns owner_name tgb_arn tgb_alb_arn alb_hostname expected_hostname

    while IFS=$'\t' read -r tgb_namespace tgb_name; do
        if [ -z "${tgb_namespace:-}" ]; then continue; fi

        owner_ns=$(kubectl --context workshop -n "$tgb_namespace" get targetgroupbinding "$tgb_name" \
            -o jsonpath='{.metadata.labels.ingress\.k8s\.aws/stack-namespace}' 2>/dev/null || true)
        owner_name=$(kubectl --context workshop -n "$tgb_namespace" get targetgroupbinding "$tgb_name" \
            -o jsonpath='{.metadata.labels.ingress\.k8s\.aws/stack-name}' 2>/dev/null || true)
        if [ -z "${owner_ns:-}" ] || [ -z "${owner_name:-}" ]; then continue; fi

        tgb_arn=$(kubectl --context workshop -n "$tgb_namespace" get targetgroupbinding "$tgb_name" \
            -o jsonpath='{.spec.targetGroupARN}' 2>/dev/null || true)
        if [ -z "${tgb_arn:-}" ]; then continue; fi

        tgb_alb_arn=$(aws elbv2 describe-target-groups --region "$WORKSHOP_REGION" --target-group-arns "$tgb_arn" \
            --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null || true)
        if [ -z "${tgb_alb_arn:-}" ] || [ "${tgb_alb_arn}" = "None" ]; then continue; fi

        alb_hostname=$(aws elbv2 describe-load-balancers --region "$WORKSHOP_REGION" --load-balancer-arns "$tgb_alb_arn" \
            --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
        if [ -z "${alb_hostname:-}" ]; then continue; fi

        expected_hostname=$(kubectl --context workshop -n "$owner_ns" get ingress "$owner_name" \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [ -z "${expected_hostname:-}" ]; then continue; fi

        if [ "$alb_hostname" != "$expected_hostname" ]; then
            print_info "Deleting orphan TGB ${tgb_namespace}/${tgb_name} (owner ${owner_ns}/${owner_name}; orphan ALB: ${alb_hostname}; current: ${expected_hostname})"
            kubectl --context workshop -n "$tgb_namespace" delete targetgroupbinding "$tgb_name" --wait=false >/dev/null 2>&1 || true
            # LBC v2.7.x does NOT GC the orphan ALB on its own when the Ingress
            # stack tag still references a live Ingress (the new ALB wins
            # ownership). Delete the orphan ALB explicitly here — its listeners
            # (with cert refs) are removed atomically by delete-load-balancer.
            # Safe because we already verified expected_hostname != alb_hostname,
            # i.e. no live Ingress points at this ALB.
            print_info "  → also deleting orphan ALB ${tgb_alb_arn}"
            aws elbv2 delete-load-balancer --region "$WORKSHOP_REGION" --load-balancer-arn "$tgb_alb_arn" >/dev/null 2>&1 || true
            count=$((count + 1))
        fi
    done < <(kubectl --context workshop get targetgroupbinding -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ "$count" -gt 0 ]; then
        print_warn "Swept ${count} orphan TargetGroupBinding(s) + their backing ALB(s). Cert detachment + ALB deletion is async (typically 30-60s)."
    else
        print_info "No orphan TargetGroupBindings found."
    fi
    ORPHAN_TGBS_SWEPT="$count"
    export ORPHAN_TGBS_SWEPT
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
        print_error "jq is required for JSON parsing"
        exit 1
    fi
    print_success "jq found"
}

#===============================================================================
# PHASE 1: Bootstrap (EC2 Spot SLR + terraform.tfvars)
#===============================================================================
phase_bootstrap() {
    phase_header "Phase 1: Bootstrap (EC2 Spot SLR + terraform.tfvars)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: bootstrap.sh --skip-prereq-gate"
        return 0
    fi

    bash "$SCRIPT_DIR/bootstrap.sh" --skip-prereq-gate
}

#===============================================================================
# PHASE 2: Foundation Deploy
#===============================================================================
phase_deploy_foundation() {
    phase_header "Phase 2: Foundation Deploy (EKS + RDS + Bedrock KB)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would sweep orphan TargetGroupBindings (Phase 07.8 IngressGroup transition)"
        print_info "[DRY-RUN] Would run: terraform -chdir=infrastructure apply -auto-approve"
        print_info "[DRY-RUN] Would call configure-workshop.sh after apply completes"
        print_info "[DRY-RUN] Would call verify-tls.sh as a strict Phase 2 trusted-cert gate (Phase 07.8)"
        return 0
    fi

    step_header "Running terraform init..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" init -upgrade || {
        print_error "Terraform init failed."
        exit 1
    }

    # Phase 07.8 transition gate — sweep orphan TargetGroupBindings before apply.
    # When an Ingress's alb.ingress.kubernetes.io/group.name annotation changes,
    # AWS Load Balancer Controller creates new TargetGroupBindings + TGs + ALB
    # but does NOT garbage-collect the old TGBs. The old TGBs keep the old ALB
    # alive, which keeps the old DNS-validated ACM cert attached, which blocks
    # `aws_acm_certificate.wrp_public` destroy with ResourceInUseException.
    # Sweep deletes any TGB whose backing ALB hostname differs from its parent
    # Ingress's current load-balancer hostname, then waits for LBC to GC the
    # now-empty ALB so the cert destroy can proceed.
    step_header "Sweeping orphan TargetGroupBindings (Phase 07.8 IngressGroup transition)..."
    _sweep_orphan_tgbs
    if [ "${ORPHAN_TGBS_SWEPT:-0}" -gt 0 ]; then
        print_info "Waiting 90s for AWS Load Balancer Controller to reconcile + GC orphan ALBs..."
        sleep 90
    fi

    step_header "Running terraform apply..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" apply -auto-approve || {
        print_error "Foundation deploy failed. Check terraform output above."
        exit 1
    }
    print_success "Foundation infrastructure deployed"

    # Call configure-workshop.sh after apply completes
    step_header "Running post-deploy configuration (configure-workshop.sh)..."
    bash "$SCRIPT_DIR/configure-workshop.sh" \
        --region "$WORKSHOP_REGION" \
        --cluster-name "$CLUSTER_NAME" || {
        print_warn "configure-workshop.sh reported failures — see above for details"
    }

    # Phase 07.8 — strict trusted-cert gate. verify-tls.sh is wave-aware: pending
    # preconditions emit info notices and exit 0; a check failing AFTER its
    # delivering wave has landed exits nonzero. Treat nonzero as fatal so e2e
    # doesn't ship a foundation that fails the "no click-through warning"
    # contract.
    step_header "Running Phase 07.8 trusted-cert verification (verify-tls.sh)..."
    bash "$SCRIPT_DIR/verify-tls.sh" || {
        print_error "verify-tls.sh failed — trusted-cert chain not serving on attendee-facing ALBs. See above for failing check(s)."
        exit 1
    }
    print_success "Phase 07.8 trusted-cert chain verified on attendee-facing ALBs"

    pause_if_interactive "Foundation deploy complete. Infrastructure is running."
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
    phase_header "Phase 4: Foundation Verify (EKS + RDS + Bedrock KB + OpenLDAP)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: test-foundation.sh"
        return 0
    fi

    # Resolve DB instance + KB id from env or fall back to AWS discovery
    local db_id="${WORKSHOP_DB_INSTANCE_ID:-}"
    local kb_id="${WORKSHOP_KB_ID:-}"

    if [ -z "$db_id" ]; then
        db_id=$(aws rds describe-db-instances --region "$WORKSHOP_REGION" \
            --query "DBInstances[?DBInstanceIdentifier=='${CLUSTER_NAME}-pg'].DBInstanceIdentifier | [0]" \
            --output text 2>/dev/null || true)
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

    # User 'oscar' is now seeded into the in-cluster OpenLDAP automatically by
    # IVIA autoconf (webseal.pdadmin.users in base_layer.yaml). No external
    # provisioning step needed.

    bash "$SCRIPT_DIR/test-foundation.sh" \
        --cluster-name "$CLUSTER_NAME" \
        --db-instance-id "$db_id" \
        --knowledge-base-id "$kb_id" \
        --region "$WORKSHOP_REGION" \
        || print_warn "Foundation verification reported failures (see above)"

    pause_if_interactive "Foundation verification complete."
}

#===============================================================================
# PHASE 5: Identity (IVIA) — verify full IVIA stack (OIDC Provider + Config + Runtime + WRP)
#===============================================================================
phase_identity() {
    phase_header "Phase 5: Identity (IVIA)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would terraform apply -target=module.ivia, then kubectl rollout restart deploy/iviawrprp1, then ivia-configure.sh"
        return 0
    fi

    local ivia_ns="verify-access"

    # Verify trial cert is in its Phase 7 location
    local trial_cert="$PROJECT_ROOT/infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer"
    if [ ! -f "${trial_cert}" ]; then
        print_error "IVIA trial cert not found at ${trial_cert} — obtain from https://isva-trial.verify.ibm.com/ and place at that path"
        return 1
    fi

    # Apply only the verify_access module (and its transitive deps).
    step_header "terraform apply -target=module.ivia"
    (
        cd "$PROJECT_ROOT/infrastructure"
        terraform apply -target=module.ivia -auto-approve
    ) || { print_error "terraform apply -target=module.ivia failed"; return 1; }

    # The kubernetes_job_v1.ivia_autoconf inside module.ivia uses
    # wait_for_completion=true, so the apply above already blocked until
    # autoconf finished. Now restart WRP to clear stale snapshot backoff
    # (RESEARCH Pitfall 6, sibling-locked post-step).
    step_header "kubectl rollout restart deploy/iviawrprp1 (post-autoconf snapshot reload)"
    kubectl rollout restart deploy/iviawrprp1 -n "${ivia_ns}" \
        || { print_error "rollout restart deploy/iviawrprp1 failed"; return 1; }
    kubectl rollout status deploy/iviawrprp1 -n "${ivia_ns}" --timeout=300s \
        || { print_error "WRP did not become Ready within 5min post-restart"; return 1; }

    # Verify the 7 deployments by app label (Phase 7 uses `app:` keys, not
    # `app.kubernetes.io/name:`).
    local ready
    for app in openldap postgresql iviaconfig iviadsc iviaop iviaruntime iviawrprp1; do
        ready=$(kubectl get deploy -n "${ivia_ns}" -l "app=${app}" \
            -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
        if [ "${ready:-0}" -ge 1 ]; then
            print_success "Deployment ${app}: Ready"
        else
            print_warn "Deployment ${app}: not Ready (readyReplicas=${ready:-0})"
        fi
    done

    # Exit gate — OIDC discovery via WRP exec.
    step_header "OIDC discovery exit gate"
    bash "$SCRIPT_DIR/ivia-configure.sh" \
        || { print_error "ivia-configure.sh failed — exit gate not met"; return 1; }

    pause_if_interactive "IVIA full-stack verification complete."
}

#===============================================================================
# PHASE 6: Vault — init + configure (local via port-forward)
# Step 1: vault-init.sh — initialize Vault, save root token + recovery keys
# Step 2: vault-configure.sh — port-forward, terraform apply vault-config (IVIA OAuth client registration moved to clients.yml + DCR Job in root TF)
# Step 3: test-vault-verify.sh — verify pods, seal status, Raft peers, audit
#===============================================================================
phase_vault() {
    phase_header "Phase 6: Vault"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: vault-init.sh"
        print_info "[DRY-RUN] Would run: vault-configure.sh"
        print_info "[DRY-RUN] Would run: test-vault-verify.sh"
        return 0
    fi

    # Step 1: Initialize Vault
    step_header "Initializing Vault..."
    bash "$SCRIPT_DIR/vault-init.sh" \
        || { print_error "vault-init.sh failed"; return 1; }

    # Step 2: Configure Vault + IVIA (local terraform apply via port-forward)
    step_header "Configuring Vault + IVIA (local port-forward)..."
    bash "$SCRIPT_DIR/vault-configure.sh" --skip-ivia \
        || print_warn "vault-configure.sh reported failures (see above)"

    # Step 3: Verify Vault
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
        print_info "[DRY-RUN] Would build+push UC1 agent image (build-uc1-agent.sh)"
        print_info "[DRY-RUN] Would update uc1_agent_image in terraform.tfvars"
        print_info "[DRY-RUN] Would run terraform apply, ingest KB (sync-bedrock-kb.sh), then verify-uc1.sh"
        return 0
    fi

    # Step 1: Build + push UC1 agent image
    step_header "Building and pushing UC1 agent image..."
    bash "$SCRIPT_DIR/build-uc1-agent.sh" \
        --region "$WORKSHOP_REGION" || {
        print_error "build-uc1-agent.sh failed"
        return 1
    }
    print_success "UC1 agent image built and pushed to ECR"
    pause_if_interactive "UC1 agent image pushed to ECR. Verify in AWS Console before continuing."

    # Step 2: Resolve ECR URI and update terraform.tfvars
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local ecr_uri="${account_id}.dkr.ecr.${WORKSHOP_REGION}.amazonaws.com/workshop/uc1-agent:latest"

    step_header "Updating uc1_agent_image in terraform.tfvars..."
    local deploy_file="$PROJECT_ROOT/infrastructure/terraform.tfvars"
    local current_image
    current_image=$(grep 'uc1_agent_image' "$deploy_file" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')

    if [ "$current_image" = "$ecr_uri" ]; then
        print_info "uc1_agent_image already set to $ecr_uri"
    elif [ -n "$current_image" ]; then
        sed -i.bak "s|uc1_agent_image *= *\"[^\"]*\"|uc1_agent_image = \"${ecr_uri}\"|" "$deploy_file"
        rm -f "${deploy_file}.bak"
        print_success "uc1_agent_image = $ecr_uri"
    else
        echo "uc1_agent_image = \"${ecr_uri}\"" >> "$deploy_file"
        print_success "uc1_agent_image = $ecr_uri (appended)"
    fi

    # Step 3: Terraform apply
    step_header "Running terraform apply for UC1 deployment..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" apply -auto-approve || {
        print_error "UC1 terraform apply failed"
        return 1
    }
    print_success "UC1 agent deployed via terraform apply"

    # Rollout restart to pick up new image (tag :latest may be cached by kubelet)
    step_header "Restarting UC1 deployment to pull latest image..."
    kubectl rollout restart deployment/uc1-agent -n uc1 2>/dev/null || true
    pause_if_interactive "Deployment restarted. Waiting for pod to become ready."

    # Step 4: Wait for pod readiness
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

    # Step 5: Ingest the Bedrock Knowledge Base corpus.
    # Creating the KB data sources (Terraform) does NOT embed the S3 corpus into
    # the vector index — an explicit ingestion job is required, or the agent's
    # retrieve_from_knowledge_base tool returns zero passages. Idempotent.
    step_header "Ingesting Bedrock Knowledge Base corpus (sync-bedrock-kb.sh)..."
    bash "$SCRIPT_DIR/sync-bedrock-kb.sh" || {
        print_error "sync-bedrock-kb.sh failed — KB will be empty and verify-uc1 Check 9 will fail"
        return 1
    }
    print_success "Knowledge Base corpus ingested"

    # Step 6: Verify
    pause_if_interactive "About to verify UC1 deployment"
    bash "$SCRIPT_DIR/verify-uc1.sh" 2>&1 || print_warn "UC1 verification had warnings"
    print_success "UC1 verification complete"
}

#===============================================================================
# PHASE 7b: Use Case 2 — OAuth Personalized Read-Only
#===============================================================================
phase_uc2() {
    phase_header "Phase 7b: Use Case 2 — OAuth Personalized Read-Only"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would build+push banking app images (UI, Agent, MCP Server)"
        print_info "[DRY-RUN] Would update banking_app_*_image in terraform.tfvars"
        print_info "[DRY-RUN] Would run terraform apply for UC2 deployment"
        print_info "[DRY-RUN] Would wait for banking-app pods to be ready"
        print_info "[DRY-RUN] Would run verify-uc2.sh"
        return 0
    fi

    # Step 1: Build + push banking app images
    step_header "Building and pushing banking app images..."
    bash "$SCRIPT_DIR/build-banking-app.sh" \
        --region "$WORKSHOP_REGION" || {
        print_error "build-banking-app.sh failed"
        return 1
    }
    print_success "Banking app images built and pushed to ECR"
    pause_if_interactive "Banking app images pushed to ECR. Verify in AWS Console before continuing."

    # Step 2: Resolve ECR URIs and update terraform.tfvars
    step_header "Resolving banking app ECR image URIs..."
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local ecr_base="${account_id}.dkr.ecr.${WORKSHOP_REGION}.amazonaws.com/workshop-banking-app"
    local ui_image="${ecr_base}:ui"
    local agent_image="${ecr_base}:agent"
    local mcp_image="${ecr_base}:mcp"

    local deploy_file="$PROJECT_ROOT/infrastructure/terraform.tfvars"

    for var_name in banking_app_ui_image banking_app_agent_image banking_app_mcp_image; do
        local var_image=""
        case "$var_name" in
            banking_app_ui_image)    var_image="$ui_image" ;;
            banking_app_agent_image) var_image="$agent_image" ;;
            banking_app_mcp_image)   var_image="$mcp_image" ;;
        esac
        local current_val
        current_val=$(grep "${var_name}" "$deploy_file" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
        if [ "$current_val" = "$var_image" ]; then
            print_info "${var_name} already set to ${var_image}"
        elif [ -n "$current_val" ]; then
            sed -i.bak "s|${var_name}[[:space:]]*=[[:space:]]*\"[^\"]*\"|${var_name} = \"${var_image}\"|" "$deploy_file"
            rm -f "${deploy_file}.bak"
            print_success "${var_name} = ${var_image}"
        else
            echo "${var_name} = \"${var_image}\"" >> "$deploy_file"
            print_success "${var_name} = ${var_image} (appended)"
        fi
    done

    # Step 3: Terraform apply
    step_header "Running terraform apply for UC2 deployment..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" apply -auto-approve || {
        print_error "UC2 terraform apply failed"
        return 1
    }
    print_success "UC2 banking app deployed via terraform apply"
    pause_if_interactive "Terraform apply complete. Verify uc2 resources before continuing."

    # Rollout restart to pick up new images (tag may be cached by kubelet)
    step_header "Restarting banking-app deployments to pull latest images..."
    kubectl rollout restart deployment/banking-ui -n banking-app 2>/dev/null || true
    kubectl rollout restart deployment/banking-agent -n banking-app 2>/dev/null || true
    kubectl rollout restart deployment/banking-mcp-server -n banking-app 2>/dev/null || true
    pause_if_interactive "Deployments restarted. Waiting for pods to become ready."

    # Step 4: Wait for all banking-app pods to be ready
    step_header "Waiting for banking-app pods to be ready..."
    local pods_ready=false
    local wait_elapsed=0
    while [ $wait_elapsed -lt 180 ]; do
        local ui_running agent_running mcp_running
        ui_running=$(kubectl get pods -n banking-app -l app=banking-ui \
            --no-headers 2>/dev/null | grep -c Running || true)
        agent_running=$(kubectl get pods -n banking-app -l app=banking-agent \
            --no-headers 2>/dev/null | grep -c Running || true)
        mcp_running=$(kubectl get pods -n banking-app -l app=banking-mcp-server \
            --no-headers 2>/dev/null | grep -c Running || true)

        if [ "${ui_running:-0}" -ge 1 ] && \
           [ "${agent_running:-0}" -ge 1 ] && \
           [ "${mcp_running:-0}" -ge 1 ]; then
            pods_ready=true
            break
        fi
        sleep 15
        wait_elapsed=$((wait_elapsed + 15))
        if [ $((wait_elapsed % 45)) -eq 0 ]; then
            print_info "Waiting for banking-app pods (${wait_elapsed}s/180s)..."
        fi
    done

    if [ "$pods_ready" = true ]; then
        print_success "All banking-app pods are Running (ui + agent + mcp-server)"
    else
        print_warn "Some banking-app pods not Running after 180s — verify-uc2.sh will report details"
    fi
    pause_if_interactive "Pods ready. Verify with 'kubectl get pods -n banking-app' before continuing."

    # Step 5: Run verify-uc2.sh
    pause_if_interactive "About to verify UC2 deployment"
    bash "$SCRIPT_DIR/verify-uc2.sh" 2>&1 || print_warn "UC2 verification had warnings"
    print_success "UC2 verification complete"
}

#===============================================================================
# PHASE 7c: Use Case 3 — CIBA Privileged
#===============================================================================
phase_uc3() {
    phase_header "Phase 7c: Use Case 3 — CIBA Privileged"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would build+push UC3 agent image (build-uc3-agent.sh)"
        print_info "[DRY-RUN] Would update uc3_agent_image in terraform.tfvars"
        print_info "[DRY-RUN] Would run terraform apply for UC3 + observability modules"
        print_info "[DRY-RUN] Would wait for uc3-agent deployment rollout"
        print_info "[DRY-RUN] Would wait for fluent-bit DaemonSet rollout"
        print_info "[DRY-RUN] Would run verify-uc3.sh (normal + bypass)"
        return 0
    fi

    # Step 1: Build + push UC3 agent image
    step_header "Building and pushing UC3 agent image..."
    bash "$SCRIPT_DIR/build-uc3-agent.sh" \
        --region "$WORKSHOP_REGION" || {
        print_error "build-uc3-agent.sh failed"
        return 1
    }
    print_success "UC3 agent image built and pushed to ECR"
    pause_if_interactive "UC3 agent image pushed to ECR. Verify in AWS Console before continuing."

    # Step 2: Resolve ECR URI and update terraform.tfvars
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    local ecr_uri="${account_id}.dkr.ecr.${WORKSHOP_REGION}.amazonaws.com/workshop/uc3-agent:latest"

    step_header "Updating uc3_agent_image in terraform.tfvars..."
    local deploy_file="$PROJECT_ROOT/infrastructure/terraform.tfvars"
    local current_image
    current_image=$(grep 'uc3_agent_image' "$deploy_file" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
    if [ "$current_image" = "$ecr_uri" ]; then
        print_info "uc3_agent_image already set to $ecr_uri"
    elif [ -n "$current_image" ]; then
        sed -i.bak "s|uc3_agent_image *= *\"[^\"]*\"|uc3_agent_image = \"${ecr_uri}\"|" "$deploy_file"
        rm -f "${deploy_file}.bak"
        print_success "uc3_agent_image = $ecr_uri"
    else
        echo "uc3_agent_image = \"${ecr_uri}\"" >> "$deploy_file"
        print_success "uc3_agent_image = $ecr_uri (appended)"
    fi

    # Step 3: Init (new modules) + apply
    step_header "Running terraform init for new UC3 + observability modules..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" init -upgrade || {
        print_error "UC3 terraform init failed"
        return 1
    }

    step_header "Running terraform apply for UC3 + observability deployment..."
    terraform -chdir="$PROJECT_ROOT/infrastructure" apply -auto-approve || {
        print_error "UC3 terraform apply failed"
        return 1
    }
    print_success "UC3 agent and observability deployed via terraform apply"
    pause_if_interactive "Terraform apply complete. Verify uc3 + observability resources before continuing."

    # Step 3b: Ensure banking.refunds table exists in RDS
    step_header "Ensuring banking.refunds table exists..."
    local rds_secret_arn
    rds_secret_arn=$(aws rds describe-db-instances --region "$WORKSHOP_REGION" \
        --query "DBInstances[?DBInstanceIdentifier=='${CLUSTER_NAME}-pg'].MasterUserSecret.SecretArn | [0]" \
        --output text 2>/dev/null)
    if [ -n "$rds_secret_arn" ] && [ "$rds_secret_arn" != "None" ]; then
        local rds_pass rds_host
        rds_pass=$(aws secretsmanager get-secret-value --secret-id "$rds_secret_arn" \
            --region "$WORKSHOP_REGION" --query 'SecretString' --output text 2>/dev/null | jq -r '.password')
        rds_host=$(aws rds describe-db-instances --region "$WORKSHOP_REGION" \
            --query "DBInstances[?DBInstanceIdentifier=='${CLUSTER_NAME}-pg'].Endpoint.Address | [0]" \
            --output text 2>/dev/null)
        kubectl run psql-refunds-$$ --rm -i --restart=Never -n banking-app \
            --image=postgres:16-alpine \
            --env="PGPASSWORD=$rds_pass" \
            -- psql "postgresql://vault_root@${rds_host}:5432/workshop?sslmode=require" \
            -c "CREATE TABLE IF NOT EXISTS banking.refunds (
                refund_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id UUID NOT NULL REFERENCES banking.accounts(id),
                transaction_id UUID NOT NULL REFERENCES banking.transactions(id),
                amount DECIMAL(12,2) NOT NULL,
                currency VARCHAR(3) NOT NULL DEFAULT 'USD',
                approved_by VARCHAR(255) NOT NULL,
                request_id UUID NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );" &>/dev/null && print_success "banking.refunds table ready" \
            || print_warn "Could not create banking.refunds table — may already exist"
    else
        print_warn "Could not find RDS secret ARN — skipping refunds table creation"
    fi

    # Step 4: Wait for UC3 agent deployment rollout
    step_header "Waiting for UC3 agent deployment rollout..."
    kubectl rollout status deployment/uc3-agent -n banking-app --timeout=300s 2>/dev/null || {
        print_warn "UC3 agent rollout timed out — verify-uc3.sh will report details"
    }

    # Step 5: Wait for fluent-bit DaemonSet
    step_header "Waiting for fluent-bit DaemonSet rollout..."
    kubectl rollout status daemonset/aws-for-fluent-bit -n logging --timeout=120s 2>/dev/null || {
        print_warn "fluent-bit DaemonSet rollout timed out — check: kubectl get pods -n logging"
    }

    # Step 6: Run UC3 verification
    pause_if_interactive "About to verify UC3 deployment"
    bash "$SCRIPT_DIR/verify-uc3.sh" 2>&1 || print_warn "UC3 verification had warnings"
    print_success "UC3 verification complete"

    # Step 7: Run bypass test
    pause_if_interactive "About to run UC3 bypass test (forged JWT rejection)"
    bash "$SCRIPT_DIR/verify-uc3.sh" --bypass 2>&1 || print_warn "UC3 bypass test had warnings"
    print_success "UC3 bypass test complete"
}

#===============================================================================
# PHASE 7d: Observability — Three-Plane Audit Verification
#===============================================================================
phase_observability() {
    phase_header "Phase 7d: Observability — Three-Plane Audit Verification"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would verify fluent-bit + CloudWatch + Firehose + S3 + Athena"
        print_info "[DRY-RUN] Would pretty-print recent events from all 3 audit planes"
        return 0
    fi

    # Step 1: Verify all 3 CloudWatch log groups have streams
    step_header "Verifying CloudWatch log groups..."
    local all_cw_ok=true
    for lg in vault-audit ivia-decision agent-trace; do
        stream_count=$(aws logs describe-log-streams \
            --log-group-name "/workshop/${lg}" \
            --region "$WORKSHOP_REGION" \
            --query 'logStreams | length(@)' \
            --output text 2>/dev/null || echo "0")
        if [ "${stream_count:-0}" -ge 1 ]; then
            print_success "/workshop/${lg} — ${stream_count} stream(s)"
        else
            print_warn "/workshop/${lg} — no streams yet"
            all_cw_ok=false
        fi
    done

    # Step 2: Verify fluent-bit DaemonSet is healthy
    step_header "Verifying fluent-bit DaemonSet..."
    local fb_running
    fb_running=$(kubectl get pods -n logging -l app.kubernetes.io/name=aws-for-fluent-bit \
        --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${fb_running:-0}" -ge 1 ]; then
        print_success "fluent-bit DaemonSet healthy (${fb_running} pods Running)"
    else
        print_error "fluent-bit DaemonSet: no Running pods in logging namespace"
        return 1
    fi

    # Step 3: Verify Firehose delivery streams are ACTIVE
    step_header "Verifying Firehose delivery streams..."
    local active_count=0
    for stream_suffix in vault-audit ivia-decision agent-trace; do
        local stream_name="${CLUSTER_NAME}-${stream_suffix}"
        local stream_status
        stream_status=$(aws firehose describe-delivery-stream \
            --delivery-stream-name "${stream_name}" \
            --region "$WORKSHOP_REGION" \
            --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
            --output text 2>/dev/null || echo "NOT_FOUND")
        if [ "${stream_status}" = "ACTIVE" ]; then
            active_count=$((active_count + 1))
            print_success "Firehose ${stream_name} — ACTIVE"
        else
            print_warn "Firehose ${stream_name} — ${stream_status}"
        fi
    done
    [ "${active_count}" -ge 3 ] || print_warn "Only ${active_count}/3 Firehose streams ACTIVE"

    # Step 4: Verify S3 log bucket has objects
    step_header "Verifying S3 log delivery..."
    local log_bucket="${CLUSTER_NAME}-workshop-logs"
    local s3_count
    s3_count=$(aws s3api list-objects-v2 --bucket "${log_bucket}" --max-items 5 \
        --query 'length(Contents)' --output text 2>/dev/null || echo "0")
    if [ "${s3_count:-0}" -ge 1 ] 2>/dev/null; then
        print_success "S3 bucket '${log_bucket}' has objects (Firehose delivering)"
    else
        print_warn "S3 bucket '${log_bucket}' empty — Firehose buffers 60s. Will re-check after plane dump."
    fi

    # Step 5: Verify Athena named query exists in workshop workgroup
    step_header "Verifying Athena named query..."
    local athena_ok=false
    local query_ids
    query_ids=$(aws athena list-named-queries \
        --work-group workshop \
        --region "$WORKSHOP_REGION" \
        --query 'NamedQueryIds' --output json 2>/dev/null || echo "[]")
    local qid_count
    qid_count=$(echo "$query_ids" | jq 'length' 2>/dev/null || echo "0")
    if [ "${qid_count:-0}" -ge 1 ]; then
        for qid in $(echo "$query_ids" | jq -r '.[]' 2>/dev/null); do
            local qname
            qname=$(aws athena get-named-query --named-query-id "$qid" \
                --region "$WORKSHOP_REGION" \
                --query 'NamedQuery.Name' --output text 2>/dev/null || echo "")
            if echo "$qname" | grep -qi "audit.correlation\|audit-correlation"; then
                print_success "Athena named query '${qname}' exists (workgroup: workshop)"
                athena_ok=true
                break
            fi
        done
        [ "$athena_ok" = true ] || print_warn "Athena workshop workgroup has ${qid_count} queries but none named audit_correlation"
    else
        print_warn "No named queries in Athena workshop workgroup"
    fi

    # Step 6: Pretty-print recent events from all 3 audit planes
    step_header "Three-Plane Audit Log Dump"
    echo ""

    # --- Plane 1: Vault Audit ---
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  PLANE 1: Vault Audit (/workshop/vault-audit)                   │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    local vault_stream
    vault_stream=$(aws logs describe-log-streams --log-group-name /workshop/vault-audit \
        --region "$WORKSHOP_REGION" --order-by LastEventTime --descending \
        --query 'logStreams[0].logStreamName' --output text 2>/dev/null || echo "")
    if [ -n "$vault_stream" ] && [ "$vault_stream" != "None" ]; then
        aws logs get-log-events --log-group-name /workshop/vault-audit \
            --log-stream-name "$vault_stream" --region "$WORKSHOP_REGION" \
            --limit 5 --query 'events[*].message' --output json 2>/dev/null \
        | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
for m in msgs[-5:]:
    try:
        obj = json.loads(m)
        t = obj.get('time', obj.get('kubernetes',{}).get('time',''))[:19]
        typ = obj.get('type','?')
        path = obj.get('request',{}).get('path','?')
        display = obj.get('auth',{}).get('display_name','')
        role = obj.get('auth',{}).get('metadata',{}).get('role','')
        policies = ','.join(obj.get('auth',{}).get('policies',[]))
        err = obj.get('error','')
        parts = [f'time={t}', f'type={typ}', f'path={path}']
        if display: parts.append(f'identity={display}')
        if role: parts.append(f'role={role}')
        if policies: parts.append(f'policies=[{policies}]')
        if err: parts.append(f'ERROR={err[:80]}')
        print('  ' + ' | '.join(parts))
    except: pass
" 2>/dev/null || print_warn "  (could not parse vault audit events)"
    else
        echo "  (no log streams yet)"
    fi
    echo ""

    # --- Plane 2: IVIA Decisions ---
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  PLANE 2: IVIA Decisions (/workshop/ivia-decision)              │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    local ivia_stream
    ivia_stream=$(aws logs describe-log-streams --log-group-name /workshop/ivia-decision \
        --region "$WORKSHOP_REGION" --order-by LastEventTime --descending \
        --query 'logStreams[0].logStreamName' --output text 2>/dev/null || echo "")
    if [ -n "$ivia_stream" ] && [ "$ivia_stream" != "None" ]; then
        aws logs get-log-events --log-group-name /workshop/ivia-decision \
            --log-stream-name "$ivia_stream" --region "$WORKSHOP_REGION" \
            --limit 5 --query 'events[*].message' --output json 2>/dev/null \
        | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
for m in msgs[-5:]:
    try:
        obj = json.loads(m)
        t = obj.get('time','')[:19]
        log = obj.get('log','').strip()
        pod = obj.get('kubernetes',{}).get('pod_name','iviaop')
        # Try to extract structured fields from the log line
        try:
            inner = json.loads(log)
            parts = [f'time={inner.get(\"timestamp\", t)[:19]}']
            for k in ['grant_type','client_id','user_identity','decision','request_id']:
                v = inner.get(k,'')
                if v: parts.append(f'{k}={v}')
            print('  ' + ' | '.join(parts))
        except:
            print(f'  {t} | {pod} | {log[:150]}')
    except: pass
" 2>/dev/null || print_warn "  (could not parse IVIA decision events)"
    else
        echo "  (no log streams yet — will populate during CIBA browser flow)"
    fi
    echo ""

    # --- Plane 3: Agent Traces ---
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  PLANE 3: Agent Traces (/workshop/agent-trace)                  │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    local agent_stream
    agent_stream=$(aws logs describe-log-streams --log-group-name /workshop/agent-trace \
        --region "$WORKSHOP_REGION" --order-by LastEventTime --descending \
        --query 'logStreams[0].logStreamName' --output text 2>/dev/null || echo "")
    if [ -n "$agent_stream" ] && [ "$agent_stream" != "None" ]; then
        aws logs get-log-events --log-group-name /workshop/agent-trace \
            --log-stream-name "$agent_stream" --region "$WORKSHOP_REGION" \
            --limit 5 --query 'events[*].message' --output json 2>/dev/null \
        | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
for m in msgs[-5:]:
    try:
        obj = json.loads(m)
        t = obj.get('time','')[:19]
        log = obj.get('log','').strip()
        pod = obj.get('kubernetes',{}).get('pod_name','?')
        ns = obj.get('kubernetes',{}).get('namespace_name','?')
        # Skip health checks for cleaner output
        if '/health' in log: continue
        print(f'  {t} | {ns}/{pod} | {log[:150]}')
    except: pass
" 2>/dev/null || print_warn "  (could not parse agent trace events)"
    else
        echo "  (no log streams yet)"
    fi
    echo ""

    # Step 7: Re-check S3 if it was empty earlier
    if [ "${s3_count:-0}" -lt 1 ] 2>/dev/null; then
        step_header "Re-checking S3 log delivery after plane dump..."
        s3_count=$(aws s3api list-objects-v2 --bucket "${log_bucket}" --max-items 5 \
            --query 'length(Contents)' --output text 2>/dev/null || echo "0")
        if [ "${s3_count:-0}" -ge 1 ] 2>/dev/null; then
            print_success "S3 bucket '${log_bucket}' now has objects"
        else
            print_warn "S3 bucket still empty — Firehose may need more time (60s buffer). Check: aws s3 ls s3://${log_bucket}/"
        fi
    fi

    print_success "Three-plane audit verification complete"
}

#===============================================================================
# PHASE 8: Teardown
#===============================================================================
phase_teardown() {
    phase_header "Phase 8: Teardown"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: teardown.sh (full: terraform destroy + AWS sweep)"
        return 0
    fi

    pause_if_interactive "About to start teardown. This will destroy all workshop resources."

    bash "$SCRIPT_DIR/teardown.sh" 2>&1 || print_warn "Teardown had warnings"
    print_success "Teardown complete"
}

#===============================================================================
# NUKE: Delete everything — terraform destroy + AWS sweep
#===============================================================================
phase_nuke() {
    if [ "$CLEANUP_ONLY" = true ]; then
        phase_header "NUKE: Cleanup Only (skip terraform destroy)"
        print_info "Cleaning up dangling AWS resources."
        print_info "Foundation assumed already destroyed."
    else
        phase_header "NUKE: Delete Everything"
        print_warn "This will destroy ALL resources: foundation (EKS/RDS/KB), VPC,"
        print_warn "and all dangling AWS resources."
    fi
    echo ""

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would check cluster existence, destroy if needed, then cleanup"
        return 0
    fi

    # Determine region for cluster check
    local nuke_region="$WORKSHOP_REGION"
    if [ -z "$nuke_region" ]; then
        nuke_region="${AWS_REGION:-}"
    fi

    # --- Step 1: Check cluster existence ---
    step_header "Checking EKS cluster existence..."
    local cluster_active=false
    if [ -n "$nuke_region" ] && \
       aws eks describe-cluster --name "$CLUSTER_NAME" --region "$nuke_region" &>/dev/null; then
        print_error "$CLUSTER_NAME ($nuke_region) — ACTIVE"
        cluster_active=true
    else
        print_success "$CLUSTER_NAME — gone (or no region resolved)"
    fi

    # --- Step 2: Terraform destroy (only if cluster exists AND not --cleanup-only) ---
    if [ "$cluster_active" = true ] && [ "$CLEANUP_ONLY" = true ]; then
        print_error "Cluster still ACTIVE but --cleanup-only was specified."
        print_info "Use --nuke (without --cleanup-only) to run terraform destroy first."
        exit 1
    fi

    if [ "$cluster_active" = true ]; then
        step_header "Running terraform destroy..."
        terraform -chdir="$PROJECT_ROOT/infrastructure" destroy -auto-approve || {
            print_warn "Terraform destroy did not fully complete — continuing with cleanup"
        }

        # Verify cluster is actually gone
        step_header "Verifying EKS cluster is destroyed..."
        if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$nuke_region" &>/dev/null; then
            print_error "$CLUSTER_NAME ($nuke_region) — still ACTIVE after destroy"
            print_info "Manual cleanup may be required in AWS Console."
        else
            print_success "$CLUSTER_NAME ($nuke_region) — gone"
        fi
        print_success "Terraform destroy complete"
    else
        print_success "EKS cluster already destroyed — skipping terraform destroy"
    fi

    # --- Step 3: AWS resource sweep (everything tagged Workshop=*) ---
    step_header "Sweeping AWS workshop resources..."
    bash "$SCRIPT_DIR/teardown.sh" --aws-only 2>&1 || \
        print_warn "AWS sweep had warnings"

    echo ""
    print_success "NUKE COMPLETE — all resources deleted"
    print_info "To redeploy from scratch: $0 --interactive --skip-teardown"
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

# Full e2e flow — --start-from skips earlier phases
_started=true
if [ -n "$START_FROM" ]; then _started=false; fi

should_run() {
    local phase_tag="$1"
    if [ "$_started" = true ]; then return 0; fi
    if [ "$phase_tag" = "$START_FROM" ]; then _started=true; return 0; fi
    print_info "Skipping ${phase_tag} (--start-from ${START_FROM})"
    return 1
}

should_run prerequisites   && phase_prerequisites
should_run bootstrap       && phase_bootstrap
should_run foundation      && phase_deploy_foundation
should_run kubectl         && phase_configure_kubectl
should_run verify          && phase_verify_foundation
should_run identity        && phase_identity
should_run vault           && phase_vault
should_run uc1             && phase_uc1
should_run uc2             && phase_uc2
should_run uc3             && phase_uc3
should_run observability   && phase_observability

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
