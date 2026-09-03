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
#   6.  UC2 native OBO surface: agent-uc2 registration + uc2-agent-ceiling policy
#       (the retired uc2-jwt jwt-auth role is GONE — decisions (b)/(e))
#   6b. REAL UC2 token: jti present AND act.sub=agent-uc2 (OBO cutover gate; the token
#       is SELF-MINTED headlessly via the production PKCE login path — UC2_VERIFY_TOKEN
#       overrides; a mint failure = warn-skip in default mode, HARD FAIL under --gate)
#   6c. UC2 refresh grant FAILS CLOSED — agent-uc2 withholds the refresh_token grant so
#       IVIA never issues one (self-mint probes it; the refresh grant must not yield an
#       act-bearing token — a stolen refresh token cannot mint agent-scoped DB access)
#   6d. OAuth alias binding: profile config_id==accessor .id + OBO allow (real token)
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
#   ./verify-uc2.sh [--gate] [--help]   (--gate: Checks 6b/6c/6d skip = HARD FAIL)
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
  ./verify-uc2.sh [--gate] [--help]

Modes:
  (default)   Routine deploy verify. Checks 6b/6c/6d SELF-MINT a real agent-uc2 OBO
              token headlessly; they warn-SKIP only if the self-mint is unavailable.
  --gate      UC2 cutover done-gate. Checks 6b/6c/6d HARD FAIL (not skip) if the
              self-mint fails, so the OBO cutover (jti + act.sub=agent-uc2 + the
              refresh-grant fail-closed edge) is provably exercised. This is the
              AUTHORITATIVE UC2 gate the Part B live run must invoke.

Checks (14 total):
  1.  Banking UI pod Running (app=banking-ui in banking-app namespace)
  2.  Banking Agent pod Running (app=banking-agent)
  3.  MCP Server pod Running (app=banking-mcp-server)
  4.  ServiceAccount uc2-mcp-server-sa exists in banking-app namespace
  5.  Vault k8s auth role uc2 bound to uc2-mcp-server-sa
  6.  UC2 native OBO surface: agent-uc2 registration + uc2-agent-ceiling policy
  6b. REAL UC2 token: jti + act.sub=agent-uc2 (self-minted; UC2_VERIFY_TOKEN overrides)
  6c. UC2 refresh grant FAILS CLOSED — agent-uc2 refresh_token grant withheld
  6d. OAuth alias binding: profile config_id==accessor .id + OBO allow (self-minted)
  7.  JIT DB creds issuance (database/creds/uc2-personal-readonly)
  8.  DB read: SELECT from banking.accounts succeeds with Vault-vended creds
  9.  ENFC-02: INSERT rejected with uc2-personal-readonly creds
  10. ENFC-03: Egress to external URL blocked from MCP server pod
  11. Agent /health endpoint returns "healthy"
  12. IVIA JWKS endpoint reachable (OAuth pre-check)
  13. Active lease exists after cred issuance (credential lifecycle)
  14. OAuth discovery: IVIA /.well-known/openid-configuration returns valid JSON

Env-var overrides:
  BANKING_NAMESPACE            (default: banking-app)
  VAULT_NAMESPACE              (default: vault)
  VAULT_POD                    (default: vault-0)
  VAULT_ROOT_TOKEN             (optional — used for lease listing)
  UC2_PERSONA                  (optional — workshop persona to self-mint the UC2 OBO
                                token for; default oscar)
  UC2_VERIFY_TOKEN             (optional — OVERRIDE the self-minted token with a real
                                banking OAuth JWT captured from the browser sign-in;
                                Checks 6b/6d assert jti + act.sub=agent-uc2 + OBO-allow)
  UC2_VERIFY_REFRESHED_TOKEN   (optional — OVERRIDE Check 6c with the legacy path: a
                                refresh_token-grant token presented to Vault, expect DENY)
USAGE
    exit 0
fi

# --gate: promote the token-dependent UC2 cutover checks (6b/6c/6d) from warn-SKIP
# to HARD FAIL when their tokens are absent, so a run cannot report all-PASS without
# actually exercising the OBO cutover. Mirrors verify-uc3.sh --bypass (skip=HARD FAIL).
UC2_CUTOVER_GATE=false
if [ "${1:-}" = "--gate" ]; then
    UC2_CUTOVER_GATE=true
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

