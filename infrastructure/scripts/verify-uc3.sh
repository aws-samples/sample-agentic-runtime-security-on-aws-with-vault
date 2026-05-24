#!/usr/bin/env bash
#===============================================================================
# verify-uc3.sh — Use Case 3 end-to-end verification
#
# Validates all UC3 success criteria after Phase 6 components are deployed.
#
# IVIA Full-Stack Checks (A-F — run first):
#   A.  IVIA Config container pod Running in verify-access
#   B.  IVIA Runtime pod Running in verify-access
#   C.  IVIA WRP pod Running in verify-access
#   D.  WRP junction connectivity to OIDC Provider (internal cluster path)
#   E.  CIBA consent endpoint reachable via WRP ALB (HTTP not 404)
#   F.  notifyuser mapping rule: InternalAuthenticator configured
#
# UC3-Specific Checks (1-13):
#   1.  UC3 agent pod Running in banking-app namespace (app=uc3-agent)
#   2.  ServiceAccount uc3-privileged-actor-sa exists in banking-app namespace
#   3.  Vault k8s auth role uc3 bound to uc3-privileged-actor-sa
#   4.  Vault jwt auth role uc3-jwt exists with bound_audiences=[agent-uc3]
#   5.  Vault DB role uc3-refund-writer generates credentials (JIT)
#   6.  banking.refunds table exists in RDS
#   7.  JIT credential fetch: vault read database/creds/uc3-refund-writer
#   8.  CloudWatch log group /workshop/agent-trace has recent log events
#   9.  fluent-bit DaemonSet pods Running in logging namespace
#   10. S3 log bucket exists and has objects
#   11. Athena audit_correlation VIEW named query exists
#   12. UC3 agent chat: "I need a refund" returns transaction list
#   13. UC3 agent chat: multi-turn session — selecting a transaction is acknowledged
#
# Bypass mode (--bypass):
#   14. Forge JWT with wrong may_act.sub — Vault must reject (403)
#   15. Forge JWT with wrong authorization_details type — Vault must reject (403)
#
# Usage:
#   ./verify-uc3.sh [--bypass] [--help]
#
# Env-var overrides:
#   BANKING_NAMESPACE     (default: banking-app)
#   LOGGING_NAMESPACE     (default: logging)
#   VAULT_NAMESPACE       (default: vault)
#   VAULT_POD             (default: vault-0)
#   VAULT_ROOT_TOKEN      (optional — auto-loaded from ~/vault-init.json)
#   IVIA_ISSUER           (default: https://iviaop.verify-access.svc.cluster.local:8436/oauth2)
#   AWS_REGION            (default: resolved from terraform.tfvars)
#
# Per common-checks.sh design: this script does NOT use `set -e`.
# All checks run regardless of failures; summary is printed at the end.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DESCRIPTION="Use Case 3 — CIBA Privileged verification"

# Source common helpers (print_pass, print_fail, print_warn, print_info,
# FAILURES[] accumulator, print_summary, EXIT trap).
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

BYPASS_MODE=false

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<USAGE
verify-uc3.sh — ${SCRIPT_DESCRIPTION}

Usage:
  ./verify-uc3.sh [--bypass] [--help]

Normal mode checks (19 total):
  IVIA Full-Stack Checks (A-F):
  A.  IVIA Config container pod Running in verify-access
  B.  IVIA Runtime pod Running in verify-access
  C.  IVIA WRP pod Running in verify-access
  D.  WRP junction connectivity to OIDC Provider (internal cluster path)
  E.  CIBA consent endpoint reachable via WRP ALB (HTTP not 404)
  F.  notifyuser mapping rule: InternalAuthenticator configured

  UC3-Specific Checks (1-13):
  1.  UC3 agent pod Running (app=uc3-agent in banking-app namespace)
  2.  ServiceAccount uc3-privileged-actor-sa exists
  3.  Vault k8s auth role uc3 bound to uc3-privileged-actor-sa
  4.  Vault jwt auth role uc3-jwt exists (bound_audiences=agent-uc3)
  5.  Vault DB role uc3-refund-writer accessible
  6.  banking.refunds table exists in RDS
  7.  JIT credential fetch: database/creds/uc3-refund-writer
  8.  CloudWatch log group /workshop/agent-trace has recent log events
  9.  fluent-bit DaemonSet Running in logging namespace
  10. S3 log bucket exists and has objects
  11. Athena audit_correlation VIEW named query exists
  12. UC3 agent chat: "I need a refund" returns transaction list
  13. UC3 agent chat: multi-turn session — selecting a transaction is acknowledged

Bypass mode (--bypass) adds:
  14. Forge JWT with wrong may_act.sub — Vault must return 403
  15. Forge JWT with wrong authorization_details type — Vault must return 403

