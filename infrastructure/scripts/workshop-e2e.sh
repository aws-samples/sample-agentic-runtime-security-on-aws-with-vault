#!/usr/bin/env bash
#===============================================================================
# Workshop End-to-End Orchestration — Agentic Runtime Security on AWS
#
# Single-command deployment and validation of the entire workshop.
# Uses local Terraform execution with HCP Terraform as remote state backend.
#
#   Phase 0: Prerequisites (calls check-prerequisites.sh)
#   Phase 1: Bootstrap (calls bootstrap.sh — variable set + workspace)
#   Phase 2: Foundation deploy (local terraform apply)
#   Phase 3: Configure kubectl
#   Phase 4: Foundation verify (calls test-foundation.sh — EKS + RDS + Bedrock KB)
#   Phase 5: Identity (IVIA) — verify IVIA pods + OIDC discovery
#   Phase 6: Vault — init + configure (local via port-forward)
#   Phase 7a: Use Case 1 — Non-Personalized Read-Only (build images, deploy, verify)
#   Phase 7b: Use Case 2 — OAuth Personalized Read-Only (build images, deploy, configure, verify)
#   Phase 7c: Use Case 3 — CIBA Privileged (placeholder; Phase 6)
#   Phase 8: Teardown (calls teardown.sh — unless --skip-teardown)
#
# Usage: ./workshop-e2e.sh <HCP_ORG> [OPTIONS]
#
# Options:
#   --interactive       Pause between phases for manual verification
#   --skip-teardown     Leave deployment running after verification
#   --teardown-only     Skip deployment, run teardown only
#   --nuke              Delete EVERYTHING: AWS resources via terraform destroy,
#                        dangling AWS resources, HCP variable set
#   --cleanup-only      Skip terraform destroy — just clean up dangling AWS
#                        resources (ENIs, SGs, EIPs, VPCs) + HCP objects
#   --skip-addons       (no-op for now; reserved for future controllers)
#   --skip-prereq-gate  (no-op at this level; passed automatically to
#                        bootstrap.sh in Phase 1 since Phase 0 already runs
#                        check-prerequisites.sh — accepted for CLI symmetry)
#   --dry-run           Show what would be done without executing
#   --start-from PHASE  Skip phases before PHASE (e.g., --start-from uc1)
#   --project NAME      HCP project name (default: "Agentic Runtime Security")
#   --workspace NAME    HCP workspace name (default: "agentic-runtime-security")
#   --help              Show this help message
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - Terraform CLI installed and authenticated (terraform login)
#   - kubectl installed
#   - jq installed
#
# Examples:
#   # Full lifecycle: bootstrap -> deploy -> verify -> teardown
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
#   # Nuke: terraform destroy + clean up everything
#   ./scripts/workshop-e2e.sh MyOrg --nuke
#
#   # Cleanup only: foundation already destroyed, just remove leftovers
#   ./scripts/workshop-e2e.sh MyOrg --cleanup-only
#
#   # Preview what any command would do
#   ./scripts/workshop-e2e.sh MyOrg --nuke --dry-run
#
#   # Use a specific project
#   ./scripts/workshop-e2e.sh MyOrg --project "My Project"
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
INTERACTIVE=false
SKIP_TEARDOWN=false
TEARDOWN_ONLY=false
NUKE=false
CLEANUP_ONLY=false
SKIP_ADDONS=false
DRY_RUN=false
START_FROM=""
WORKSPACE_NAME="agentic-runtime-security"

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
        --workspace)      WORKSPACE_NAME="$2"; shift ;;
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
        --project)        HCP_PROJECT="$2"; shift ;;
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
    echo "Set AWS_REGION or ensure infrastructure/terraform.tfvars is present."
    exit 1
fi

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
# PHASE 1: Bootstrap (Variable Set + Workspace)
#===============================================================================
phase_bootstrap() {
    phase_header "Phase 1: Bootstrap (Variable Set + Workspace)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: bootstrap.sh $HCP_ORG --skip-prereq-gate"
        return 0
    fi

    # Check if variable set already configured — fast path
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ] && \
       [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfvars" ]; then
        print_info "Verifying variable set is current..."
        terraform -chdir="$SCRIPT_DIR/hcp-setup" apply -auto-approve -input=false >/dev/null 2>&1 && {
            print_success "Variable set verified — bootstrap already complete"
            return 0
        }
        print_warn "Variable set refresh failed — re-running full bootstrap"
    fi

    bash "$SCRIPT_DIR/bootstrap.sh" "$HCP_ORG" --skip-prereq-gate
}