# decode_jwt_claim <jwt> <jq-filter> — base64url-decode the JWT payload (2nd
# segment) and extract a claim via jq. Echoes the value, or empty on any failure.
# Portable across macOS/BusyBox base64 (both accept `-d`). Pads base64url to a
# multiple of 4 and maps the url-safe alphabet (-_ → +/) before decoding.
decode_jwt_claim() {
    local jwt="$1" filter="$2" payload
    payload=$(printf '%s' "$jwt" | cut -d. -f2)
    case $(( ${#payload} % 4 )) in
        2) payload="${payload}==" ;;
        3) payload="${payload}=" ;;
    esac
    printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null \
        | jq -r "$filter" 2>/dev/null || echo ""
}

# ivia_client_secret <client_id> — read ONE OIDC client's secret from the Kubernetes
# Secret that carries it. Every client (agent-uc2, agent-uc3, uc3-actor) has its OWN
# secret and none of them live in a ConfigMap any more (issue #30), so a caller must
# name the client it intends to authenticate as. An unknown client_id returns empty,
# which every call site treats as a hard mint failure.
ivia_client_secret() {
    local client_id="$1" secret_name key
    case "${client_id}" in
        agent-uc2) secret_name="banking-ui-oidc"; key="IVIA_CLIENT_SECRET" ;;
        agent-uc3) secret_name="uc3-oidc-clients"; key="IVIA_CLIENT_SECRET" ;;
        uc3-actor) secret_name="uc3-oidc-clients"; key="IVIA_ACTOR_CLIENT_SECRET" ;;
        *) return 1 ;;
    esac
    kubectl get secret -n "${BANKING_NAMESPACE}" "${secret_name}" \
        -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null
}


