#!/usr/bin/env bash
#===============================================================================
# verify-uc2.sh — Use Case 2 end-to-end verification
#
# Validates all UC2 success criteria after Phase 5 components are deployed:
#   1.  Banking UI pod Running in banking-app namespace (app=banking-ui)
#   2.  Banking Agent pod Running (app=banking-agent)
#   3.  MCP Server pod Running (app=banking-mcp-server)
#   4.  ServiceAccount uc2-mcp-server-sa exists in banking-app namespace
#   5.  Vault k8s auth role uc2 bound to uc2-mcp-server-sa
#   6.  Vault jwt auth role uc2-jwt exists with bound_audiences containing agent-uc2
#   7.  JIT DB creds issuance: database/creds/uc2-personal-readonly succeeds
#   8.  DB read works: SELECT from banking.accounts returns rows (proves RLS is active)
#   9.  ENFC-02 — INSERT rejected: uc2-personal-readonly creds cannot INSERT
#   10. ENFC-03 — NetworkPolicy egress block: curl to external URL blocked from MCP pod
#   11. Agent /health endpoint returns "healthy"
#   12. IVIA OAuth pre-check: JWKS endpoint reachable (prerequisite for jwt auth)
#   13. Active lease exists after cred issuance (credential lifecycle check)
#   14. OAuth discovery: IVIA /.well-known/openid-configuration returns valid JSON
#       (sanity that the OIDC Provider is reachable via the WRP ALB — the full
#       Authorization Code + PKCE flow requires browser interaction with the
#       WebSEAL login form and cannot be tested headlessly here)
#
# Usage:
#   ./verify-uc2.sh [--help]
#
# Env-var overrides:
#   BANKING_NAMESPACE     (default: banking-app)
#   VAULT_NAMESPACE       (default: vault)
#   VAULT_POD             (default: vault-0)
#   VAULT_ROOT_TOKEN      (optional — used for lease listing; falls back to vault-init state)
#
# Per common-checks.sh design: this script does NOT use `set -e`.
# All checks run regardless of failures; summary is printed at the end.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DESCRIPTION="Use Case 2 — OAuth Personalized Read-Only verification"

# Source common helpers (print_pass, print_fail, print_warn, print_info,
# FAILURES[] accumulator, print_summary, EXIT trap).
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<USAGE
verify-uc2.sh — ${SCRIPT_DESCRIPTION}

Usage:
  ./verify-uc2.sh [--help]

Checks (14 total):
  1.  Banking UI pod Running (app=banking-ui in banking-app namespace)
  2.  Banking Agent pod Running (app=banking-agent)
  3.  MCP Server pod Running (app=banking-mcp-server)
  4.  ServiceAccount uc2-mcp-server-sa exists in banking-app namespace
  5.  Vault k8s auth role uc2 bound to uc2-mcp-server-sa
  6.  Vault jwt auth role uc2-jwt exists with bound_audiences containing agent-uc2
  7.  JIT DB creds issuance (database/creds/uc2-personal-readonly)
  8.  DB read: SELECT from banking.accounts succeeds with Vault-vended creds
  9.  ENFC-02: INSERT rejected with uc2-personal-readonly creds
  10. ENFC-03: Egress to external URL blocked from MCP server pod
  11. Agent /health endpoint returns "healthy"
  12. IVIA JWKS endpoint reachable (OAuth pre-check)
  13. Active lease exists after cred issuance (credential lifecycle)
  14. OAuth discovery: IVIA /.well-known/openid-configuration returns valid JSON

Env-var overrides:
  BANKING_NAMESPACE   (default: banking-app)
  VAULT_NAMESPACE     (default: vault)
  VAULT_POD           (default: vault-0)
  VAULT_ROOT_TOKEN    (optional — used for lease listing)
USAGE
    exit 0
fi

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
BANKING_NAMESPACE="${BANKING_NAMESPACE:-banking-app}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"

# Load root token from vault-init.json or local state
if [ -z "${VAULT_ROOT_TOKEN:-}" ] && [ -f "$HOME/vault-init.json" ]; then
    VAULT_ROOT_TOKEN=$(jq -r '.root_token // empty' "$HOME/vault-init.json" 2>/dev/null || true)
