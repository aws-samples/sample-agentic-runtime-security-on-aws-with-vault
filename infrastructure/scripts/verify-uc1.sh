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
#   7b. UC1 Agent Registry registration resolvable by display-name (ceiling INERT)
#   8. Vault audit device enabled (>= 1 audit device)
#   9. Agent /query end-to-end: KB retrieve + Nova Pro answer returned
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

Checks (9 total):
  1. UC1 agent pod Running (app=uc1-agent in uc1 namespace)
  2. UC1 ServiceAccount uc1-retriever-sa exists
  3. Vault role uc1 bound to uc1-retriever-sa
  4. JIT DB creds issuance (database/creds/uc1-readonly)
  5. JIT STS creds issuance (aws/sts/bedrock-reader)
  6. Agent /health endpoint returns "healthy"
  7. ENFC-01: uc1-readonly policy does not grant UC3 database path access
  7b. UC1 Agent Registry registration resolvable by display-name (ceiling INERT)
  8. Vault audit device enabled
  9. Agent /query end-to-end (KB retrieve + Nova Pro answer)

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

VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}"
if [ -z "$VAULT_ROOT_TOKEN" ] && [ -f "$HOME/vault-init.json" ]; then
    VAULT_ROOT_TOKEN=$(jq -r '.root_token // empty' "$HOME/vault-init.json" 2>/dev/null || true)
fi
VAULT_EXEC="VAULT_TOKEN='${VAULT_ROOT_TOKEN}'"

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
    sh -c "${VAULT_EXEC} vault read auth/kubernetes/role/uc1 -format=json" 2>/dev/null \
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
    sh -c "${VAULT_EXEC} vault read database/creds/uc1-readonly -format=json" 2>/dev/null \
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
    sh -c "${VAULT_EXEC} vault read aws/sts/bedrock-reader -format=json" 2>/dev/null \
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
    python3 -c "import urllib.request,json; r=urllib.request.urlopen('http://localhost:8080/health'); print(json.loads(r.read())['status'])" \
    2>/dev/null || echo "")
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
    sh -c "${VAULT_EXEC} vault policy read uc1-readonly" 2>/dev/null || echo "")
if echo "${uc1_policy}" | grep -q 'uc3-refund-writer'; then
    print_fail "ENFC-01: UC3 cred rejection" \
        "ENFC-01 FAIL: uc1-readonly policy incorrectly grants UC3 database path access (uc3-refund-writer found in policy). Reapply vault_config component to enforce policy isolation."
else
    print_pass "ENFC-01: uc1-readonly policy does not grant UC3 (uc3-refund-writer) path access"
fi

#-------------------------------------------------------------------------------
# Check 7b — UC1 Agent Registry registration resolvable by display-name
#
# Phase 9 native model (UC1_AUTH=kubernetes): UC1 keeps k8s auth AND gains an
# Agent-Registry registration for REGISTRY IDENTITY. Assert the registration
# reads back by display-name `uc1-agent`.
#
# IMPORTANT (09-DISCOVERY UC1_CEILING=inert): UC1's registry ceiling does NOT
# enforce — with no act.sub, the agent's own ceiling never self-applies. UC1's
# enforcement floor is the k8s `uc1-readonly` policy (asserted by Checks 3/4/7
# above). We deliberately do NOT assert a ceiling ENFORCES for UC1 here.
#-------------------------------------------------------------------------------
uc1_reg_name=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read -format=json agent-registry/registration/display-name/uc1-agent" 2>/dev/null \
    | jq -r '.data.display_name // empty' 2>/dev/null || echo "")
if [ "${uc1_reg_name}" = "uc1-agent" ]; then
    print_pass "UC1 Agent Registry: registration 'uc1-agent' resolvable by display-name (registry identity; ceiling INERT — k8s uc1-readonly is the floor)"
else
    print_fail "UC1 Agent Registry registration" \
        "agent-registry/registration/display-name/uc1-agent did not read back (got '${uc1_reg_name}') — reapply vault_config (vault_agent_registration.uc1_agent). Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read agent-registry/registration/display-name/uc1-agent"
fi

#-------------------------------------------------------------------------------
# Check 8 — Vault audit device enabled (>= 1 device)
#-------------------------------------------------------------------------------
audit_count=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault audit list -format=json" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [ "${audit_count:-0}" -ge 1 ]; then
    print_pass "Vault audit device: enabled (${audit_count} device(s))"
else
    print_fail "Vault audit device" \
        "Vault audit device not enabled — reapply vault_config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault audit list"
fi

#-------------------------------------------------------------------------------
# Check 9 — Agent /query end-to-end (KB retrieve + JIT DB + Nova Pro answer)
#
# POSTs a real natural-language question to the agent. This is the ONLY check
# that exercises the full data path end-to-end: Vault STS -> bedrock:Retrieve on
# the Knowledge Base -> Amazon Nova Pro inference (plus the db tool when the model
# selects it). A non-empty "answer" with no error means the path works.
#-------------------------------------------------------------------------------
query_result=$(kubectl exec -n "${UC1_NAMESPACE}" deploy/uc1-agent -- \
    python3 -c '
import urllib.request, urllib.error, json, re
body = json.dumps({"query": "Using the knowledge base, summarize the employee PTO policy including accrual by tenure."}).encode()
req = urllib.request.Request("http://localhost:8080/query", data=body,
                            headers={"Content-Type": "application/json"})
# Phrases the model emits when the KB retrieve returned nothing. A non-empty
# answer that is really one of these is NOT a working retrieval — it is the
# empty-index cop-out that previously let this check pass falsely.
FAIL_RE = re.compile(r"(unable to find|could ?n.?t find|not (?:available|indexed|find)|no (?:information|results|relevant)|reach(?:ing)? out to .*HR|consult .*HR)", re.I)
try:
    r = urllib.request.urlopen(req, timeout=120)
    ans = (json.loads(r.read()).get("answer") or "").strip()
    if not ans:
        print("EMPTY_ANSWER")
    elif FAIL_RE.search(ans):
        print("NO_KB_CONTENT")
    else:
        print("OK")
except urllib.error.HTTPError as e:
    print("HTTP_%d:%s" % (e.code, e.read().decode("utf-8", "replace")[:300]))
except Exception as e:
    print("ERR:%s" % str(e)[:300])
' 2>/dev/null || echo "EXEC_FAIL")
if [ "${query_result}" = "OK" ]; then
    print_pass "Agent /query end-to-end: KB retrieve + Nova Pro answer returned"
elif [ "${query_result}" = "NO_KB_CONTENT" ]; then
    print_fail "Agent /query end-to-end (KB empty)" \
        "Agent answered but retrieved NOTHING from the Knowledge Base (model said it could not find the policy). The corpus is in S3 but the vector index is empty — run: ./sync-bedrock-kb.sh"
else
    print_fail "Agent /query end-to-end" \
        "POST /query returned no usable answer (result: ${query_result}). Needs bedrock:Retrieve on the KB, the DB_*/REGION env vars in uc1-config, KB ingestion (./sync-bedrock-kb.sh), and Nova Pro access. Check: kubectl logs -n ${UC1_NAMESPACE} deploy/uc1-agent --tail=50"
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