# _mint_uc2_token <user> — headlessly mint a REAL IVIA-issued UC2 OBO login token
# for <user>, exercising the EXACT production path the banking UI uses: PKCE
# authorization_code login at WebSEAL, then the token endpoint (client_secret_basic,
# client=agent-uc2). Populates:
#   MINTED_UC2_TOKEN     — sub=<user>, act.sub=agent-uc2 (the OBO actor), a native jti.
#   UC2_REFRESH_PRESENT  — yes|no: did the login response carry a refresh_token?
#   UC2_REFRESH_STATUS   — HTTP status of an attempted refresh_token grant.
#   UC2_REFRESH_HASACT   — yes|no: if the refresh grant returned 200, did the token
#                          carry an act claim? (the fail-closed edge for Check 6c).
# Returns 0 on success, 1 on any failure (so a --gate check HARD-FAILs, never silent).
#
# Every secret/host is sourced at RUNTIME (never hardcoded — global no-hardcoded-
# identity/auth rule): WRP host ← infrastructure/.acme-state; redirect_uri + client id
# ← banking-ui-config; agent-uc2's client secret ← the banking-ui-oidc Secret (each
# client has its OWN secret, issue #30); persona password ← base_layer.yaml.tftpl. The mint runs
# INSIDE the uc3-agent pod (has httpx + in-cluster iviaop DNS + egress to the WRP ALB).
_mint_uc2_token() {
    local user="$1"
    MINTED_UC2_TOKEN=""; UC2_REFRESH_PRESENT=""; UC2_REFRESH_STATUS=""; UC2_REFRESH_HASACT=""; UC2_MINT_ERR=""

    local acme_state="${SCRIPT_DIR}/../.acme-state"
    local base_layer="${SCRIPT_DIR}/../modules/verify_access/base_layer/base_layer.yaml.tftpl"
    local wrp ru secret agent_client persona_pw pod mint_out

    wrp=$(grep -E '^NIP_FQDN_WRP=' "${acme_state}" 2>/dev/null | cut -d= -f2)
    ru=$(kubectl get configmap -n "${BANKING_NAMESPACE}" banking-ui-config -o jsonpath='{.data.REDIRECT_URI}' 2>/dev/null)
    agent_client=$(kubectl get configmap -n "${BANKING_NAMESPACE}" banking-ui-config -o jsonpath='{.data.IVIA_CLIENT_ID}' 2>/dev/null)
    secret=$(ivia_client_secret "${agent_client}")
    persona_pw=$(grep -oE 'password:[[:space:]]*"[^"]+"' "${base_layer}" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    pod=$(kubectl get pod -n "${BANKING_NAMESPACE}" -l app=uc3-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "${wrp}" ] || [ -z "${ru}" ] || [ -z "${agent_client}" ] || [ -z "${secret}" ] || [ -z "${persona_pw}" ] || [ -z "${pod}" ]; then
        UC2_MINT_ERR="could not source mint inputs (wrp='${wrp}' ru='${ru}' client='${agent_client}' secret=$([ -n "${secret}" ] && echo set || echo MISSING) pw=$([ -n "${persona_pw}" ] && echo set || echo MISSING) pod='${pod}')"
        return 1
    fi

    mint_out=$(kubectl exec -i -n "${BANKING_NAMESPACE}" "${pod}" -- python3 - \
        "${user}" "${wrp}" "${ru}" "${agent_client}" "${secret}" "${persona_pw}" <<'PYEOF' 2>/dev/null
import base64,hashlib,json,os,re,sys,urllib.parse
try:
    import httpx
except Exception as e:
    print("MINT_ERR import httpx: %s" % e); sys.exit(1)
user,wrp,ru,agent_client,secret,pw = sys.argv[1:7]
if not wrp.startswith("http"): wrp = "https://" + wrp
op = "https://iviaop.verify-access.svc.cluster.local:8436"
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def claims(j):
    p = j.split(".")[1]; return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
try:
    cv = b64u(os.urandom(48)); cc = b64u(hashlib.sha256(cv.encode()).digest()); st = b64u(os.urandom(12))
    c = httpx.Client(verify=False, follow_redirects=False, timeout=30.0)
    az = (wrp + "/isvaop/oauth2/authorize?response_type=code&client_id=" + agent_client
          + "&redirect_uri=" + urllib.parse.quote(ru, safe='') + "&code_challenge=" + cc
          + "&code_challenge_method=S256&state=" + st + "&scope=openid+profile+email")
    c.get(az)
    c.post(wrp + "/pkmslogin.form",
           data={"username": user, "password": pw, "login-form-type": "pwd", "login-response-type": "original_url"})
    loc = c.get(az).headers.get("location", "")
    m = re.search(r"[?&]code=([^&]+)", loc)
    if not m:
        print("MINT_ERR no auth code returned (WebSEAL login failed for user=%s)" % user); sys.exit(1)
    code = urllib.parse.unquote(m.group(1))
    r = c.post(op + "/oauth2/token", auth=(agent_client, secret),
               data={"grant_type": "authorization_code", "code": code, "redirect_uri": ru, "code_verifier": cv})
    if r.status_code != 200:
        print("MINT_ERR authcode exchange %d %s" % (r.status_code, r.text[:200])); sys.exit(1)
    tok = r.json(); acc = tok["access_token"]; rt = tok.get("refresh_token")
    print("UC2TOKEN=" + acc)
    print("REFRESH_PRESENT=" + ("yes" if rt else "no"))
    # Probe the refresh_token grant — with the grant WITHHELD from agent-uc2 it must be
    # rejected (fail-closed at the source). Use the issued refresh_token if any, else a
    # placeholder (the client grant_types allowlist is checked regardless of the value).
    r2 = c.post(op + "/oauth2/token", auth=(agent_client, secret),
                data={"grant_type": "refresh_token", "refresh_token": rt if rt else "withheld-probe"})
    print("REFRESH_STATUS=%d" % r2.status_code)
    hasact = "no"
    if r2.status_code == 200:
        try:
            if claims(r2.json()["access_token"]).get("act"): hasact = "yes"
        except Exception:
            pass
    print("REFRESH_HASACT=" + hasact)
except Exception as e:
    print("MINT_ERR %s" % e); sys.exit(1)
PYEOF
)
    MINTED_UC2_TOKEN=$(printf '%s\n' "${mint_out}" | sed -n 's/^UC2TOKEN=//p')
    UC2_REFRESH_PRESENT=$(printf '%s\n' "${mint_out}" | sed -n 's/^REFRESH_PRESENT=//p')
    UC2_REFRESH_STATUS=$(printf '%s\n' "${mint_out}" | sed -n 's/^REFRESH_STATUS=//p')
    UC2_REFRESH_HASACT=$(printf '%s\n' "${mint_out}" | sed -n 's/^REFRESH_HASACT=//p')
    if [ -z "${MINTED_UC2_TOKEN}" ]; then
        UC2_MINT_ERR=$(printf '%s\n' "${mint_out}" | grep 'MINT_ERR' | head -1)
        [ -z "${UC2_MINT_ERR}" ] && UC2_MINT_ERR="mint produced no token (output: ${mint_out:0:200})"
        return 1
    fi
    return 0
}

# Self-mint a REAL agent-uc2 OBO token (+ refresh-grant probe) so Checks 6b/6c/6d run
# headlessly. UC2_VERIFY_TOKEN (if set) overrides the minted token — the Part B live
# gate can inject a browser-captured token instead.
UC2_PERSONA="${UC2_PERSONA:-oscar}"
MINTED_UC2_TOKEN=""; UC2_REFRESH_PRESENT=""; UC2_REFRESH_STATUS=""; UC2_REFRESH_HASACT=""; UC2_MINT_ERR=""
_mint_uc2_token "${UC2_PERSONA}" || true
if [ -z "${UC2_VERIFY_TOKEN:-}" ] && [ -n "${MINTED_UC2_TOKEN}" ]; then
    UC2_VERIFY_TOKEN="${MINTED_UC2_TOKEN}"
fi

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
# Check 6 — UC2 native OBO surface: agent-uc2 registration + agent ceiling
#
# Phase 9 cutover (locked decisions (b)/(e)): the uc2-jwt jwt-auth role is RETIRED
# (the jwt/ backend is GONE — asserted in test-vault-verify.sh). UC2 is now OBO:
# the human `sub` + the agent `act.sub=agent-uc2` resolve via the
# oauth-resource-server profile. Assert the two native surfaces exist:
#   (a) the agent-uc2 registration reads back by display-name, and
#   (b) the uc2-agent-ceiling policy is present (the OBO agent-ceiling layer;
#       its live enforcement is exercised end-to-end by the OBO-allow in Check 6d
#       and mirrored by verify-uc3's wrong-actor / RAR deny suite).
#-------------------------------------------------------------------------------
uc2_reg_name=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read -format=json agent-registry/registration/display-name/agent-uc2" 2>/dev/null \
    | jq -r '.data.display_name // empty' 2>/dev/null || echo "")
if [ "${uc2_reg_name}" = "agent-uc2" ]; then
    print_pass "UC2 Agent Registry: registration 'agent-uc2' resolvable by display-name (OBO actor)"
else
    print_fail "UC2 Agent Registry registration (agent-uc2)" \
        "agent-registry/registration/display-name/agent-uc2 did not read back (got '${uc2_reg_name}') — reapply vault_config (vault_agent_registration.agent_uc2). Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault read agent-registry/registration/display-name/agent-uc2"
fi

uc2_ceiling=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault policy read uc2-agent-ceiling" 2>/dev/null || echo "")
if [ -n "${uc2_ceiling}" ] && echo "${uc2_ceiling}" | grep -q 'path'; then
    print_pass "UC2 agent ceiling policy 'uc2-agent-ceiling' present (OBO agent-ceiling layer)"
else
    print_fail "UC2 agent ceiling policy (uc2-agent-ceiling)" \
        "Vault policy uc2-agent-ceiling not found or empty — reapply vault_config (vault_policy.uc2_agent_ceiling). Check: kubectl exec -n ${VAULT_NAMESPACE} ${VAULT_POD} -- vault policy read uc2-agent-ceiling"
fi

#-------------------------------------------------------------------------------
# Check 6b — REAL UC2 token: jti present AND act.sub=agent-uc2 (OBO cutover gate)
#
# UNCONDITIONAL native assertion (no UC2_ENDSTATE / jwt_login branch — the cutover
# is LOCKED, decision (b)). UC2 is OBO: AGENT_IDENTITY_CLAIM_UC2=act.sub. Decode the
# ACTUAL banking OAuth JWT the MCP server forwards to Vault and assert:
#   - a non-empty `jti` claim (JTI_MANDATORY — a jti-less token 403s at Vault), and
#   - `act.sub` == agent-uc2 (the OBO actor binding).
# A missing jti OR a missing/wrong act.sub FAILS LOUD; the fix is Plan 04's UC2
# jti + act.sub emission, NEVER a jwt_login fallback.
#
# Token source: SELF-MINTED headlessly by _mint_uc2_token via the EXACT production
# path (PKCE authorization_code login at WebSEAL, then the token endpoint with
# client_secret_basic, client=agent-uc2). UC2_VERIFY_TOKEN overrides the minted token
# (e.g. a browser-captured token for the Part B live gate). When the self-mint is
# unavailable the assertion is SKIPPED with a warn (never a fake pass) — HARD FAIL
# under --gate.
#-------------------------------------------------------------------------------
if [ -n "${UC2_VERIFY_TOKEN:-}" ]; then
    uc2_jti=$(decode_jwt_claim "${UC2_VERIFY_TOKEN}" '.jti // empty')
    uc2_actsub=$(decode_jwt_claim "${UC2_VERIFY_TOKEN}" '.act.sub // empty')

    if [ -n "${uc2_jti}" ]; then
        print_pass "UC2 real token carries a jti claim (jti=${uc2_jti})"
    else
        print_fail "UC2 real-token jti MISSING" \
            "The forwarded UC2 OAuth token has NO jti claim — Vault (JTI_MANDATORY) rejects it and UC2 (no fallback) breaks. Fix = Plan 04's UC2 jti emission on the aud=agent-uc2 authcode grant, NEVER a jwt_login fallback. Decode: echo <jwt> | cut -d. -f2 | base64 -d"
    fi

    if [ "${uc2_actsub}" = "agent-uc2" ]; then
        print_pass "UC2 real token carries act.sub=agent-uc2 (OBO actor binding — AGENT_IDENTITY_CLAIM_UC2=act.sub)"
    else
        print_fail "UC2 real-token act.sub != agent-uc2" \
            "The forwarded UC2 token's act.sub is '${uc2_actsub:-<absent>}' (expected agent-uc2) — native OBO cannot resolve the agent actor and UC2 fails closed. Fix = Plan 04's ACTOR_CLAIM_UC2=agent-uc2 emission, NEVER a jwt_login fallback."
    fi
else
    if [ "${UC2_CUTOVER_GATE}" = "true" ]; then
        print_fail "UC2 real-token jti + act.sub gate NOT exercised — self-mint failed and no UC2_VERIFY_TOKEN (--gate: skip = HARD FAIL)" \
            "Self-mint error: ${UC2_MINT_ERR:-unknown}. _mint_uc2_token headlessly mints a real agent-uc2 OBO token via the production PKCE login path; ensure the uc3-agent pod is Running and IVIA is reachable. Or supply UC2_VERIFY_TOKEN=<real banking OAuth JWT: sub=<human>, act.sub=agent-uc2, a unique jti> and re-invoke with --gate."
    else
        print_warn "UC2 real-token jti + act.sub checks SKIPPED — self-mint unavailable (${UC2_MINT_ERR:-no token}); set UC2_VERIFY_TOKEN=<real banking OAuth JWT> to exercise the phase-done gate. This is NOT a pass."
    fi
fi

#-------------------------------------------------------------------------------
# Check 6c — UC2 refresh grant FAILS CLOSED (fail-closed enforced AT THE SOURCE)
#
# Fail-closed-on-refresh is enforced by WITHHOLDING the refresh_token grant from the
# agent-uc2 client (clients.yml.tftpl grant_types = authorization_code only). This is
# REQUIRED because ISVAOP auto-propagates the parent token's act=agent-uc2 claim into
# any refresh-grant reissue and the isvaop_pretoken mapping rule CANNOT strip it
# (proven live: the rule's delete runs but ISVAOP re-injects the parent claims
# downstream of pre_token, so a refreshed token still carries act -> Vault 200).
# Withholding the grant means IVIA never issues a refresh token, so the OBO agent
# identity is mintable ONLY on fresh interactive auth — capping the blast radius of a
# stolen 30-day refresh token. The app never uses refresh (access_token cookie =
# expires_in), so this is pure security upside.
#
# The self-mint (_mint_uc2_token) probed the refresh grant: UC2_REFRESH_STATUS is the
# HTTP status of an attempted refresh_token grant, UC2_REFRESH_HASACT whether a 200
# reissue carried act, UC2_REFRESH_PRESENT whether the login response even issued a
# refresh_token. PASS iff the refresh grant does NOT yield an act-bearing token.
#
# UC2_VERIFY_REFRESHED_TOKEN (if set) overrides with the legacy present-to-Vault path:
# a refreshed token presented to Vault must be DENIED (belt-and-suspenders).
#-------------------------------------------------------------------------------
if [ -n "${UC2_VERIFY_REFRESHED_TOKEN:-}" ]; then
    ref_jti=$(decode_jwt_claim "${UC2_VERIFY_REFRESHED_TOKEN}" '.jti // empty')
    ref_act=$(decode_jwt_claim "${UC2_VERIFY_REFRESHED_TOKEN}" '.act.sub // empty')
    ref_out=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
        sh -c "VAULT_TOKEN='${UC2_VERIFY_REFRESHED_TOKEN}' vault read database/creds/uc2-personal-readonly" 2>&1)
    ref_rc=$?
    if [ "${ref_rc}" -ne 0 ] \
        && echo "${ref_out}" | grep -qiE 'permission denied|invalid token|missing|denied|403|error validating'; then
        print_pass "UC2 refreshed token (jti='${ref_jti:-none}', act.sub='${ref_act:-none}') FAILS CLOSED at Vault — no silent credential vend on a refreshed token"
    else
        print_fail "UC2 refreshed-token fail-closed" \
            "A refreshed UC2 token was ACCEPTED by Vault (rc=${ref_rc}) — it lacks act/jti and MUST be rejected. The MCP server must never forward a refreshed token, and Vault must fail closed. Output: ${ref_out:0:200}"
    fi
