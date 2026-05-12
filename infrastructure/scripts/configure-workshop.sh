#!/usr/bin/env bash
#===============================================================================
# configure-workshop.sh — Post-Deploy Workshop Configuration
#
# Run after HCP workspace apply converges. Configures the full workshop
# environment in sequence:
#   Step 1: Configure kubectl (aws eks update-kubeconfig)
#   Step 2: Initialize Vault (vault-init.sh)
#   Step 3: Configure Vault (vault-configure.sh)
#   Step 4: Configure IVIA (ivia-configure.sh)
#   Step 5: Seed banking DB (seed-banking-db.sh)
#
# Idempotent — safe to re-run. Each step self-verifies its result.
# Missing sub-scripts are skipped with a warning (not a fatal error).
#
# Usage: ./configure-workshop.sh [OPTIONS]
#
# Options:
#   --region REGION          AWS region (default: parsed from terraform.tfvars)
#   --cluster-name NAME      EKS cluster name (default: parsed from terraform.tfvars)
#   --skip-vault-init        Skip Vault initialization (Vault already initialized)
#   --dry-run                Print planned actions without executing
#   --help                   Show this help message
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - kubectl installed
#   - Vault CLI installed
#   - HCP workspace apply complete (EKS cluster + Vault pods running)
#
# Examples:
#   # Full post-deploy configuration
#   ./configure-workshop.sh
#
#   # Specify region and cluster name explicitly
#   ./configure-workshop.sh --region us-west-2 --cluster-name agentic-runtime-security
#
#   # Skip vault-init if Vault is already initialized
#   ./configure-workshop.sh --skip-vault-init
#
#   # Preview what would be done
#   ./configure-workshop.sh --dry-run
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Suppress the common-checks EXIT trap — we emit our own summary at end.
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
REGION=""
CLUSTER_NAME=""
SKIP_VAULT_INIT=false
DRY_RUN=false

# Vault port-forward PID (cleaned up on exit)
VAULT_PF_PID=""

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    sed -n '2,44p' "$0"
    exit 0
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)          usage ;;
        --region)           REGION="$2"; shift ;;
        --cluster-name)     CLUSTER_NAME="$2"; shift ;;
        --skip-vault-init)  SKIP_VAULT_INIT=true ;;
        --dry-run)          DRY_RUN=true ;;
        -*) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

#-------------------------------------------------------------------------------
# Resolve REGION and CLUSTER_NAME from terraform.tfvars if not supplied
#-------------------------------------------------------------------------------
TFVARS="${PROJECT_ROOT}/infrastructure/terraform.tfvars"
TFVARS_EXAMPLE="${PROJECT_ROOT}/infrastructure/terraform.tfvars.example"

_resolve_tfvar() {
    local key="$1"
    local file=""
    if [[ -f "$TFVARS" ]]; then
        file="$TFVARS"
    elif [[ -f "$TFVARS_EXAMPLE" ]]; then
        file="$TFVARS_EXAMPLE"
    fi
    if [[ -n "$file" ]]; then
        grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
            | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
    fi
}

if [[ -z "$REGION" ]]; then
    REGION=$(_resolve_tfvar "region")
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(_resolve_tfvar "cluster_name")
fi

if [[ -z "$REGION" ]]; then
    print_fail "REGION" "Pass --region <region> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    print_fail "CLUSTER_NAME" "Pass --cluster-name <name> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi

#-------------------------------------------------------------------------------
# EXIT cleanup — kill port-forward on any exit
#-------------------------------------------------------------------------------
_cleanup() {
    if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
        kill "$VAULT_PF_PID" 2>/dev/null || true
    fi
    print_summary
}
trap '_cleanup' EXIT

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
_run_subscript() {
    local label="$1"
    local script_path="$2"
    shift 2
    local args=("$@")

    if [[ ! -f "$script_path" ]]; then
        print_warn "${label}: ${script_path} not found — skipping"
        return 0
    fi

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: ${script_path} ${args[*]}"
        return 0
    fi

    "${script_path}" "${args[@]}"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        print_fail "${label}" "Re-run: ${script_path} ${args[*]}"
        return 1
    fi
    return 0
}

_wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf "http://localhost:${port}/v1/sys/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

#-------------------------------------------------------------------------------
# Header
#-------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Workshop Post-Deploy Configuration${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""
print_info "Region:       ${REGION}"
print_info "Cluster:      ${CLUSTER_NAME}"
print_info "Skip Vault init: ${SKIP_VAULT_INIT}"
if [[ "$DRY_RUN" = true ]]; then
    print_warn "DRY-RUN mode — no changes will be made"
fi
echo ""

#===============================================================================
# STEP 1: Configure kubectl
#===============================================================================
echo -e "${YELLOW}> Step 1: Configure kubectl${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} --alias workshop"
    print_pass "Step 1: Configure kubectl (dry-run)"
else
    if aws eks update-kubeconfig \
            --region "${REGION}" \
            --name "${CLUSTER_NAME}" \
            --alias workshop \
            >/dev/null 2>&1; then
        # Verify connectivity
        if kubectl --context workshop get nodes --no-headers >/dev/null 2>&1; then
            local_node_count=$(kubectl --context workshop get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
            print_pass "Step 1: Configure kubectl (${local_node_count} node(s) reachable)"
        else
            print_fail "Step 1: Configure kubectl — nodes not reachable" \
                "Check EKS cluster status: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
        fi
    else
        print_fail "Step 1: Configure kubectl — update-kubeconfig failed" \
            "Ensure EKS cluster is Active: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
    fi
fi

#===============================================================================
# STEP 2: Initialize Vault (skip if --skip-vault-init)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 2: Initialize Vault${NC}"

if [[ "$SKIP_VAULT_INIT" = true ]]; then
    print_info "Step 2: Vault init skipped (--skip-vault-init)"
    PASSES+=("Step 2: Initialize Vault (skipped)")
elif [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: vault-init.sh"
    print_pass "Step 2: Initialize Vault (dry-run)"
else
    # Start port-forward in background (vault-init.sh may also do this; pass
    # through — vault-init.sh is idempotent if Vault is already initialized)
    if kubectl --context workshop get pods -n vault vault-0 --no-headers >/dev/null 2>&1; then
        if _run_subscript "Step 2: vault-init" "${SCRIPT_DIR}/vault-init.sh"; then
            # Verify: vault status should show initialized=true, sealed=false
            # port-forward for check (vault-init.sh cleans up its own port-forward)
            kubectl --context workshop port-forward svc/vault -n vault 8200:8200 \
                >/dev/null 2>&1 &
            VAULT_PF_PID=$!
            if _wait_for_port 8200 30; then
                VAULT_STATUS=$(VAULT_ADDR="http://localhost:8200" \
                    vault status -format=json 2>/dev/null || echo '{}')
                VAULT_INIT=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')
                VAULT_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')
                if [[ "$VAULT_INIT" = "true" ]] && [[ "$VAULT_SEALED" = "false" ]]; then
                    print_pass "Step 2: Initialize Vault (initialized=true, sealed=false)"
                else
                    print_fail "Step 2: Initialize Vault" \
                        "Vault status: initialized=${VAULT_INIT} sealed=${VAULT_SEALED}. Check vault-0 logs: kubectl logs -n vault vault-0"
                fi
            else
                print_warn "Step 2: Could not verify Vault status via port-forward — vault-init may still be in progress"
            fi
            # Kill our temporary port-forward (vault-configure.sh starts its own)
            if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
                kill "$VAULT_PF_PID" 2>/dev/null || true
                VAULT_PF_PID=""
            fi
        fi
    else
        print_fail "Step 2: Initialize Vault" \
            "Vault pod vault-0 not found. Ensure EKS + Vault deploy completed: kubectl get pods -n vault"
    fi
fi

#===============================================================================
# STEP 3: Configure Vault (vault-configure.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 3: Configure Vault${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: vault-configure.sh"
    print_pass "Step 3: Configure Vault (dry-run)"
else
    if _run_subscript "Step 3: vault-configure" "${SCRIPT_DIR}/vault-configure.sh"; then
        # Verify: vault auth list should show kubernetes/ and jwt/
        kubectl --context workshop port-forward svc/vault -n vault 8200:8200 \
            >/dev/null 2>&1 &
        VAULT_PF_PID=$!
        if _wait_for_port 8200 30; then
            ROOT_TOKEN=""
            if [[ -f "${HOME}/vault-init.json" ]]; then
                ROOT_TOKEN=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || echo "")
            fi
            if [[ -n "$ROOT_TOKEN" ]]; then
                AUTH_LIST=$(VAULT_ADDR="http://localhost:8200" VAULT_TOKEN="$ROOT_TOKEN" \
                    vault auth list -format=json 2>/dev/null || echo '{}')
                K8S_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "kubernetes/")' 2>/dev/null || echo "")
                JWT_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "jwt/")' 2>/dev/null || echo "")
                if [[ -n "$K8S_ENABLED" ]] && [[ -n "$JWT_ENABLED" ]]; then
                    print_pass "Step 3: Configure Vault (kubernetes/ and jwt/ auth methods enabled)"
                else
                    print_fail "Step 3: Configure Vault — auth methods missing" \
                        "kubernetes=${K8S_ENABLED:-MISSING} jwt=${JWT_ENABLED:-MISSING}. Re-run: ${SCRIPT_DIR}/vault-configure.sh"
                fi
            else
                print_warn "Step 3: Could not verify Vault auth — root token not found in ~/vault-init.json"
            fi
        else
            print_warn "Step 3: Could not verify Vault auth via port-forward"
        fi
        if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
            kill "$VAULT_PF_PID" 2>/dev/null || true
            VAULT_PF_PID=""
        fi
    fi
