#!/usr/bin/env bash
#===============================================================================
# test-vault-verify.sh — Platform verification for Vault + Verify Access
#
# Validates all platform health checks after Phase 3 components are deployed:
#   1. Vault pods running (3 of 3 in vault namespace)
#   2. Vault seal status (unsealed)
#   3. Vault Raft peers (3 peers)
#   4. Vault audit device enabled
#   5. IVIA pods running in verify-access namespace
#   6. IVIA OIDC discovery reachable (issuer non-empty)
#   7. cert-manager pods running
#   8. AWS Load Balancer Controller running
#
# Usage:
#   ./test-vault-verify.sh [--help]
#
# Env-var overrides:
#   VAULT_NAMESPACE       (default: vault)
#   IVIA_NAMESPACE        (default: verify-access)
#   IVIA_OIDC_URL         (default: https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration)
#   VAULT_POD             (default: vault-0)
#
# Per common-checks.sh design: this script does NOT use `set -e`.
# All checks run regardless of failures; summary is printed at the end.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DESCRIPTION="Platform — Vault and Verify Access verification"

# Source common helpers (print_pass, print_fail, print_warn, print_info,
# FAILURES[] accumulator, print_summary, EXIT trap).
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<USAGE
test-vault-verify.sh — ${SCRIPT_DESCRIPTION}

Usage:
  ./test-vault-verify.sh [--help]

Checks (8 total):
  1. Vault pods running (3 of 3)
  2. Vault seal status: unsealed
  3. Vault Raft peers: 3
  4. Vault audit device: enabled
  5. IVIA pods running
  6. IVIA OIDC discovery: issuer reachable
  7. cert-manager pods running
  8. AWS Load Balancer Controller running

Env-var overrides:
  VAULT_NAMESPACE   (default: vault)
  IVIA_NAMESPACE    (default: verify-access)
  IVIA_OIDC_URL     (default: https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration)
  VAULT_POD         (default: vault-0)
USAGE
    exit 0
fi

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
IVIA_NAMESPACE="${IVIA_NAMESPACE:-verify-access}"
IVIA_OIDC_URL="${IVIA_OIDC_URL:-https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_LABEL="app.kubernetes.io/name=vault"
LBC_LABEL="app.kubernetes.io/name=aws-load-balancer-controller"

# Load Vault root token for authenticated checks (raft peers, audit device)
VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}"
if [ -z "$VAULT_ROOT_TOKEN" ] && [ -f "$HOME/vault-init.json" ]; then
    VAULT_ROOT_TOKEN=$(jq -r '.root_token // empty' "$HOME/vault-init.json" 2>/dev/null || true)
fi

print_info "${SCRIPT_DESCRIPTION}"
echo ""

#-------------------------------------------------------------------------------
# Check 1 — Vault pods running (3 of 3)
#-------------------------------------------------------------------------------
running_vault=$(kubectl get pods -n "${VAULT_NAMESPACE}" -l "${VAULT_LABEL}" \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_vault}" -ge 3 ]; then
    print_pass "Vault pods running (${running_vault} of 3)"
else
    print_fail "Vault pods running" \
        "Only ${running_vault}/3 Vault pods Running. Check: kubectl get pods -n ${VAULT_NAMESPACE} -l ${VAULT_LABEL}. If 0, ensure the workspace apply completed successfully."
fi

#-------------------------------------------------------------------------------
# Check 2 — Vault seal status (unsealed)
#-------------------------------------------------------------------------------
sealed=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "error")
if [ "${sealed}" = "false" ]; then
    print_pass "Vault seal status: unsealed"
elif [ "${sealed}" = "true" ]; then
    print_fail "Vault seal status" \
        "Vault is sealed. Run: kubectl exec -it -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault operator init -key-shares=1 -key-threshold=1 -format=json. If already initialized, KMS auto-unseal may be failing — check Pod Identity association."
else
    print_fail "Vault seal status" \
        "Could not reach ${VAULT_POD} (got '${sealed}'). Check pod is Running: kubectl get pod -n ${VAULT_NAMESPACE} ${VAULT_POD}"
fi

#-------------------------------------------------------------------------------
# Check 3 — Vault Raft peers (3 peers)
#-------------------------------------------------------------------------------
raft_peers=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault operator raft list-peers -format=json" 2>/dev/null \
    | jq '.data.config.servers | length' 2>/dev/null || echo "0")
if [ "${raft_peers}" -ge 3 ]; then
    print_pass "Vault Raft peers: ${raft_peers}"
else
    print_fail "Vault Raft peers" \
        "Expected 3 Raft peers, found ${raft_peers}. If Vault is not initialized, run vault operator init first. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault operator raft list-peers"
fi

#-------------------------------------------------------------------------------
# Check 4 — Vault audit device enabled
#-------------------------------------------------------------------------------
audit_count=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault audit list -format=json" 2>/dev/null \
    | jq 'length' 2>/dev/null || echo "0")
if [ "${audit_count:-0}" -ge 1 ]; then
    print_pass "Vault audit device: enabled (${audit_count} device(s))"
else
    print_fail "Vault audit device" \
        "No audit devices found. The vault_config module enables the audit device. Verify vault_config applied: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault audit list"
fi

#-------------------------------------------------------------------------------
# Check 5 — IVIA pods running
#-------------------------------------------------------------------------------
running_ivia=$(kubectl get pods -n "${IVIA_NAMESPACE}" \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_ivia}" -ge 1 ]; then
    print_pass "IVIA pods running (${running_ivia} pod(s))"
else
    print_fail "IVIA pods running" \
        "No IVIA pods Running in ${IVIA_NAMESPACE}. Check: kubectl get pods -n ${IVIA_NAMESPACE}. If ImagePullBackOff, the ibm_entitlement_key HCP variable is missing or incorrect."
fi

#-------------------------------------------------------------------------------
# Check 6 — IVIA OIDC discovery reachable
#-------------------------------------------------------------------------------
ivia_issuer=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    curl -sk "${IVIA_OIDC_URL}" 2>/dev/null \
    | jq -r '.issuer // empty' 2>/dev/null || echo "")
if [ -n "${ivia_issuer}" ]; then
    print_pass "IVIA OIDC discovery: issuer reachable (${ivia_issuer})"
else
    print_fail "IVIA OIDC discovery" \
        "OIDC discovery URL returned no issuer. Check IVIA pod logs: kubectl logs -n ${IVIA_NAMESPACE} -l app=ivia. Ensure isvaop Service exists: kubectl get svc -n ${IVIA_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 7 — cert-manager pods running
#-------------------------------------------------------------------------------
running_cm=$(kubectl get pods -n cert-manager \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_cm}" -ge 1 ]; then
    print_pass "cert-manager pods running (${running_cm} pod(s))"
else
    print_fail "cert-manager pods running" \
        "No cert-manager pods Running. Check the addons module: kubectl get pods -n cert-manager. Re-apply the addons component in HCP Terraform if needed."
fi

#-------------------------------------------------------------------------------
# Check 8 — AWS Load Balancer Controller running
#-------------------------------------------------------------------------------
running_lbc=$(kubectl get pods -n kube-system -l "${LBC_LABEL}" \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_lbc}" -ge 1 ]; then
    print_pass "AWS Load Balancer Controller running (${running_lbc} pod(s))"
else
    print_fail "AWS Load Balancer Controller running" \
        "No AWS LBC pods Running. Check the addons component: kubectl get pods -n kube-system -l ${LBC_LABEL}. Re-apply the addons component in HCP Terraform if needed."
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