elif [ -n "${MINTED_UC2_TOKEN}" ]; then
    if [ "${UC2_REFRESH_STATUS}" = "200" ] && [ "${UC2_REFRESH_HASACT}" = "yes" ]; then
        print_fail "UC2 refresh fail-closed (grant withheld)" \
            "agent-uc2's refresh_token grant returned an ACT-bearing token (HTTP 200, act present) — IVIA still honors the refresh grant for this client, so a stolen refresh token could mint agent-scoped DB access. Remove 'refresh_token' from agent-uc2 grant_types in modules/verify_access/iviaop-config/clients.yml.tftpl (the mapping rule CANNOT strip a propagated act) and re-apply tier-3 (deploy-workshop.sh --tier 3) so the iviaop_clients_patch re-renders and iviaop is rolled. refresh_token in login response=${UC2_REFRESH_PRESENT}."
    elif [ "${UC2_REFRESH_STATUS}" != "200" ]; then
        print_pass "UC2 refresh grant FAILS CLOSED at the source — agent-uc2 refresh_token grant rejected (HTTP ${UC2_REFRESH_STATUS}; refresh_token issued at login=${UC2_REFRESH_PRESENT}). The OBO agent identity is mintable only on fresh interactive auth — a stolen refresh token cannot mint agent-scoped DB access."
    else
        print_pass "UC2 refresh grant returned a token WITHOUT an act claim (HTTP 200, no agent identity) — fail closed on refresh (refresh_token issued at login=${UC2_REFRESH_PRESENT})."
    fi