fi

#===============================================================================
# STEP 4: Configure IVIA (ivia-configure.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 4: Configure IVIA${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: ivia-configure.sh"
    print_pass "Step 4: Configure IVIA (dry-run)"
else
    if _run_subscript "Step 4: ivia-configure" "${SCRIPT_DIR}/ivia-configure.sh"; then
        # Verify: IVIA health endpoint responds
        IVIA_HEALTH=""
        if kubectl --context workshop get pods -n verify-access --no-headers 2>/dev/null | grep -q Running; then
            kubectl --context workshop port-forward \
                svc/isvaop -n verify-access 8436:8436 \
                >/dev/null 2>&1 &
            _IVIA_PF_PID=$!
            sleep 3
            IVIA_HEALTH=$(curl -sk \
                "https://localhost:8436/sps/oauth/oauth20/.well-known/openid-configuration" \
                2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")
            kill "$_IVIA_PF_PID" 2>/dev/null || true
        fi
        if [[ -n "$IVIA_HEALTH" ]]; then
            print_pass "Step 4: Configure IVIA (OIDC issuer: ${IVIA_HEALTH})"
        else
            print_warn "Step 4: Could not verify IVIA OIDC health endpoint (IVIA may still be starting)"
        fi
    fi
fi

#===============================================================================
# STEP 5: Seed Banking DB (seed-banking-db.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 5: Seed Banking DB${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: seed-banking-db.sh --region ${REGION}"
    print_pass "Step 5: Seed Banking DB (dry-run)"
else
    if _run_subscript "Step 5: seed-banking-db" \
            "${SCRIPT_DIR}/seed-banking-db.sh" \
            --region "${REGION}"; then
        # Verify: seed-banking-db.sh is self-verifying; if it exited 0, seeding succeeded.
        print_pass "Step 5: Seed Banking DB (script verified successfully)"
    fi
fi

#===============================================================================
# Summary is emitted by the EXIT trap (_cleanup)
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Configuration Complete${NC}"
echo -e "${BLUE}================================================================${NC}"