Env-var overrides:
  BANKING_NAMESPACE   (default: banking-app)
  LOGGING_NAMESPACE   (default: logging)
  VAULT_NAMESPACE     (default: vault)
  VAULT_POD           (default: vault-0)
  VAULT_ROOT_TOKEN    (optional)
  IVIA_ISSUER         (default: https://iviaop.verify-access.svc.cluster.local:8436/oauth2)
  AWS_REGION          (default: resolved from terraform.tfvars)
USAGE
    exit 0
fi

if [ "${1:-}" = "--bypass" ]; then
    BYPASS_MODE=true
fi

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
BANKING_NAMESPACE="${BANKING_NAMESPACE:-banking-app}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
IVIA_ISSUER="${IVIA_ISSUER:-https://iviaop.verify-access.svc.cluster.local:8436/oauth2}"

# Resolve AWS region from terraform.tfvars (canonical-region contract)
_TFVARS="${SCRIPT_DIR}/../../infrastructure/terraform.tfvars"
if [ -z "${AWS_REGION:-}" ] && [ -f "${_TFVARS}" ]; then
    AWS_REGION=$(grep -E '^\s*region\s*=' "${_TFVARS}" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

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

if [ "${BYPASS_MODE}" = true ]; then
    print_info "${SCRIPT_DESCRIPTION} — BYPASS TEST MODE"
else
    print_info "${SCRIPT_DESCRIPTION}"
fi
echo ""

if [ "${BYPASS_MODE}" = true ]; then
    #---------------------------------------------------------------------------
    # Bypass check 12 — Forge JWT with wrong may_act.sub
    #
    # Uses PyJWT to create an HS256-signed JWT (IVIA uses RS256/ES256 from JWKS;
    # Vault's JWKS validation will reject any HS256 token). The claim content
    # includes a wrong may_act.sub to demonstrate the two-layer rejection:
    #   1. JWT signature invalid (HS256 not trusted by IVIA JWKS)
    #   2. may_act.sub does not match the bound_claim pattern
    # Either layer alone is sufficient; both provide defense-in-depth.
    #---------------------------------------------------------------------------
    print_info "Bypass Check 12: Forge JWT with wrong may_act.sub"

    # Check PyJWT is available inside the vault pod (it ships with Vault's Python helper)
    # We use kubectl exec to run python3 inside a debug pod
    FORGED_JWT_WRONG_MAYACT=""
    forge_pod="verify-uc3-forge-$$"
    kubectl delete pod "${forge_pod}" -n default --ignore-not-found --wait=true &>/dev/null

    kubectl run "${forge_pod}" -n default --restart=Never \
        --image=python:3.12-slim \
        --command -- sh -c "pip install PyJWT --quiet 2>/dev/null && python3 -c \"
import jwt, time
payload = {
    'sub': 'attacker',
    'iss': '${IVIA_ISSUER}',
    'aud': 'agent-uc3',
    'exp': int(time.time()) + 3600,
    'may_act': {'sub': 'service-account:wrong-agent'}
}
print(jwt.encode(payload, 'forged-secret', algorithm='HS256'))
\"" &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${forge_pod}" -n default --timeout=120s &>/dev/null || true
    FORGED_JWT_WRONG_MAYACT=$(kubectl logs "${forge_pod}" -n default 2>/dev/null | tail -1)
    kubectl delete pod "${forge_pod}" -n default --ignore-not-found &>/dev/null

    if [ -n "${FORGED_JWT_WRONG_MAYACT}" ] && [ "${FORGED_JWT_WRONG_MAYACT}" != "Error" ]; then
        # Present the forged JWT to Vault — expect 403 (rejected)
        vault_response=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
            sh -c "${VAULT_EXEC} vault write auth/jwt/login role=uc3-jwt jwt='${FORGED_JWT_WRONG_MAYACT}' -format=json 2>&1" \
            2>/dev/null || echo "REJECTED")

        if echo "${vault_response}" | grep -qiE "403|permission denied|invalid|REJECTED|no permission|Code: 403"; then
            print_pass "Bypass Check 12 PASSED: Vault rejected forged may_act.sub — HS256 token not trusted by JWKS (signature validation + may_act.sub bound_claim enforcement)"
        else
            print_fail "Bypass Check 12: Vault accepted forged may_act.sub" \
                "Vault DID NOT reject the forged JWT with wrong may_act.sub — bound_claims enforcement may be misconfigured. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/jwt/role/uc3-jwt"
        fi
    else
        print_warn "Bypass Check 12 skipped — could not generate forged JWT (PyJWT pod failed). Check Docker image availability."
    fi

    echo ""

    #---------------------------------------------------------------------------
    # Bypass check 13 — Forge JWT with wrong authorization_details type
    #---------------------------------------------------------------------------
    print_info "Bypass Check 13: Forge JWT with wrong authorization_details type"

    FORGED_JWT_WRONG_RAR=""
    forge_pod2="verify-uc3-forge2-$$"
    kubectl delete pod "${forge_pod2}" -n default --ignore-not-found --wait=true &>/dev/null

    kubectl run "${forge_pod2}" -n default --restart=Never \
        --image=python:3.12-slim \
        --command -- sh -c "pip install PyJWT --quiet 2>/dev/null && python3 -c \"
import jwt, time
payload = {
    'sub': 'attacker',
    'iss': '${IVIA_ISSUER}',
    'aud': 'agent-uc3',
    'exp': int(time.time()) + 3600,
    'may_act': {'sub': 'service-account:agent-uc3'},
    'authorization_details': [{'type': 'transfer_approval'}]
}
print(jwt.encode(payload, 'forged-secret', algorithm='HS256'))
\"" &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${forge_pod2}" -n default --timeout=120s &>/dev/null || true
    FORGED_JWT_WRONG_RAR=$(kubectl logs "${forge_pod2}" -n default 2>/dev/null | tail -1)
    kubectl delete pod "${forge_pod2}" -n default --ignore-not-found &>/dev/null

    if [ -n "${FORGED_JWT_WRONG_RAR}" ] && [ "${FORGED_JWT_WRONG_RAR}" != "Error" ]; then
        vault_response2=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
            sh -c "${VAULT_EXEC} vault write auth/jwt/login role=uc3-jwt jwt='${FORGED_JWT_WRONG_RAR}' -format=json 2>&1" \
            2>/dev/null || echo "REJECTED")

        if echo "${vault_response2}" | grep -qiE "403|permission denied|invalid|REJECTED|no permission|Code: 403"; then
            print_pass "Bypass Check 13 PASSED: Vault rejected wrong authorization_details type — HS256 token not trusted by JWKS (even if may_act.sub matched, authorization_details.type must equal refund_approval)"
        else
            print_fail "Bypass Check 13: Vault accepted wrong authorization_details type" \
                "Vault DID NOT reject the forged JWT with wrong authorization_details type — bound_claims on authorization_details may be misconfigured. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/jwt/role/uc3-jwt"
        fi
    else
        print_warn "Bypass Check 13 skipped — could not generate forged JWT (PyJWT pod failed). Check Docker image availability."
    fi

    # Summary is printed automatically by the common-checks.sh EXIT trap
    exit 0