else
    if [ "${UC2_CUTOVER_GATE}" = "true" ]; then
        print_fail "UC2 refresh fail-closed edge NOT exercised — self-mint failed and no UC2_VERIFY_REFRESHED_TOKEN (--gate: skip = HARD FAIL)" \
            "Self-mint error: ${UC2_MINT_ERR:-unknown}. Ensure the uc3-agent pod is Running and IVIA is reachable so _mint_uc2_token can probe the refresh grant, or supply UC2_VERIFY_REFRESHED_TOKEN=<a refresh_token-grant token> to present it to Vault and prove DENY."
    else
        print_warn "UC2 refresh fail-closed check SKIPPED — self-mint unavailable (${UC2_MINT_ERR:-no token}). The Part B live gate exercises it via the self-mint (or UC2_VERIFY_REFRESHED_TOKEN)."
    fi
fi

#-------------------------------------------------------------------------------
# Check 6d — OAuth alias binding: profile config_id == the accessor's, OBO allow
#            (folded-in CONFIG_ID vs .id check)
#
# Plan 05 builds the actor/subject alias mount_accessor as the synthetic string
# `oauth-resource-server_root_${profile.id}` (09-DISCOVERY MOUNT_ACCESSOR_FORM).
# This confirms the profile resource `.id` equals the actual config_id Vault
# materialized in the synthetic accessor — if they diverged, the actor alias would
# point at a non-existent accessor and OBO would fail closed. Two signals:
#   (1) Structural: the agent-uc2 entity alias's mount_accessor has the
#       oauth-resource-server_root_<config_id> form and its suffix matches the
#       profile id (best-effort; warns if the alias/field is not enumerable).
#   (2) Load-bearing: present the REAL UC2 token (sub=human + act.sub=agent-uc2 +
#       jti) via X-Vault-Token to database/creds/uc2-personal-readonly and expect
#       ALLOW — the end-to-end proof that the alias binds and OBO resolves.
#-------------------------------------------------------------------------------
# (1) Structural cross-check — resolve the profile id and the actor alias accessor.
profile_id=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault read -format=json sys/config/oauth-resource-server/ivia" 2>/dev/null \
    | jq -r '.data.config_id // .data.id // .config_id // empty' 2>/dev/null || echo "")
