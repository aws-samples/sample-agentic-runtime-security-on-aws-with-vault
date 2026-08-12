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
#   9. Vault Enterprise edition (native Agent Registry is Enterprise-only)
#  10. database/ + aws/ secrets engines mounted (license-module gate)
#  11. agent-registry responds (uc1-agent registration resolvable by display-name)
#  12. oauth-resource-server profile 'ivia' responds
#  13. jwt/ auth mount ABSENT (retired IVIA jwt backend gone — decision (e))
#
# Usage:
#   ./test-vault-verify.sh [--help]
#
# Env-var overrides:
#   VAULT_NAMESPACE       (default: vault)
#   IVIA_NAMESPACE        (default: verify-access)
#   IVIA_OIDC_URL         (default: https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration)
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

Checks (13 total):
  1. Vault pods running (3 of 3)
  2. Vault seal status: unsealed
  3. Vault Raft peers: 3
  4. Vault audit device: enabled
  5. IVIA pods running
  6. IVIA OIDC discovery: issuer reachable
  7. cert-manager pods running
  8. AWS Load Balancer Controller running
  9. Vault Enterprise edition (native Agent Registry is Enterprise-only)
 10. database/ + aws/ secrets engines mounted (license-module gate)
 11. agent-registry responds (uc1-agent registration by display-name)
 12. oauth-resource-server profile 'ivia' responds
 13. jwt/ auth mount ABSENT (retired IVIA jwt backend gone — decision (e))

Env-var overrides:
  VAULT_NAMESPACE   (default: vault)
  IVIA_NAMESPACE    (default: verify-access)
  IVIA_OIDC_URL     (default: https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration)
  VAULT_POD         (default: vault-0)
USAGE
    exit 0
fi

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
IVIA_NAMESPACE="${IVIA_NAMESPACE:-verify-access}"
IVIA_OIDC_URL="${IVIA_OIDC_URL:-https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration}"
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
        "No IVIA pods Running in ${IVIA_NAMESPACE}. Check: kubectl get pods -n ${IVIA_NAMESPACE}. If ImagePullBackOff, verify ibm_entitlement_key is set in infrastructure/terraform.tfvars."
fi

#-------------------------------------------------------------------------------
# Check 6 — IVIA OIDC discovery reachable
#-------------------------------------------------------------------------------
ivia_issuer=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "wget -q -O - --no-check-certificate --timeout=10 '${IVIA_OIDC_URL}'" 2>/dev/null \
    | jq -r '.issuer // empty' 2>/dev/null || echo "")
if [ -n "${ivia_issuer}" ]; then
    print_pass "IVIA OIDC discovery: issuer reachable (${ivia_issuer})"
else
    print_fail "IVIA OIDC discovery" \
        "OIDC discovery URL returned no issuer. Check IVIA pod logs: kubectl logs -n ${IVIA_NAMESPACE} -l app=iviaop --tail=-1 (--tail=-1 is required: with -l, kubectl logs shows only the last 10 lines by default). Ensure iviaop Service exists: kubectl get svc -n ${IVIA_NAMESPACE}"
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
        "No cert-manager pods Running. Check the addons module: kubectl get pods -n cert-manager. Re-apply the addons module if needed."
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
        "No AWS LBC pods Running. Check the addons module: kubectl get pods -n kube-system -l ${LBC_LABEL}. Re-apply the addons module if needed."
fi

#===============================================================================
# Phase 9 native-surface assertions (Agent Registry + OAuth resource server)
#
# These prove the Vault Enterprise native-agent-identity adoption landed:
#   9.  Vault reports Enterprise edition (native Agent Registry is Enterprise-only)
#   10. database/ + aws/ secrets engines mounted (license-module gate — pki-only
#       would refuse these; their presence proves the platform-standard license)
#   11. agent-registry responds — the uc1-agent registration reads back
#       (agent-registry/registration/display-name/<name>, 09-DISCOVERY path)
#   12. oauth-resource-server profile 'ivia' responds (sys/config/oauth-resource-server/ivia)
#   13. jwt/ auth mount is ABSENT — the retired IVIA jwt auth backend is GONE
#       (locked decision (e) cutover proof; a still-mounted jwt/ FAILS LOUD)
#
# All use the same kubectl-exec + root-token pattern as Checks 3/4 above.
#===============================================================================
VAULT_EXEC="VAULT_TOKEN='${VAULT_ROOT_TOKEN}'"