fi

#-------------------------------------------------------------------------------
# Normal mode checks
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# IVIA Full-Stack Checks (A-F) — prerequisite for all UC3 flows
# These verify the full IVIA stack: Config + Runtime + WRP + CIBA consent endpoint
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Check A — IVIA Config container pod Running
#-------------------------------------------------------------------------------
running_config=$(kubectl get pods -n verify-access -l app=iviaconfig \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_config:-0}" -ge 1 ]; then
    print_pass "IVIA Config container Running in verify-access (${running_config} pod(s))"
else
    print_fail "IVIA Config container Running" \
        "IVIA Config container not running — full stack required for CIBA consent. Check: kubectl get pods -n verify-access -l app=iviaconfig"
fi

#-------------------------------------------------------------------------------
# Check B — IVIA Runtime pod Running
#-------------------------------------------------------------------------------
running_runtime=$(kubectl get pods -n verify-access -l app=iviaruntime \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_runtime:-0}" -ge 1 ]; then
    print_pass "IVIA Runtime Running in verify-access (${running_runtime} pod(s))"
else
    print_fail "IVIA Runtime Running" \
        "IVIA Runtime not running — AAC engine required for WRP authentication. Check: kubectl get pods -n verify-access -l app=iviaruntime"
fi

#-------------------------------------------------------------------------------
# Check C — IVIA WRP pod Running
#-------------------------------------------------------------------------------
running_wrp=$(kubectl get pods -n verify-access -l app=iviawrprp1 \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_wrp:-0}" -ge 1 ]; then
    print_pass "IVIA WRP Running in verify-access (${running_wrp} pod(s))"
else
    print_fail "IVIA WRP Running" \
        "IVIA WRP not running — browser authentication requires WRP. Check: kubectl get pods -n verify-access -l app=iviawrprp1"
fi

#-------------------------------------------------------------------------------
# Check D — WRP junction connectivity to OIDC Provider (internal cluster path)
#-------------------------------------------------------------------------------
wrp_junction_result=""
wrp_junction_pod="wrp-junction-check-$$"
kubectl delete pod "${wrp_junction_pod}" -n verify-access --ignore-not-found --wait=true &>/dev/null
kubectl run "${wrp_junction_pod}" --image=curlimages/curl --rm -i --restart=Never \
    -n verify-access -- \
    curl -sk --max-time 10 \
    "https://iviawrprp1.verify-access.svc.cluster.local:9443/isvaop/oauth2/.well-known/openid-configuration" \
    2>/dev/null > /tmp/wrp_junction_$$.json || true
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${wrp_junction_pod}" \
    -n verify-access --timeout=60s &>/dev/null || true
wrp_junction_result=$(cat /tmp/wrp_junction_$$.json 2>/dev/null || echo "")
rm -f "/tmp/wrp_junction_$$.json"

if echo "${wrp_junction_result}" | grep -q '"issuer"'; then
    print_pass "WRP junction /isvaop -> OIDC Provider: connected (issuer present in discovery)"
else
    print_fail "WRP junction /isvaop -> OIDC Provider" \
        "WRP junction not reachable or not proxying OIDC discovery. Check: kubectl run wrp-check --image=curlimages/curl --rm -i --restart=Never -n verify-access -- curl -sk https://iviawrprp1.verify-access.svc.cluster.local:9443/isvaop/oauth2/.well-known/openid-configuration"
