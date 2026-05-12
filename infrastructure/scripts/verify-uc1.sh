#!/usr/bin/env bash
#===============================================================================
# verify-uc1.sh — Use Case 1 end-to-end verification
#
# Validates all UC1 success criteria after Phase 4 components are deployed:
#   1. UC1 agent pod Running in uc1 namespace
#   2. UC1 ServiceAccount uc1-retriever-sa exists
#   3. Vault role uc1 bound to uc1-retriever-sa
#   4. JIT DB creds issuance (database/creds/uc1-readonly)
#   5. JIT STS creds issuance (aws/sts/bedrock-reader)
#   6. Agent /health endpoint returns "healthy"
#   7. ENFC-01: uc1-readonly policy does NOT grant UC3 database path access
#   8. Vault audit device enabled (>= 1 audit device)
#
# Usage:
#   ./verify-uc1.sh [--help]
#
# Env-var overrides:
#   UC1_NAMESPACE         (default: uc1)
#   VAULT_NAMESPACE       (default: vault)
#   VAULT_POD             (default: vault-0)
#   VAULT_ADDR            (default: http://vault.vault.svc.cluster.local:8200)
#
# Per common-checks.sh design: this script does NOT use `set -e`.
# All checks run regardless of failures; summary is printed at the end.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DESCRIPTION="Use Case 1 — Non-Personalized Read-Only verification"

# Source common helpers (print_pass, print_fail, print_warn, print_info,
# FAILURES[] accumulator, print_summary, EXIT trap).
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<USAGE
verify-uc1.sh — ${SCRIPT_DESCRIPTION}

Usage:
  ./verify-uc1.sh [--help]

Checks (8 total):
  1. UC1 agent pod Running (app=uc1-agent in uc1 namespace)
  2. UC1 ServiceAccount uc1-retriever-sa exists
  3. Vault role uc1 bound to uc1-retriever-sa
  4. JIT DB creds issuance (database/creds/uc1-readonly)
  5. JIT STS creds issuance (aws/sts/bedrock-reader)
  6. Agent /health endpoint returns "healthy"
  7. ENFC-01: uc1-readonly policy does not grant UC3 database path access
  8. Vault audit device enabled

Env-var overrides:
  UC1_NAMESPACE     (default: uc1)
  VAULT_NAMESPACE   (default: vault)
  VAULT_POD         (default: vault-0)
  VAULT_ADDR        (default: http://vault.vault.svc.cluster.local:8200)
USAGE
    exit 0
fi

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
UC1_NAMESPACE="${UC1_NAMESPACE:-uc1}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"

print_info "${SCRIPT_DESCRIPTION}"
echo ""

#-------------------------------------------------------------------------------
# Check 1 — UC1 agent pod Running
#-------------------------------------------------------------------------------
running_uc1=$(kubectl get pods -n "${UC1_NAMESPACE}" -l app=uc1-agent \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_uc1:-0}" -ge 1 ]; then
    print_pass "UC1 agent pod Running (${running_uc1} pod(s) in ${UC1_NAMESPACE})"
else
    print_fail "UC1 agent pod Running" \
        "UC1 agent pod not running — verify workspace apply completed and image URI is correct. Check: kubectl get pods -n ${UC1_NAMESPACE} -l app=uc1-agent"
fi

#-------------------------------------------------------------------------------
# Check 2 — UC1 ServiceAccount exists
#-------------------------------------------------------------------------------
if kubectl get sa uc1-retriever-sa -n "${UC1_NAMESPACE}" --no-headers &>/dev/null; then
    print_pass "UC1 ServiceAccount uc1-retriever-sa exists"
else
    print_fail "UC1 ServiceAccount exists" \
        "ServiceAccount uc1-retriever-sa not found — check uc1_agent module in workspace run. Run: kubectl get sa -n ${UC1_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 3 — Vault role uc1 bound to uc1-retriever-sa
#-------------------------------------------------------------------------------
vault_role_sa=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault read auth/kubernetes/role/uc1 -format=json 2>/dev/null \
    | jq -r '.data.bound_service_account_names[0]' 2>/dev/null || echo "")