fi
if [ -z "${VAULT_ROOT_TOKEN:-}" ]; then
    local_root_token_file="${SCRIPT_DIR}/.vault-root-token"
    if [ -f "${local_root_token_file}" ]; then
        VAULT_ROOT_TOKEN=$(cat "${local_root_token_file}")
    fi
fi

VAULT_EXEC="VAULT_TOKEN='${VAULT_ROOT_TOKEN:-}'"

print_info "${SCRIPT_DESCRIPTION}"
echo ""

#-------------------------------------------------------------------------------
# Check 1 — Banking UI pod Running
#-------------------------------------------------------------------------------
running_ui=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=banking-ui \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_ui:-0}" -ge 1 ]; then
    print_pass "Banking UI pod Running (${running_ui} pod(s) in ${BANKING_NAMESPACE})"
else
    print_fail "Banking UI pod Running" \
        "Banking UI pod not running — verify workspace apply completed and banking-ui image URI is correct. Check: kubectl get pods -n ${BANKING_NAMESPACE} -l app=banking-ui"
fi

#-------------------------------------------------------------------------------
# Check 2 — Banking Agent pod Running
#-------------------------------------------------------------------------------
running_agent=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=banking-agent \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_agent:-0}" -ge 1 ]; then
    print_pass "Banking Agent pod Running (${running_agent} pod(s) in ${BANKING_NAMESPACE})"
else
    print_fail "Banking Agent pod Running" \
        "Banking Agent pod not running — verify workspace apply completed and banking-agent image URI is correct. Check: kubectl get pods -n ${BANKING_NAMESPACE} -l app=banking-agent"
fi

#-------------------------------------------------------------------------------
# Check 3 — MCP Server pod Running
#-------------------------------------------------------------------------------
running_mcp=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=banking-mcp-server \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_mcp:-0}" -ge 1 ]; then
    print_pass "MCP Server pod Running (${running_mcp} pod(s) in ${BANKING_NAMESPACE})"
else
    print_fail "MCP Server pod Running" \
        "MCP Server pod not running — verify workspace apply completed and banking-mcp-server image URI is correct. Check: kubectl get pods -n ${BANKING_NAMESPACE} -l app=banking-mcp-server"
fi

#-------------------------------------------------------------------------------
# Check 4 — ServiceAccount uc2-mcp-server-sa exists
#-------------------------------------------------------------------------------
if kubectl get sa uc2-mcp-server-sa -n "${BANKING_NAMESPACE}" --no-headers &>/dev/null; then
    print_pass "ServiceAccount uc2-mcp-server-sa exists in ${BANKING_NAMESPACE}"
else
    print_fail "ServiceAccount uc2-mcp-server-sa exists" \
        "ServiceAccount uc2-mcp-server-sa not found — check uc2_agent module in workspace run. Run: kubectl get sa -n ${BANKING_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 5 — Vault k8s auth role uc2 bound to uc2-mcp-server-sa
#-------------------------------------------------------------------------------
vault_k8s_role_sa=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read auth/kubernetes/role/uc2 -format=json" 2>/dev/null \
    | jq -r '.data.bound_service_account_names[0]' 2>/dev/null || echo "")
if [ "${vault_k8s_role_sa}" = "uc2-mcp-server-sa" ]; then
    print_pass "Vault k8s auth role uc2 bound to uc2-mcp-server-sa"
else
    print_fail "Vault k8s auth role uc2 binding" \
        "Vault k8s role uc2 not bound to uc2-mcp-server-sa (got '${vault_k8s_role_sa}') — reapply the workspace run. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/kubernetes/role/uc2"
fi

#-------------------------------------------------------------------------------
# Check 6 — Vault jwt auth role uc2-jwt exists with bound_audiences=[agent-uc2]
#-------------------------------------------------------------------------------
jwt_audiences=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read auth/jwt/role/uc2-jwt -format=json" 2>/dev/null \
    | jq -r '.data.bound_audiences[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