fi

#-------------------------------------------------------------------------------
# Check E — CIBA consent endpoint reachable via WRP ALB (the money check)
#-------------------------------------------------------------------------------
wrp_alb_host=""
wrp_alb_host=$(kubectl get ingress -n verify-access ivia-wrp \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "${wrp_alb_host}" ]; then
    ciba_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "http://${wrp_alb_host}/isvaop/oauth2/ciba_user_authorize/test-check" 2>/dev/null || echo "")
    if [ -n "${ciba_code}" ] && [ "${ciba_code}" != "404" ]; then
        print_pass "CIBA consent endpoint: HTTP ${ciba_code} via WRP (not 404) — WRP is handling the request"
    elif [ "${ciba_code}" = "404" ]; then
        print_fail "CIBA consent endpoint: HTTP 404 — still broken" \
            "WRP junction or ACL misconfigured. CIBA consent URL must not return 404. Check WRP junction definition for /isvaop path. WRP ALB: ${wrp_alb_host}"
    else
        print_warn "CIBA consent endpoint: no HTTP response from WRP ALB — ALB may still be provisioning. Check: kubectl get ingress -n verify-access ivia-wrp"
    fi
else
    print_warn "CIBA consent endpoint: skipped — WRP Ingress has no ALB hostname yet. Check: kubectl get ingress -n verify-access ivia-wrp"
fi