#===============================================================================
# PHASE 2: Foundation Deploy
#===============================================================================
phase_deploy_foundation() {
    phase_header "Phase 2: Foundation Deploy (EKS + RDS + Bedrock KB)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: terraform -chdir=infrastructure apply -auto-approve"
        print_info "[DRY-RUN] Would call configure-workshop.sh after apply completes"
        return 0
    fi

    export TF_CLOUD_ORGANIZATION="$HCP_ORG"

    step_header "Running terraform apply (local execution, HCP remote state)..."
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

    # Provision Simple AD users before verification checks them
    local ad_dns_ip ad_password
    ad_dns_ip=$(cd "${PROJECT_ROOT}/infrastructure" && terraform output -json 2>/dev/null \
        | jq -r '.simple_ad_dns_ips.value[0] // empty' 2>/dev/null || echo "")
    ad_password=$(grep -E '^simple_ad_admin_password\s*=' "${TF_VARS}" 2>/dev/null \
        | sed 's/.*=\s*"\(.*\)"/\1/' || echo "")
    if [ -n "$ad_dns_ip" ] && [ -n "$ad_password" ]; then
        step_header "Provisioning Simple AD users..."
        bash "$SCRIPT_DIR/create-simple-ad-users.sh" \
            --ldap-host "$ad_dns_ip" \
            --admin-password "$ad_password" \
            || print_warn "Simple AD user provisioning had warnings"
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
    local oidc_url="https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration"

    # Check IVIA pods
    local running_ivia
    running_ivia=$(kubectl get pods -n "${ivia_ns}" --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${running_ivia:-0}" -ge 1 ]; then
        print_success "IVIA: ${running_ivia} pod(s) Running in ${ivia_ns}"
    else
        print_warn "IVIA: no pods Running in ${ivia_ns} — IVIA may still be starting"
    fi

    # Check OIDC discovery via a temporary curl pod (vault-0 may not be ready yet)
    local ivia_issuer=""
    ivia_issuer=$(kubectl run ivia-check --image=curlimages/curl --rm -i --restart=Never \
        -n "${ivia_ns}" -- curl -sk "${oidc_url}" 2>/dev/null \
        | jq -r '.issuer // empty' 2>/dev/null || echo "")
    if [ -n "${ivia_issuer}" ]; then
        print_success "IVIA OIDC discovery: issuer = ${ivia_issuer}"
    else
        print_warn "IVIA OIDC discovery: issuer not reachable (IVIA may still be initializing)"
    fi

    pause_if_interactive "IVIA verification complete."
}

#===============================================================================
# PHASE 6: Vault — init + configure (local via port-forward)
# Step 1: vault-init.sh — initialize Vault, save root token + recovery keys
# Step 2: vault-configure.sh — port-forward, terraform apply vault-config + isva-config
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
        print_info "[DRY-RUN] Would run terraform apply, then verify-uc1.sh"
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
    else
        sed -i.bak "s|uc1_agent_image *= *\"[^\"]*\"|uc1_agent_image = \"${ecr_uri}\"|" "$deploy_file"
        rm -f "${deploy_file}.bak"
        print_success "uc1_agent_image = $ecr_uri"
    fi

    # Step 3: Terraform apply
    step_header "Running terraform apply for UC1 deployment..."
    export TF_CLOUD_ORGANIZATION="$HCP_ORG"
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

    # Step 5: Verify
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
        else
            sed -i.bak "s|${var_name}[[:space:]]*=[[:space:]]*\"[^\"]*\"|${var_name} = \"${var_image}\"|" "$deploy_file"
            rm -f "${deploy_file}.bak"
            print_success "${var_name} = ${var_image}"
        fi
    done

    # Step 3: Terraform apply
    step_header "Running terraform apply for UC2 deployment..."
    export TF_CLOUD_ORGANIZATION="$HCP_ORG"
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
# NUKE: Delete everything — terraform destroy + AWS sweep + HCP variable set
#===============================================================================
phase_nuke() {
    if [ "$CLEANUP_ONLY" = true ]; then
        phase_header "NUKE: Cleanup Only (skip terraform destroy)"
        print_info "Cleaning up dangling AWS resources + HCP objects."
        print_info "Foundation assumed already destroyed."
    else
        phase_header "NUKE: Delete Everything"
        print_warn "This will destroy ALL resources: foundation (EKS/RDS/KB), VPC,"
        print_warn "HCP variable set, and all dangling AWS resources."
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
        export TF_CLOUD_ORGANIZATION="$HCP_ORG"
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

    # --- Step 3: Cleanup (always runs) ---

    # 3a: AWS resource sweep (everything tagged Workshop=*)
    step_header "Sweeping AWS workshop resources..."
    bash "$SCRIPT_DIR/teardown.sh" --aws-only 2>&1 || \
        print_warn "AWS sweep had warnings"

    # 3b: Destroy HCP variable set via terraform
    step_header "Destroying HCP variable set..."
    if [ -f "$SCRIPT_DIR/hcp-setup/terraform.tfstate" ]; then
        terraform -chdir="$SCRIPT_DIR/hcp-setup" destroy -auto-approve -input=false >/dev/null 2>&1 && \
            print_success "HCP variable set destroyed" || \
            print_warn "Variable set destroy had errors (may already be gone)"
    else
        print_info "No terraform state found — variable set may already be destroyed"
    fi

    # 3c: Clean up local state
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
should_run uc3             && phase_uc3_placeholder

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