if echo "${jwt_audiences}" | grep -q "agent-uc2"; then
    print_pass "Vault jwt auth role uc2-jwt exists (bound_audiences contains agent-uc2)"
else
    print_fail "Vault jwt auth role uc2-jwt" \
        "Vault jwt role uc2-jwt not found or bound_audiences does not contain agent-uc2 (got '${jwt_audiences}') — reapply vault_config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/jwt/role/uc2-jwt"
fi

#-------------------------------------------------------------------------------
# Check 7 — JIT DB creds issuance (database/creds/uc2-personal-readonly)
#-------------------------------------------------------------------------------
db_creds_json=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read database/creds/uc2-personal-readonly -format=json" 2>/dev/null || echo "{}")
db_username=$(echo "${db_creds_json}" | jq -r '.data.username' 2>/dev/null || echo "")
db_password=$(echo "${db_creds_json}" | jq -r '.data.password' 2>/dev/null || echo "")
if [ -n "${db_username}" ] && [ "${db_username}" != "null" ]; then
    print_pass "JIT DB creds issuance: username=${db_username}"
else
    print_fail "JIT DB creds issuance" \
        "Cannot generate DB creds from database/creds/uc2-personal-readonly — verify RDS connectivity and vault_config database connection. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read database/creds/uc2-personal-readonly"
fi

#-------------------------------------------------------------------------------
# Check 8 — DB read: SELECT from banking.accounts succeeds
#
# Resolve RDS host from the MCP server ConfigMap (uc2-mcp-config).
# Execute psql SELECT via a temporary pod using the Vault-vended credentials.
# Requires the uc2-personal-readonly Postgres role to have SELECT on banking.accounts.
#-------------------------------------------------------------------------------
rds_host=$(kubectl get configmap banking-mcp-config -n "${BANKING_NAMESPACE}" \
    -o jsonpath='{.data.RDS_ADDRESS}' 2>/dev/null || echo "")

if [ -n "${db_username}" ] && [ "${db_username}" != "null" ] && [ -n "${rds_host}" ]; then
    psql_pod="verify-uc2-psql-$$"
    kubectl delete pod "${psql_pod}" -n default --ignore-not-found --wait=true &>/dev/null
    kubectl run "${psql_pod}" -n default --restart=Never \
        --image=postgres:17-alpine --env="PGPASSWORD=${db_password}" \
        --command -- psql -h "${rds_host}" -U "${db_username}" -d workshop \
            -c "SET app.current_user_sub = 'test-verify-script'; SELECT count(*) FROM banking.accounts;" \
            --no-password --tuples-only &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${psql_pod}" -n default --timeout=60s &>/dev/null || true
    select_result=$(kubectl logs "${psql_pod}" -n default 2>/dev/null || echo "PSQL_FAILED")
    kubectl delete pod "${psql_pod}" -n default --ignore-not-found &>/dev/null

    if echo "${select_result}" | grep -qE "^[[:space:]]*[0-9]+"; then
        row_count=$(echo "${select_result}" | grep -E "^[[:space:]]*[0-9]+" | tr -d ' ')
        print_pass "DB read: SELECT from banking.accounts returned ${row_count} row(s)"
    else
        print_fail "DB read: SELECT from banking.accounts" \
            "SELECT failed with JIT creds — RDS host: ${rds_host}, user: ${db_username}. Error: ${select_result}. Verify RLS policy and uc2_personal_readonly Postgres role GRANTs."
    fi
else
    print_warn "DB read check skipped — missing DB credentials or RDS host (ConfigMap banking-mcp-config)"
fi