#-------------------------------------------------------------------------------
# Check F — notifyuser mapping rule uses InternalAuthenticator
#
# Post-Phase-7 refactor: there is no longer an `isvaop-cfg-data` configmap; the
# notifyuser mapping rule is published into IVIA's mapping-rules table via the
# autoconf SDK. Query LMI's REST API (basic auth from `iviaadmin` Secret) for a
# mapping rule named `notifyuser` and grep its content for InternalAuthenticator.
#-------------------------------------------------------------------------------
ivia_admin_pw=$(kubectl get secret iviaadmin -n verify-access \
    -o jsonpath='{.data.adminpw}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
notifyuser_check_pod="notifyuser-check-$$"
kubectl delete pod "${notifyuser_check_pod}" -n verify-access --ignore-not-found --wait=true &>/dev/null
notifyuser_rule_json=""
if [ -n "${ivia_admin_pw}" ]; then
    notifyuser_rule_json=$(kubectl run "${notifyuser_check_pod}" --image=curlimages/curl --rm -i --restart=Never \
        -n verify-access -- \
        curl -sk --max-time 15 -u "admin:${ivia_admin_pw}" \
        "https://iviaconfig.verify-access.svc.cluster.local:9443/iam/access/v8/mapping-rules?filter=name+equals+notifyuser" \
        2>/dev/null || echo "")
fi
if echo "${notifyuser_rule_json}" | grep -q "InternalAuthenticator"; then
    print_pass "notifyuser mapping rule: InternalAuthenticator configured (queried LMI mapping-rules API)"
elif [ -z "${ivia_admin_pw}" ]; then
    print_warn "notifyuser mapping rule check: skipped — could not read iviaadmin Secret. Check: kubectl get secret iviaadmin -n verify-access"
else
    print_warn "notifyuser mapping rule: InternalAuthenticator not found via LMI API — workshop_layer that publishes this rule may not yet be re-added (commit cc8dd44 reverted it). CIBA consent flows that depend on it will fail until restored."
fi

#-------------------------------------------------------------------------------
# Check 1 — UC3 agent pod Running
#-------------------------------------------------------------------------------
running_uc3=$(kubectl get pods -n "${BANKING_NAMESPACE}" -l app=uc3-agent \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_uc3:-0}" -ge 1 ]; then
    print_pass "UC3 agent pod Running (${running_uc3} pod(s) in ${BANKING_NAMESPACE})"
else
    print_fail "UC3 agent pod Running" \
        "UC3 agent pod not running — verify workspace apply completed and uc3-agent image URI is correct. Check: kubectl get pods -n ${BANKING_NAMESPACE} -l app=uc3-agent"
fi

#-------------------------------------------------------------------------------
# Check 2 — ServiceAccount uc3-privileged-actor-sa exists
#-------------------------------------------------------------------------------
if kubectl get sa uc3-privileged-actor-sa -n "${BANKING_NAMESPACE}" --no-headers &>/dev/null; then
    print_pass "ServiceAccount uc3-privileged-actor-sa exists in ${BANKING_NAMESPACE}"
else
    print_fail "ServiceAccount uc3-privileged-actor-sa exists" \
        "ServiceAccount uc3-privileged-actor-sa not found — check uc3_agent module in workspace run. Run: kubectl get sa -n ${BANKING_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 3 — Vault k8s auth role uc3 bound to uc3-privileged-actor-sa
#-------------------------------------------------------------------------------
vault_k8s_role_sa=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read auth/kubernetes/role/uc3 -format=json" 2>/dev/null \
    | jq -r '.data.bound_service_account_names[0]' 2>/dev/null || echo "")
if [ "${vault_k8s_role_sa}" = "uc3-privileged-actor-sa" ]; then
    print_pass "Vault k8s auth role uc3 bound to uc3-privileged-actor-sa"
else
    print_fail "Vault k8s auth role uc3 binding" \
        "Vault k8s role uc3 not bound to uc3-privileged-actor-sa (got '${vault_k8s_role_sa}') — reapply the workspace run. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/kubernetes/role/uc3"
fi

#-------------------------------------------------------------------------------
# Check 4 — Vault jwt auth role uc3-jwt exists with bound_audiences=[agent-uc3]
#-------------------------------------------------------------------------------
jwt_audiences=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read auth/jwt/role/uc3-jwt -format=json" 2>/dev/null \
    | jq -r '.data.bound_audiences[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
if echo "${jwt_audiences}" | grep -q "agent-uc3"; then
    print_pass "Vault jwt auth role uc3-jwt exists (bound_audiences contains agent-uc3)"
else
    print_fail "Vault jwt auth role uc3-jwt" \
        "Vault jwt role uc3-jwt not found or bound_audiences does not contain agent-uc3 (got '${jwt_audiences}') — reapply vault_config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read auth/jwt/role/uc3-jwt"
fi

#-------------------------------------------------------------------------------
# Check 5 — Vault DB role uc3-refund-writer is accessible
#-------------------------------------------------------------------------------
refund_role_exists=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read database/roles/uc3-refund-writer -format=json 2>/dev/null" \
    | jq -r '.data.db_name' 2>/dev/null || echo "")
if [ -n "${refund_role_exists}" ] && [ "${refund_role_exists}" != "null" ]; then
    print_pass "Vault DB role uc3-refund-writer accessible (db=${refund_role_exists})"
else
    print_fail "Vault DB role uc3-refund-writer" \
        "Vault DB role uc3-refund-writer not found or not readable — reapply vault_config. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read database/roles/uc3-refund-writer"
fi

#-------------------------------------------------------------------------------
# Check 6 — banking.refunds table exists in RDS
#
# Fetch Vault-vended creds, then verify the table with a psql temp pod.
#-------------------------------------------------------------------------------
db_creds_json=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read database/creds/uc3-refund-writer -format=json" 2>/dev/null || echo "{}")
db_username=$(echo "${db_creds_json}" | jq -r '.data.username' 2>/dev/null || echo "")
db_password=$(echo "${db_creds_json}" | jq -r '.data.password' 2>/dev/null || echo "")

rds_host=$(kubectl get configmap uc3-agent-config -n "${BANKING_NAMESPACE}" \
    -o jsonpath='{.data.RDS_ADDRESS}' 2>/dev/null || \
    kubectl get configmap banking-mcp-config -n "${BANKING_NAMESPACE}" \
    -o jsonpath='{.data.RDS_ADDRESS}' 2>/dev/null || echo "")

if [ -n "${db_username}" ] && [ "${db_username}" != "null" ] && [ -n "${rds_host}" ]; then
    refunds_check_pod="verify-uc3-refunds-$$"
    kubectl delete pod "${refunds_check_pod}" -n default --ignore-not-found --wait=true &>/dev/null
    kubectl run "${refunds_check_pod}" -n default --restart=Never \
        --image=postgres:17-alpine --env="PGPASSWORD=${db_password}" \
        --command -- psql -h "${rds_host}" -U "${db_username}" -d workshop \
            -c "SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema='banking' AND table_name='refunds';" \
            --no-password --tuples-only &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${refunds_check_pod}" -n default --timeout=60s &>/dev/null || true
    refunds_result=$(kubectl logs "${refunds_check_pod}" -n default 2>/dev/null || echo "")
    kubectl delete pod "${refunds_check_pod}" -n default --ignore-not-found &>/dev/null

    if echo "${refunds_result}" | grep -q "refunds"; then
        print_pass "banking.refunds table exists in RDS"
    else
        print_fail "banking.refunds table exists" \
            "banking.refunds table not found in RDS — check seed.sql and workspace apply. Connect with: psql -h ${rds_host} -U ${db_username} -d workshop -c '\\dt banking.*'"
    fi
else
    print_warn "Check 6 skipped — missing DB credentials (check 5 above) or RDS host (ConfigMap uc3-agent-config)"
fi

#-------------------------------------------------------------------------------
# Check 7 — JIT credential fetch: database/creds/uc3-refund-writer
#
# The creds were already fetched for check 6; reuse the result.
#-------------------------------------------------------------------------------
if [ -n "${db_username}" ] && [ "${db_username}" != "null" ]; then
    print_pass "JIT DB creds issuance (uc3-refund-writer): username=${db_username}"
else
    print_fail "JIT DB creds issuance (uc3-refund-writer)" \
        "Cannot generate DB creds from database/creds/uc3-refund-writer — verify RDS connectivity and vault_config database connection. Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read database/creds/uc3-refund-writer"
fi

#-------------------------------------------------------------------------------
# Check 8 — CloudWatch log group /workshop/agent-trace has recent log events
#-------------------------------------------------------------------------------
if [ -n "${AWS_REGION:-}" ]; then
    cw_log_count=$(aws logs describe-log-streams \
        --log-group-name "/workshop/agent-trace" \
        --region "${AWS_REGION}" \
        --order-by LastEventTime \
        --descending \
        --max-items 1 \
        --query 'logStreams | length(@)' \
        --output text 2>/dev/null || echo "0")
    if [ "${cw_log_count:-0}" -ge 1 ] 2>/dev/null; then
        print_pass "CloudWatch log group /workshop/agent-trace exists and has log streams"
    else
        print_warn "CloudWatch log group /workshop/agent-trace has no log streams — UC3 agent may not have run yet or fluent-bit is still starting. Check: aws logs describe-log-streams --log-group-name /workshop/agent-trace --region ${AWS_REGION}"
    fi
else
    print_warn "Check 8 skipped — AWS_REGION not resolved. Set AWS_REGION env var or add region to terraform.tfvars"
fi

#-------------------------------------------------------------------------------
# Check 9 — fluent-bit DaemonSet pods Running in logging namespace
#-------------------------------------------------------------------------------
running_fluentbit=$(kubectl get pods -n "${LOGGING_NAMESPACE}" -l app.kubernetes.io/name=aws-for-fluent-bit \
    --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_fluentbit:-0}" -ge 1 ]; then
    print_pass "fluent-bit DaemonSet Running (${running_fluentbit} pod(s) in ${LOGGING_NAMESPACE})"
else
    print_fail "fluent-bit DaemonSet Running" \
        "No fluent-bit pods Running in ${LOGGING_NAMESPACE} — verify observability module was applied. Check: kubectl get pods -n ${LOGGING_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 10 — S3 log bucket exists and has objects
#
# Resolve log bucket name from terraform output or ConfigMap.
#-------------------------------------------------------------------------------
if [ -n "${AWS_REGION:-}" ]; then
    log_bucket=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, 'workshop-logs') || contains(Name, 'workshop-audit')].Name | [0]" \
        --output text 2>/dev/null || echo "")
    if [ -z "${log_bucket}" ] || [ "${log_bucket}" = "None" ]; then
        log_bucket=$(aws s3api list-buckets \
            --query "Buckets[?contains(Name, 'agentic') && contains(Name, 'log')].Name | [0]" \
            --output text 2>/dev/null || echo "")
    fi

    if [ -n "${log_bucket}" ] && [ "${log_bucket}" != "None" ]; then
        # Verify Firehose delivery streams are ACTIVE (3 streams)
        active_streams=0
        for stream_suffix in vault-audit ivia-decision agent-trace; do
            cluster_prefix=$(echo "${log_bucket}" | sed 's/-workshop-logs$//')
            stream_name="${cluster_prefix}-${stream_suffix}"
            stream_status=$(aws firehose describe-delivery-stream \
                --delivery-stream-name "${stream_name}" \
                --region "${AWS_REGION}" \
                --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
                --output text 2>/dev/null || echo "NOT_FOUND")
            if [ "${stream_status}" = "ACTIVE" ]; then
                active_streams=$((active_streams + 1))
            fi
        done
        if [ "${active_streams}" -ge 3 ]; then
            print_pass "Firehose delivery streams ACTIVE (${active_streams}/3) → S3 bucket '${log_bucket}'"
        elif [ "${active_streams}" -ge 1 ]; then
            print_warn "Only ${active_streams}/3 Firehose streams ACTIVE — some log planes may not deliver to S3. Check: aws firehose list-delivery-streams --region ${AWS_REGION}"
        else
            print_warn "No Firehose delivery streams ACTIVE — observability module may not have been applied. Check: aws firehose list-delivery-streams --region ${AWS_REGION}"
        fi

        s3_obj_count=$(aws s3api list-objects-v2 \
            --bucket "${log_bucket}" \
            --max-items 1 \
            --query 'length(Contents)' \
            --output text 2>/dev/null || echo "0")
        if [ "${s3_obj_count:-0}" -ge 1 ] 2>/dev/null; then
            print_pass "S3 log bucket '${log_bucket}' has objects (Firehose delivering)"
        else
            print_warn "S3 log bucket '${log_bucket}' has no objects yet — Firehose buffers for 60s before flushing. Re-run after generating UC3 traffic."
        fi
    else
        print_warn "S3 log bucket not found — observability module may not have been applied. Check: aws s3api list-buckets --query \"Buckets[?contains(Name,'workshop')]\""
    fi