if [ "${vault_role_sa}" = "uc1-retriever-sa" ]; then
    print_pass "Vault role uc1 bound to uc1-retriever-sa"
else
    print_fail "Vault role uc1 binding" \
        "Vault role uc1 not bound to uc1-retriever-sa (got '${vault_role_sa}') — reapply the workspace run. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/kubernetes/role/uc1"
fi

#-------------------------------------------------------------------------------
# Check 4 — JIT DB creds issuance (database/creds/uc1-readonly)
#-------------------------------------------------------------------------------
db_username=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault read database/creds/uc1-readonly -format=json 2>/dev/null \
    | jq -r '.data.username' 2>/dev/null || echo "")
if [ -n "${db_username}" ] && [ "${db_username}" != "null" ]; then
    print_pass "JIT DB creds issuance: username=${db_username}"
else
    print_fail "JIT DB creds issuance" \
        "Cannot generate DB creds from database/creds/uc1-readonly — verify RDS connectivity and vault_config database connection. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read database/creds/uc1-readonly"
fi

#-------------------------------------------------------------------------------
# Check 5 — JIT STS creds issuance (aws/sts/bedrock-reader)
#-------------------------------------------------------------------------------
sts_access_key=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault read aws/sts/bedrock-reader -format=json 2>/dev/null \
    | jq -r '.data.access_key' 2>/dev/null || echo "")
if [ -n "${sts_access_key}" ] && [ "${sts_access_key}" != "null" ]; then
    print_pass "JIT STS creds issuance: access_key=${sts_access_key:0:8}..."
else
    print_fail "JIT STS creds issuance" \
        "Cannot generate STS creds from aws/sts/bedrock-reader — verify bedrock_role_arn and Vault AWS secrets engine config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read aws/sts/bedrock-reader"
fi

#-------------------------------------------------------------------------------
# Check 6 — Agent /health endpoint returns "healthy"
#-------------------------------------------------------------------------------
agent_health=$(kubectl exec -n "${UC1_NAMESPACE}" deploy/uc1-agent -- \
    curl -s http://localhost:8080/health 2>/dev/null \
    | jq -r '.status' 2>/dev/null || echo "")
if [ "${agent_health}" = "healthy" ]; then
    print_pass "Agent /health endpoint: healthy"
else
    print_fail "Agent /health endpoint" \
        "Agent health check returned '${agent_health}' (expected 'healthy') — check pod logs: kubectl logs -n ${UC1_NAMESPACE} deploy/uc1-agent"
fi

#-------------------------------------------------------------------------------
# Check 7 — ENFC-01: uc1-readonly policy does NOT grant UC3 database path access
#
# Read the uc1-readonly Vault policy and check whether it contains any path
# allowing access to database/creds/uc3-refund-writer. If found → FAIL.
# Policy isolation is the ENFC-01 enforcement point.
#-------------------------------------------------------------------------------
uc1_policy=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault policy read uc1-readonly 2>/dev/null || echo "")
if echo "${uc1_policy}" | grep -q 'uc3-refund-writer'; then
    print_fail "ENFC-01: UC3 cred rejection" \
        "ENFC-01 FAIL: uc1-readonly policy incorrectly grants UC3 database path access (uc3-refund-writer found in policy). Reapply vault_config component to enforce policy isolation."
else
    print_pass "ENFC-01: uc1-readonly policy does not grant UC3 (uc3-refund-writer) path access"
fi

#-------------------------------------------------------------------------------
# Check 8 — Vault audit device enabled (>= 1 device)
#-------------------------------------------------------------------------------
audit_count=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault audit list -format=json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [ "${audit_count:-0}" -ge 1 ]; then
    print_pass "Vault audit device: enabled (${audit_count} device(s))"
else
    print_fail "Vault audit device" \
        "Vault audit device not enabled — reapply vault_config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault audit list"
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