#-------------------------------------------------------------------------------
# Check 9 — Vault Enterprise edition
#
# Two independent signals, either of which proves Enterprise:
#   - the version string carries the '+ent' build suffix, AND/OR
#   - sys/license/status responds (an Enterprise-only endpoint; OSS 404s /
#     returns "unsupported path").
#-------------------------------------------------------------------------------
vault_version=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault status -format=json 2>/dev/null | jq -r '.version // empty' 2>/dev/null || echo "")
lic_out=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read sys/license/status" 2>&1 || true)
if echo "${vault_version}" | grep -qi 'ent' \
    || { [ -n "${lic_out}" ] && ! echo "${lic_out}" | grep -qiE 'unsupported path|not supported|no handler'; }; then
    print_pass "Vault Enterprise edition (version=${vault_version:-unknown}; sys/license/status responds)"
else
    print_fail "Vault Enterprise edition" \
        "Vault does NOT report Enterprise (version='${vault_version}', license/status='${lic_out:0:120}'). The native Agent Registry + OAuth resource server are Enterprise-only — the vault_server image must be hashicorp/vault-enterprise:2.0.3-ent with a platform-standard license. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault status"
fi

#-------------------------------------------------------------------------------
# Check 10 — database/ + aws/ secrets engines mounted (license-module gate)
#-------------------------------------------------------------------------------
mounts_json=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault secrets list -format=json" 2>/dev/null || echo "{}")
missing_engines=""
for _eng in database aws; do
    if ! echo "${mounts_json}" | jq -e --arg m "${_eng}/" 'has($m)' >/dev/null 2>&1; then
        missing_engines="${missing_engines} ${_eng}/"
    fi
done
if [ -z "${missing_engines}" ]; then
    print_pass "Secrets engines mounted: database/ + aws/ (platform-standard license present; pki-only absent)"
else
    print_fail "Secrets engines database/ + aws/" \
        "Missing secrets engine(s):${missing_engines}. A pki-only Vault Enterprise license refuses these mounts — replace with a platform-standard .hclic and re-run deploy-workshop.sh --tier 2. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault secrets list"
fi

#-------------------------------------------------------------------------------
# Check 11 — agent-registry responds (Agent Registry / agentic-iam present)
#
# Read back the uc1-agent registration the vault_config apply reconciled. The
# display-name lookup path is the 09-DISCOVERY-confirmed contract. A successful
# read proves the agent-registry surface is live (agentic-iam is bundled in the
# platform-standard license).
#-------------------------------------------------------------------------------
reg_out=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read -format=json agent-registry/registration/display-name/uc1-agent" 2>/dev/null || echo "")
reg_name=$(echo "${reg_out}" | jq -r '.data.display_name // empty' 2>/dev/null || echo "")
if [ "${reg_name}" = "uc1-agent" ]; then
    print_pass "Agent Registry responds — registration 'uc1-agent' resolvable by display-name (agentic-iam present)"
else
    print_fail "Agent Registry (agent-registry/registration/display-name/uc1-agent)" \
        "The uc1-agent registration did not read back (agentic-iam / platform-standard may be absent, or vault_config did not reconcile). Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read agent-registry/registration/display-name/uc1-agent"
fi

#-------------------------------------------------------------------------------
# Check 12 — oauth-resource-server profile 'ivia' responds
#-------------------------------------------------------------------------------
oauth_out=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read sys/config/oauth-resource-server/ivia" 2>&1 || true)
if [ -n "${oauth_out}" ] && ! echo "${oauth_out}" | grep -qiE 'no value found|unsupported path|not found|error reading'; then
    print_pass "OAuth resource server profile 'ivia' responds (feature active + profile applied)"
else
    print_fail "OAuth resource server profile 'ivia'" \
        "sys/config/oauth-resource-server/ivia did not return a profile. Confirm the oauth-resource-server activation flag is set and vault_config applied the profile. Got: ${oauth_out:0:160}. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read sys/config/oauth-resource-server/ivia"
fi

#-------------------------------------------------------------------------------
# Check 13 — jwt/ auth mount is ABSENT (locked decision (e) cutover proof)
#
# The retired IVIA jwt auth backend (and its uc2-jwt / uc3-jwt roles) MUST be
# gone: UC2/UC3 now present the OAuth JWT directly via X-Vault-Token against the
# oauth-resource-server profile. A lingering jwt/ mount means the cutover is
# incomplete and a dead auth path survives — FAIL LOUD.
#-------------------------------------------------------------------------------
auth_list_json=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault auth list -format=json" 2>/dev/null || echo "{}")
if echo "${auth_list_json}" | jq -e 'has("jwt/")' >/dev/null 2>&1; then
    print_fail "jwt/ auth mount ABSENT (decision (e) cutover)" \
        "The retired IVIA jwt/ auth backend is STILL mounted — the native cutover (locked decision (e)) is incomplete. UC2/UC3 must present the OAuth JWT via X-Vault-Token, not vault write auth/jwt/login. Disable it: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault auth disable jwt. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault auth list"
else
    print_pass "jwt/ auth mount is ABSENT — retired IVIA jwt backend removed (decision (e) cutover proof)"
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