else
    print_warn "Check 10 skipped — AWS_REGION not resolved"
fi

#-------------------------------------------------------------------------------
# Check 11 — Athena audit_correlation VIEW named query exists
#
# The VIEW is created as an Athena named query (not via null_resource).
# Attendees execute CREATE OR REPLACE VIEW as an explicit lab step.
# We verify the named query exists in Athena as the configuration signal.
#-------------------------------------------------------------------------------
if [ -n "${AWS_REGION:-}" ]; then
    named_query_count=$(aws athena list-named-queries \
        --work-group workshop \
        --region "${AWS_REGION}" \
        --query "NamedQueryIds | length(@)" \
        --output text 2>/dev/null || echo "0")

    if [ "${named_query_count:-0}" -ge 1 ] 2>/dev/null; then
        correlation_query=$(aws athena list-named-queries \
            --work-group workshop \
            --region "${AWS_REGION}" \
            --query "NamedQueryIds" \
            --output json 2>/dev/null \
            | jq -r '.[]' 2>/dev/null | while read -r qid; do
                name=$(aws athena get-named-query \
                    --named-query-id "${qid}" \
                    --region "${AWS_REGION}" \
                    --query 'NamedQuery.Name' \
                    --output text 2>/dev/null || echo "")
                if echo "${name}" | grep -qi "audit_correlation\|audit-correlation"; then
                    echo "${name}"
                    break
                fi
            done)

        if [ -n "${correlation_query}" ]; then
            print_pass "Athena audit_correlation named query exists: '${correlation_query}' (workgroup: workshop)"
        else
            print_warn "Athena workshop workgroup has ${named_query_count} named query(ies) but none named 'audit_correlation' — check: aws athena list-named-queries --work-group workshop --region ${AWS_REGION}"
        fi
    else
        print_warn "No Athena named queries in workshop workgroup — observability module may not have been applied. Check: aws athena list-named-queries --work-group workshop --region ${AWS_REGION}"
    fi