actor_accessor=""
for _aid in $(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "${VAULT_EXEC} vault list -format=json identity/entity-alias/id" 2>/dev/null \
    | jq -r '.[]?' 2>/dev/null); do
    _a=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
        sh -c "${VAULT_EXEC} vault read -format=json identity/entity-alias/id/${_aid}" 2>/dev/null || echo "{}")
    if [ "$(echo "${_a}" | jq -r '.data.name // empty' 2>/dev/null)" = "agent-uc2" ]; then
        actor_accessor=$(echo "${_a}" | jq -r '.data.mount_accessor // empty' 2>/dev/null || echo "")
        break
    fi
done
if echo "${actor_accessor}" | grep -q '^oauth-resource-server_root_'; then
    accessor_cfg="${actor_accessor#oauth-resource-server_root_}"
    if [ -n "${profile_id}" ] && [ "${accessor_cfg}" = "${profile_id}" ]; then
        print_pass "UC2 alias accessor '${actor_accessor}' matches oauth profile config_id (.id=${profile_id}) — alias binding intact"
    else
        print_warn "UC2 alias accessor is '${actor_accessor}' (form OK); profile config_id ('${profile_id:-unresolved}') not field-matched — the load-bearing OBO-allow below is authoritative"
    fi
else
    print_warn "UC2 actor alias mount_accessor not enumerable (got '${actor_accessor:-none}') — the load-bearing OBO-allow below is authoritative for the binding"