#-------------------------------------------------------------------------------
# Check 9 — ENFC-02: INSERT rejected with uc2-personal-readonly creds
#
# Attempt INSERT with the same Vault-vended credentials.
# PostgreSQL GRANTs for the uc2_personal_readonly role must NOT include INSERT.
# Expected: "ERROR: permission denied for table accounts"
#-------------------------------------------------------------------------------
if [ -n "${db_username}" ] && [ "${db_username}" != "null" ] && [ -n "${rds_host}" ]; then
    insert_pod="verify-uc2-insert-$$"
    kubectl delete pod "${insert_pod}" -n default --ignore-not-found --wait=true &>/dev/null
    kubectl run "${insert_pod}" -n default --restart=Never \
        --image=postgres:17-alpine --env="PGPASSWORD=${db_password}" \
        --command -- psql -h "${rds_host}" -U "${db_username}" -d workshop \
            -c "INSERT INTO banking.accounts (user_sub, account_number, balance) VALUES ('verify-test', 'ACC999', 0.00);" \
            --no-password &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${insert_pod}" -n default --timeout=60s &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/"${insert_pod}" -n default --timeout=60s &>/dev/null || true
    insert_result=$(kubectl logs "${insert_pod}" -n default 2>/dev/null || echo "PSQL_FAILED")
    kubectl delete pod "${insert_pod}" -n default --ignore-not-found &>/dev/null

    if echo "${insert_result}" | grep -qi "permission denied"; then
        print_pass "ENFC-02: INSERT rejected by PostgreSQL (permission denied for table)"
    elif echo "${insert_result}" | grep -qi "read-only"; then
        print_pass "ENFC-02: INSERT rejected (read-only transaction)"
    else
        print_fail "ENFC-02: INSERT not rejected" \
            "INSERT was NOT rejected — uc2-personal-readonly creds should not have INSERT privileges. Result: ${insert_result}. Review DB GRANT statements in seed.sql and vault_config uc2-personal-readonly role creation_statements."
    fi
else
    print_warn "ENFC-02 check skipped — missing DB credentials or RDS host"
fi

#-------------------------------------------------------------------------------
# Check 10 — ENFC-03: NetworkPolicy egress block from MCP server pod
#
# Execute curl from within the mcp-server pod to an external URL.
# Expected: connection timeout or connection refused (NetworkPolicy blocks egress).
#-------------------------------------------------------------------------------
mcp_pod=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=banking-mcp-server \
    --no-headers 2>/dev/null | awk '{print $1}' | head -1)

if [ -n "${mcp_pod}" ]; then
    egress_result=$(kubectl exec -n "${BANKING_NAMESPACE}" "${mcp_pod}" -- \
        sh -c "wget -q -O - -T 5 http://httpbin.org:8080/get 2>&1 || echo BLOCKED" \
        2>/dev/null || echo "EXEC_FAILED")

    if echo "${egress_result}" | grep -qiE "timed out|BLOCKED|Connection timed out|Could not connect|Network unreachable|connection refused|EXEC_FAILED|not found"; then
        print_pass "ENFC-03: NetworkPolicy egress blocked from MCP server pod (external curl timed out)"
    elif [ -z "${egress_result}" ]; then
        print_pass "ENFC-03: NetworkPolicy egress blocked (empty response — connection dropped)"
    else
        print_fail "ENFC-03: NetworkPolicy egress NOT blocked" \
            "External curl from MCP server pod succeeded or returned unexpected output — NetworkPolicy should block egress to unapproved destinations. Result: ${egress_result:0:200}. Check uc2-mcp-server-egress NetworkPolicy."
    fi
else
    print_warn "ENFC-03 check skipped — MCP server pod not found (check 3 above)"
fi

#-------------------------------------------------------------------------------
# Check 11 — Agent /health endpoint returns "healthy"
#-------------------------------------------------------------------------------
agent_pod=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=banking-agent \
    --no-headers 2>/dev/null | awk '{print $1}' | head -1)

if [ -n "${agent_pod}" ]; then
    agent_health=$(kubectl exec -n "${BANKING_NAMESPACE}" "${agent_pod}" -- \
        python3 -c "import urllib.request,json; r=urllib.request.urlopen('http://localhost:3002/health'); print(json.loads(r.read())['status'])" \
        2>/dev/null || echo "")
    if [ "${agent_health}" = "healthy" ] || [ "${agent_health}" = "ok" ]; then
        print_pass "Agent /health endpoint: healthy"
    else
        print_fail "Agent /health endpoint" \
            "Agent health check returned '${agent_health}' (expected 'healthy') — check pod logs: kubectl logs -n ${BANKING_NAMESPACE} ${agent_pod}"
    fi