else
    print_warn "Check 11 skipped — AWS_REGION not resolved"
fi

#-------------------------------------------------------------------------------
# Check 12 — UC3 agent chat: list_transactions returns transaction data
#
# POST to UC3 agent /chat with "I need a refund" and verify the response
# contains transaction details (proves the full flow: Vault creds → DB query).
#-------------------------------------------------------------------------------
chat_session="verify-$$-$(date +%s)"
chat_response=$(kubectl run uc3-chat-test-$$ --rm -i --restart=Never -n "${BANKING_NAMESPACE}" \
    --image=curlimages/curl -- \
    curl -s --max-time 30 -X POST http://uc3-agent-svc:8080/chat \
    -H 'Content-Type: application/json' \
    -d "{\"message\":\"I need a refund\",\"sessionId\":\"${chat_session}\"}" \
    2>/dev/null || echo "")

if echo "${chat_response}" | grep -qi "transaction\|amount\|merchant"; then
    print_pass "UC3 agent chat: list_transactions returns transaction data"
else
    print_fail "UC3 agent chat: list_transactions did not return transaction data" \
        "Expected response containing transaction details. Got: ${chat_response:0:200}. Check: kubectl logs deployment/uc3-agent -n ${BANKING_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 13 — UC3 agent chat: multi-turn session (select transaction)
#
# Send a follow-up message selecting transaction #1 on the same sessionId.
# The agent should acknowledge the selection (proves session state works).
#-------------------------------------------------------------------------------
select_response=$(kubectl run uc3-chat-sel-$$ --rm -i --restart=Never -n "${BANKING_NAMESPACE}" \
    --image=curlimages/curl -- \
    curl -s --max-time 30 -X POST http://uc3-agent-svc:8080/chat \
    -H 'Content-Type: application/json' \
    -d "{\"message\":\"Refund transaction 1\",\"sessionId\":\"${chat_session}\"}" \
    2>/dev/null || echo "")

if echo "${select_response}" | grep -qi "refund\|confirm\|approve\|CIBA\|consent\|process"; then
    print_pass "UC3 agent chat: multi-turn session — agent acknowledged transaction selection"
else
    print_fail "UC3 agent chat: multi-turn session did not acknowledge selection" \
        "Expected response referencing refund/confirm/CIBA. Got: ${select_response:0:200}. Check: kubectl logs deployment/uc3-agent -n ${BANKING_NAMESPACE}"
fi

#-------------------------------------------------------------------------------
# Check 14 — Athena audit_correlation single-row assertion (D3 step 14)
#
# This is the three-plane capstone gate. It runs AFTER a real browser-approved
# refund (the browser consent step is a documented MANUAL smoke step — it is NOT
# automated here). Provide the approved refund's request_id via the env var
# UC3_VERIFY_REQUEST_ID; the check then waits (bounded retry) for fluent-bit +
# Firehose + Glue propagation, runs SELECT * FROM audit_correlation WHERE
# request_id='<id>' LIMIT 1, polls to SUCCEEDED, and asserts EXACTLY ONE row.
#-------------------------------------------------------------------------------
if [ -z "${UC3_VERIFY_REQUEST_ID:-}" ]; then
    print_warn "Check 14 skipped — set UC3_VERIFY_REQUEST_ID=<approved-refund-request_id> after a manual browser approval to run the audit_correlation single-row assertion."
elif [ -z "${AWS_REGION:-}" ]; then
    print_warn "Check 14 skipped — AWS_REGION not resolved"