fi

# (2) Load-bearing OBO allow — the real token must resolve and be authorized.
if [ -n "${UC2_VERIFY_TOKEN:-}" ]; then
    obo_user=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
        sh -c "VAULT_TOKEN='${UC2_VERIFY_TOKEN}' vault read -format=json database/creds/uc2-personal-readonly" 2>/dev/null \
        | jq -r '.data.username // empty' 2>/dev/null || echo "")
    if [ -n "${obo_user}" ]; then
        print_pass "UC2 OBO allow: real token (sub + act.sub=agent-uc2) authorized database/creds/uc2-personal-readonly (username=${obo_user}) — alias binds, config_id/.id correct"
    else
        print_fail "UC2 OBO allow (alias binding)" \
            "The real UC2 token was NOT authorized for database/creds/uc2-personal-readonly — the oauth alias may not bind (config_id/.id mismatch in oauth-resource-server_root_<id>), the agent ceiling denies it, or jti/act.sub is malformed. Check: present the token via X-Vault-Token to \$VAULT_ADDR/v1/database/creds/uc2-personal-readonly and inspect the Vault response."
    fi
else
    if [ "${UC2_CUTOVER_GATE}" = "true" ]; then
        print_fail "UC2 OBO-allow (alias binding) NOT exercised — self-mint failed and no UC2_VERIFY_TOKEN (--gate: skip = HARD FAIL)" \
            "The load-bearing config_id/.id accessor binding is proven by presenting the self-minted (or UC2_VERIFY_TOKEN) real token to database/creds/uc2-personal-readonly (OBO allow). Self-mint error: ${UC2_MINT_ERR:-unknown} (see Check 6b). Re-invoke with --gate once the uc3-agent pod is Running and IVIA is reachable."
    else
        print_warn "UC2 OBO-allow (alias binding) check SKIPPED — self-mint unavailable (${UC2_MINT_ERR:-no token}); see Check 6b. The Part B live gate exercises it via --gate."
    fi
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
    # Use a real seeded user_sub ('oscar') so RLS lets us prove the SELECT actually
    # returns the user's rows. A bogus sub would silently return 0 rows and still
    # appear to "pass" — which would mean this check verifies nothing.
    kubectl run "${psql_pod}" -n default --restart=Never \
        --image=postgres:17-alpine --env="PGPASSWORD=${db_password}" \
        --command -- psql -h "${rds_host}" -U "${db_username}" -d workshop \
            -c "SET app.current_user_sub = 'oscar'; SELECT count(*) FROM banking.accounts;" \
            --no-password --tuples-only &>/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${psql_pod}" -n default --timeout=60s &>/dev/null || true
    select_result=$(kubectl logs "${psql_pod}" -n default 2>/dev/null || echo "PSQL_FAILED")
    kubectl delete pod "${psql_pod}" -n default --ignore-not-found &>/dev/null

    row_count=$(echo "${select_result}" | grep -oE "^[[:space:]]*[0-9]+" | tr -d ' ' | head -n1)
    if [ -n "${row_count}" ] && [ "${row_count}" -ge 2 ]; then
        print_pass "DB read: SELECT from banking.accounts returned ${row_count} row(s) for user 'oscar' (>= 2 expected)"
    else
        print_fail "DB read: SELECT from banking.accounts" \
            "SELECT did not return >= 2 rows for user 'oscar' — RDS host: ${rds_host}, user: ${db_username}. Got: '${select_result}'. Verify the seed.sql has Oscar's accounts loaded and the uc2-personal-readonly Postgres role has SELECT on banking.accounts."
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
# Check 10b — the MCP tool contract has no place to put an identity
#
# The token the MCP server acts on must come from the Authorization header and
# nowhere else. A `jwt` tool parameter would make the header decoration: anything
# able to reach the server would choose the identity Vault sees, and the OBO
# intersection, the RLS predicate and the audit record would all faithfully
# enforce the caller's choice of user. tools/list needs no real user (it touches
# neither Vault nor the database), so any non-empty bearer gets past the 401 gate.
#
# This is the scripted half of the attendee exercise on the OAuth Login Flow page.
#-------------------------------------------------------------------------------
tools_probe_pod="verify-uc2-tools-$$"
kubectl delete pod "${tools_probe_pod}" -n "${BANKING_NAMESPACE}" --ignore-not-found --now &>/dev/null
tools_json=$(kubectl run "${tools_probe_pod}" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:8.11.1 -n "${BANKING_NAMESPACE}" --command -- \
    curl -s -X POST http://banking-mcp-svc:3001/mcp \
      -H 'Authorization: Bearer schema-probe' \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null || echo "PROBE_FAILED")