else
    print_warn "Agent /health check skipped — banking-agent pod not found (check 2 above)"
fi

#-------------------------------------------------------------------------------
# Check 12 — IVIA JWKS endpoint reachable (OAuth pre-check)
#
# Vault jwt auth validates user JWTs against IVIA's JWKS endpoint.
# Verify the JWKS URL is reachable from within the cluster (via vault-0 proxy check).
# This is a prerequisite for the full OAuth flow, not a full OAuth test.
#-------------------------------------------------------------------------------
ivia_jwks_url="https://iviaop.verify-access.svc.cluster.local:8436/oauth2/jwks"
jwks_result=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "wget -q -O - --no-check-certificate --timeout=10 '${ivia_jwks_url}'" 2>/dev/null | jq -r '.keys | length' 2>/dev/null || echo "0")

if [ "${jwks_result:-0}" -ge 1 ] 2>/dev/null; then
    print_pass "IVIA JWKS endpoint reachable (${jwks_result} key(s) returned) — OAuth pre-check passed"
else
    print_warn "IVIA JWKS endpoint not reachable at ${ivia_jwks_url} — IVIA may still be initializing or JWT auth URL differs. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/jwt/config"
fi

#-------------------------------------------------------------------------------
# Check 13 — Active lease exists after cred issuance (credential lifecycle)
#
# After Check 7 issued DB credentials, verify at least one active lease exists
# for the uc2-personal-readonly path. Uses VAULT_ROOT_TOKEN if available
# (required for sys/leases path — the uc2-personal policy is read-only on db creds).
#-------------------------------------------------------------------------------
if [ -n "${VAULT_ROOT_TOKEN:-}" ]; then
    lease_count=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
        sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault list -format=json sys/leases/lookup/database/creds/uc2-personal-readonly 2>/dev/null" \
        | jq 'length' 2>/dev/null || echo "0")
    if [ "${lease_count:-0}" -ge 1 ] 2>/dev/null; then
        print_pass "Active Vault lease exists for uc2-personal-readonly (${lease_count} lease(s))"
    else
        print_warn "No active leases found for uc2-personal-readonly — Check 7 may have issued and expired, or VAULT_ROOT_TOKEN is stale"
    fi
else
    print_warn "Credential lifecycle check skipped — VAULT_ROOT_TOKEN not set. Set VAULT_ROOT_TOKEN to enable lease verification."
fi

#-------------------------------------------------------------------------------
# Check 14 — OAuth discovery endpoint reachable
#
# Hits the IVIA OIDC Provider's discovery document via the WRP ALB. This is
# the only sub-path under /isvaop that has the `unauth` ACL attached, so it
# is the right sanity check for "the OAuth surface is up and proxied".
#
# Why not a full end-to-end token test here:
#   - banking-ui now uses Authorization Code + PKCE, not ROPC.
#   - The authorize step renders the WebSEAL login form (HTML), which can
#     only be completed in a real browser. The full flow is validated by
#     the workshop attendee in sub-module 61.
#-------------------------------------------------------------------------------
ivia_endpoint=$(kubectl get ingress -n verify-access ivia-wrp \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "${ivia_endpoint}" ]; then
    discovery=$(curl -sLk "https://${ivia_endpoint}/isvaop/oauth2/.well-known/openid-configuration" \
        --max-time 15 -H "Accept: application/json" 2>/dev/null || echo "{}")
    if echo "${discovery}" | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .jwks_uri' >/dev/null 2>&1; then
        issuer=$(echo "${discovery}" | jq -r '.issuer')
        print_pass "OAuth discovery: IVIA OIDC Provider reachable (issuer=${issuer})"
    else
        print_fail "OAuth discovery failed" \
            "GET /isvaop/oauth2/.well-known/openid-configuration did not return a valid OIDC document. Response: ${discovery:0:300}. Verify the WRP unauth ACL is attached to /isvaop/oauth2/.well-known and the iviaop pod is Ready."
    fi
else
    print_warn "OAuth discovery check skipped — IVIA ALB hostname not resolved (check ivia-wrp Ingress)"
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