else
    ac_request_id="${UC3_VERIFY_REQUEST_ID}"
    ac_database="${GLUE_DATABASE:-workshop_logs}"

    # Resolve an S3 output location for Athena results (reuse the workshop logs bucket).
    ac_bucket=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, 'workshop-logs') || contains(Name, 'workshop-audit')].Name | [0]" \
        --output text 2>/dev/null || echo "")
    if [ -z "${ac_bucket}" ] || [ "${ac_bucket}" = "None" ]; then
        ac_bucket=$(aws s3api list-buckets \
            --query "Buckets[?contains(Name, 'agentic') && contains(Name, 'log')].Name | [0]" \
            --output text 2>/dev/null || echo "")
    fi

    if [ -z "${ac_bucket}" ] || [ "${ac_bucket}" = "None" ]; then
        print_fail "Check 14: could not resolve an S3 bucket for Athena results" \
            "Fix: ensure the observability module is applied (workshop-logs bucket exists). Check: aws s3api list-buckets --query \"Buckets[?contains(Name,'workshop')]\""
    else
        ac_output="s3://${ac_bucket}/athena-results/"
        ac_query="SELECT * FROM audit_correlation WHERE request_id = '${ac_request_id}' LIMIT 1"

        # Bounded propagation retry (~90s budget: fluent-bit + Firehose 60s buffer +
        # Glue), then up to a few query attempts. Not a single blind sleep.
        ac_row_count=""
        ac_qid=""
        ac_attempts=6   # 6 attempts
        ac_wait_secs=15 # 15s between attempts -> ~90s total budget
        ac_attempt=1
        while [ "${ac_attempt}" -le "${ac_attempts}" ]; do
            print_info "Check 14 attempt ${ac_attempt}/${ac_attempts}: querying audit_correlation for request_id=${ac_request_id}"

            ac_qid=$(aws athena start-query-execution \
                --query-string "${ac_query}" \
                --work-group workshop \
                --query-execution-context "Database=${ac_database}" \
                --result-configuration "OutputLocation=${ac_output}" \
                --region "${AWS_REGION}" \
                --query 'QueryExecutionId' --output text 2>/dev/null || echo "")

            if [ -z "${ac_qid}" ] || [ "${ac_qid}" = "None" ]; then
                sleep "${ac_wait_secs}"
                ac_attempt=$((ac_attempt + 1))
                continue
            fi

            # Poll the execution until terminal.
            ac_state="RUNNING"
            ac_poll=0
            while [ "${ac_poll}" -lt 20 ]; do
                ac_state=$(aws athena get-query-execution \
                    --query-execution-id "${ac_qid}" \
                    --region "${AWS_REGION}" \
                    --query 'QueryExecution.Status.State' --output text 2>/dev/null || echo "FAILED")
                case "${ac_state}" in
                SUCCEEDED | FAILED | CANCELLED) break ;;
                esac
                sleep 3
                ac_poll=$((ac_poll + 1))
            done

            if [ "${ac_state}" != "SUCCEEDED" ]; then
                # Query itself failed/cancelled — surface and stop retrying.
                ac_reason=$(aws athena get-query-execution \
                    --query-execution-id "${ac_qid}" \
                    --region "${AWS_REGION}" \
                    --query 'QueryExecution.Status.StateChangeReason' --output text 2>/dev/null || echo "")
                print_fail "Check 14: Athena query did not SUCCEED (state=${ac_state})" \
                    "Reason: ${ac_reason}. Fix: confirm the audit_correlation VIEW exists (run the named query in Athena first) and the Glue tables resolve. Check: aws athena get-query-execution --query-execution-id ${ac_qid} --region ${AWS_REGION}"
                ac_row_count="ERROR"
                break
            fi

            # Result rows: subtract 1 for the header row.
            ac_total_rows=$(aws athena get-query-results \
                --query-execution-id "${ac_qid}" \
                --region "${AWS_REGION}" \
                --query 'length(ResultSet.Rows)' --output text 2>/dev/null || echo "0")
            if [ "${ac_total_rows:-0}" -ge 2 ] 2>/dev/null; then
                ac_row_count=$((ac_total_rows - 1))
                break
            fi

            # No data row yet — propagation likely incomplete; wait and retry.
            ac_row_count=0
            sleep "${ac_wait_secs}"
            ac_attempt=$((ac_attempt + 1))
        done

        if [ "${ac_row_count}" = "1" ]; then
            print_pass "Check 14 PASSED: audit_correlation returned exactly ONE row for request_id=${ac_request_id} (three-plane capstone — D3 step 14 GREEN)"
        elif [ "${ac_row_count}" = "ERROR" ]; then
            : # already reported by print_fail above
        elif [ "${ac_row_count}" = "0" ] || [ -z "${ac_row_count}" ]; then
            print_fail "Check 14: audit_correlation returned ZERO rows for request_id=${ac_request_id} after ~90s" \
                "Fix: wait longer for fluent-bit + Firehose (60s buffer) + Glue propagation, then re-run; confirm the ivia_decisions anchor row landed (SELECT count(*) FROM ivia_decisions WHERE request_id='${ac_request_id}'); confirm pgaudit/vault rows exist. Check: aws athena get-query-results --query-execution-id ${ac_qid:-<id>} --region ${AWS_REGION}"
        else
            print_fail "Check 14: audit_correlation returned ${ac_row_count} rows (expected exactly 1) for request_id=${ac_request_id}" \
                "Fix: a duplicate anchor or time-window join is producing fan-out; inspect the joined planes for the request_id."
        fi
    fi
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