if [ "${tools_json}" = "PROBE_FAILED" ] || [ -z "${tools_json}" ]; then
    print_warn "MCP tool-contract check skipped — tools/list probe returned nothing (is banking-mcp-svc up?)"
elif ! echo "${tools_json}" | grep -q '"get_accounts"'; then
    print_fail "MCP tool contract: tools/list did not list get_accounts" \
        "tools/list returned: ${tools_json:0:300}. Expected the banking-tools server to advertise get_accounts and get_transactions."
elif echo "${tools_json}" | grep -q '"jwt"'; then
    print_fail "MCP tool contract: a tool still declares a jwt parameter" \
        "tools/list advertises a 'jwt' input — the caller could then choose the identity Vault sees, making the Authorization header decorative. Remove the parameter and close over the header token in createMcpServer(). Response: ${tools_json:0:400}"
else
    print_pass "MCP tool contract: no tool accepts a jwt argument — identity can only come from the Authorization header"
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
# Vault's OAuth resource server validates user JWTs against IVIA's JWKS endpoint.
# Verify the JWKS URL is reachable from within the cluster (via vault-0 proxy check).
# This is a prerequisite for the full OAuth flow, not a full OAuth test.
#-------------------------------------------------------------------------------
ivia_jwks_url="https://iviaop.verify-access.svc.cluster.local:8436/oauth2/jwks"
jwks_result=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    sh -c "wget -q -O - --no-check-certificate --timeout=10 '${ivia_jwks_url}'" 2>/dev/null | jq -r '.keys | length' 2>/dev/null || echo "0")

if [ "${jwks_result:-0}" -ge 1 ] 2>/dev/null; then
    print_pass "IVIA JWKS endpoint reachable (${jwks_result} key(s) returned) — OAuth pre-check passed"
else
    print_warn "IVIA JWKS endpoint not reachable at ${ivia_jwks_url} — IVIA may still be initializing or the JWKS URL differs. Check IVIA pods: kubectl get pods -n verify-access"
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
# Phase 07.8 D-02 scoped the WRP Ingress to the nip.io FQDN, so the raw
# ALB hostname no longer matches the host rule and returns 404 on /isvaop
# paths. Resolve the FQDN from .acme-state, which deploy-workshop.sh Step 7
# writes after the LE cert is issued. Fall back to the raw ALB host if
# .acme-state is missing (older deploys) so this check still has a chance.
_acme_state_file="${SCRIPT_DIR}/../.acme-state"
ivia_endpoint=""
if [ -f "${_acme_state_file}" ]; then
    # shellcheck source=/dev/null
    . "${_acme_state_file}"
    ivia_endpoint="${NIP_FQDN_WRP:-}"
fi
if [ -z "${ivia_endpoint}" ]; then
    ivia_endpoint=$(kubectl get ingress -n verify-access ivia-wrp \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
fi

if [ -n "${ivia_endpoint}" ]; then
    discovery=$(curl -sLk "https://${ivia_endpoint}/isvaop/oauth2/.well-known/openid-configuration" \
        --max-time 15 -H "Accept: application/json" 2>/dev/null || echo "{}")
    if echo "${discovery}" | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .jwks_uri' >/dev/null 2>&1; then
        issuer=$(echo "${discovery}" | jq -r '.issuer')
        print_pass "OAuth discovery: IVIA OIDC Provider reachable (issuer=${issuer})"
    else
        print_fail "OAuth discovery failed" \
            "GET https://${ivia_endpoint}/isvaop/oauth2/.well-known/openid-configuration did not return a valid OIDC document. Response: ${discovery:0:300}. Verify the WRP unauth ACL is attached to /isvaop/oauth2/.well-known and the iviaop pod is Ready."
    fi
else
    print_warn "OAuth discovery check skipped — neither NIP_FQDN_WRP (.acme-state) nor IVIA ALB hostname resolved"
fi

# Summary is printed automatically by the common-checks.sh EXIT trap
