#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# capture-uc2-jwt.sh — headlessly capture a real IVIA-issued access_token JWT for a
# workshop LDAP user, so the Use Case 2 demo beat can run page-62 Step 5 verbatim
# without a manual browser sign-in.
#
# This mirrors exactly what the attendee does in the browser (sign in as the user
# at the IVIA WebSEAL login page → OAuth Authorization Code + PKCE), but driven
# with curl so the demo is reproducible. The access_token is the same value the
# attendee copies from the banking-UI HttpOnly `access_token` cookie via DevTools.
#
# It must be the access_token, NOT the id_token: only the access_token carries the
# `act` claim naming the agent actor, and without it Vault cannot resolve the
# on-behalf-of pair and returns 403.
#
# Why the token exchange goes through a port-forward and not the WRP ALB: WebSEAL
# strips the inbound Authorization header on its /isvaop junction, so a Basic-auth
# token POST through the ALB fails ("client credentials missing"). The banking-UI
# itself exchanges the code in-cluster against iviaop:8436 for the same reason;
# this script does the same via `kubectl port-forward`.
#
# Identity is NOT defaulted: the username is a required argument and the password
# a required env var — no auth-relevant value falls back to a hardcoded default.
#
# Writes demo/out/uc2-jwt.env (gitignored) with JWT_TOKEN=<access_token>. The
# token TTL is ~1h — run this immediately before rendering the UC2 beat.
#
# Usage:
#   UC2_DEMO_PASSWORD='...' bash demo/capture-uc2-jwt.sh oscar
#-------------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p demo/out

USER_NAME="${1:-}"
[ -n "$USER_NAME" ] || { echo "usage: UC2_DEMO_PASSWORD='...' bash demo/capture-uc2-jwt.sh <username>" >&2; exit 2; }
PASSWORD="${UC2_DEMO_PASSWORD:-}"
[ -n "$PASSWORD" ] || { echo "UC2_DEMO_PASSWORD env var is required (the user's LDAP password)" >&2; exit 2; }

# --- everything else derived from the live cluster (no hardcoded endpoints/secrets)
# shellcheck disable=SC1091
source infrastructure/.acme-state   # NIP_FQDN_WRP, NIP_FQDN_BANKING
WRP="https://${NIP_FQDN_WRP}"
RU="https://${NIP_FQDN_BANKING}/callback"
cfg() { kubectl get configmap -n banking-app banking-ui-config -o jsonpath="{.data.$1}"; }
CID="$(cfg IVIA_CLIENT_ID)"
# agent-uc2's client secret is a Kubernetes Secret, not a ConfigMap key — each OIDC
# client has its own credential and none of them are readable via `get configmap`.
CSEC="$(kubectl get secret -n banking-app banking-ui-oidc -o jsonpath='{.data.IVIA_CLIENT_SECRET}' | base64 -d)"
[ -n "$CID" ] && [ -n "$CSEC" ] || { echo "could not read agent-uc2 client creds (client_id <- banking-ui-config, secret <- banking-ui-oidc Secret)" >&2; exit 1; }

# --- in-cluster OP token endpoint via port-forward (bypasses the WRP junction)
LPORT=18436
kubectl port-forward -n verify-access svc/iviaop "${LPORT}:8436" >/tmp/uc2-pf.log 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sk "https://localhost:${LPORT}/oauth2/.well-known/openid-configuration" >/dev/null 2>&1 && break
  sleep 0.5
done

# --- PKCE pair (S256, matching the banking-UI)
CV="$(openssl rand -base64 60 | tr -d '=+/\n' | cut -c1-64)"
CC="$(printf '%s' "$CV" | openssl dgst -binary -sha256 | openssl base64 | tr -d '=' | tr '+/' '-_')"
JAR="$(mktemp)"
AUTH="${WRP}/isvaop/oauth2/authorize?response_type=code&client_id=${CID}&redirect_uri=${RU}&code_challenge=${CC}&code_challenge_method=S256&state=demo-$$&scope=openid+profile+email"

# 1) prime the WebSEAL login form (establishes request state)
curl -sk -c "$JAR" -b "$JAR" "$AUTH" -o /dev/null
# 2) authenticate at WebSEAL (LDAP bind)
curl -sk -c "$JAR" -b "$JAR" -o /dev/null \
  --data-urlencode "username=${USER_NAME}" \
  --data-urlencode "password=${PASSWORD}" \
  --data-urlencode "login-form-type=pwd" \
  --data-urlencode "login-response-type=original_url" \
  "${WRP}/pkmslogin.form"
# 3) re-request authorize WITH the session → 303 to the callback carrying ?code=
LOC="$(curl -sk -c "$JAR" -b "$JAR" -D - -o /dev/null "$AUTH" | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: //')"
CODE="$(printf '%s' "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
[ -n "$CODE" ] || { echo "no authorization code returned — check the username/password for '${USER_NAME}'" >&2; exit 1; }
# 4) exchange the code in-cluster (Basic auth, /oauth2/token, no /isvaop prefix)
TOK="$(curl -sk -u "${CID}:${CSEC}" -X POST "https://localhost:${LPORT}/oauth2/token" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "redirect_uri=${RU}" \
  --data-urlencode "code_verifier=${CV}")"
ACCESS_TOKEN="$(printf '%s' "$TOK" | jq -r '.access_token // empty')"
[ -n "$ACCESS_TOKEN" ] || { echo "token exchange did not return an access_token. response:" >&2; printf '%s\n' "$TOK" | head -c 400 >&2; exit 1; }

printf 'JWT_TOKEN=%s\n' "$ACCESS_TOKEN" > demo/out/uc2-jwt.env
SUB="$(printf '%s' "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' | { read -r p; printf '%s' "${p}$(printf '%*s' $(( (4 - ${#p} % 4) % 4 )) '' | tr ' ' '=')"; } | base64 -d 2>/dev/null | jq -r '.sub' 2>/dev/null || echo '?')"
echo "DONE -> demo/out/uc2-jwt.env  (access_token for sub='${SUB}', ~1h TTL)"
