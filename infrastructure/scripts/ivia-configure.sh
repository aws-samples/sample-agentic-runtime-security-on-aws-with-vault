#!/usr/bin/env bash
#===============================================================================
# ivia-configure.sh — IVIA Runtime Configuration
#
# Configures IVIA at runtime AFTER the Terraform deploy of uc2_app:
#   1. Creates test users Oscar and Adriana in the IVIA local user registry
#   2. Updates the UC2 OAuth client (agent-uc2) redirect_uri to the banking
#      app ALB hostname (auto-discovered from the banking-app namespace Ingress)
#   3. Verifies both operations succeed
#
# Called from workshop-e2e.sh AFTER the uc2_app Terraform deploy — the banking app
# ALB Ingress must exist before this script runs so the redirect URI is known.
#
# Prerequisites:
#   - kubectl configured and pointing to the workshop EKS cluster
#   - IVIA admin pod reachable via kubectl port-forward (port 8436)
#   - IVIA_ADMIN_PASSWORD env var OR readable from Terraform/HCP state
#
# Usage:
#   ./ivia-configure.sh [--dry-run] [--help]
#
# Options:
#   --dry-run   Print planned actions without making API calls
#   --help      Show this help message and exit
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
IVIA_PORT=8436
IVIA_LOCALHOST="localhost"
IVIA_BASE="http://${IVIA_LOCALHOST}:${IVIA_PORT}"
IVIA_ADMIN_USERNAME="${IVIA_ADMIN_USERNAME:-admin}"
UC2_CLIENT_ID="agent-uc2"
BANKING_APP_NAMESPACE="banking-app"
CALLBACK_PATH="/callback"

DRY_RUN=false

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

IVIA Runtime Configuration Script for the Agentic Runtime Security Workshop.

Configures IVIA after uc2_app Terraform deploy:
  - Creates test users Oscar and Adriana in IVIA local user registry
  - Updates agent-uc2 OAuth client redirect_uri to banking app ALB hostname

Options:
  --dry-run   Print planned actions without making API calls to IVIA
  --help      Show this help message and exit

Environment Variables:
  IVIA_ADMIN_PASSWORD   IVIA admin password (required unless --dry-run)
  IVIA_ADMIN_USERNAME   IVIA admin username (default: admin)
  OSCAR_PASSWORD        Password for Oscar test user (default: Workshop@123)
  ADRIANA_PASSWORD      Password for Adriana test user (default: Workshop@123)

Examples:
  # Normal run (IVIA admin password set in env):
  export IVIA_ADMIN_PASSWORD='<password>'
  ./ivia-configure.sh

  # Dry run (no API calls):
  ./ivia-configure.sh --dry-run

Notes:
  - Script is idempotent: GET-before-POST pattern; existing users/URIs are
    checked first and skipped if already configured correctly.
  - Requires an active kubectl port-forward to IVIA admin port 8436.
    Start with: kubectl -n verify-access port-forward svc/isvaop 8436:8436 &
  - HTTP redirect URIs are intentional — workshop uses ALB-generated hostnames
    that cannot get public ACM certs (lab-only, not production).
EOF
}

#-------------------------------------------------------------------------------
# CLI argument parsing
#-------------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --help)   usage; exit 0 ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------

# ivia_curl: wrapper around curl for IVIA admin API calls
# Usage: ivia_curl <method> <path> [<json-body>]
# Returns HTTP response body; exits non-zero on curl failure.
ivia_curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=(
    --silent --show-error
    --max-time 10
    --user "${IVIA_ADMIN_USERNAME}:${IVIA_ADMIN_PASSWORD}"
    --header "Accept: application/json"
    --request "${method}"
    "${IVIA_BASE}${path}"
  )
  if [ -n "$body" ]; then
    args+=(--header "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}"
}

# dry_echo: print a [DRY-RUN] prefixed action line
dry_echo() {
  echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
}

#-------------------------------------------------------------------------------
# Step 0: Dry-run fast-path
#-------------------------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  echo
  echo -e "${BLUE}=== IVIA Configure — Dry Run ===${NC}"
  echo
  dry_echo "Would check IVIA connectivity at ${IVIA_BASE}/mga/sps/mga/user/mgmt/users"
  dry_echo "Would GET banking app ALB hostname from: kubectl get ingress -n ${BANKING_APP_NAMESPACE}"
  dry_echo "Would create user: oscar  (if not exists)"
  dry_echo "Would create user: adriana  (if not exists)"
  dry_echo "Would PATCH agent-uc2 redirect_uris → http://<alb-hostname>${CALLBACK_PATH}"
  dry_echo "Would verify agent-uc2 config and user list"
  echo
  echo -e "${GREEN}Dry run complete. No changes made.${NC}"
  exit 0
fi

#-------------------------------------------------------------------------------
# Step 1: Validate prerequisites
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}=== IVIA Configure ===${NC}"
echo

# Require IVIA_ADMIN_PASSWORD
if [ -z "${IVIA_ADMIN_PASSWORD:-}" ]; then
  print_fail "IVIA_ADMIN_PASSWORD env var" \
    "export IVIA_ADMIN_PASSWORD='<password>' — obtain from: terraform output -json | jq -r '.ivia_admin_password.value' or HCP Terraform state"
  print_summary
  exit 1
fi

# Require kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  print_fail "kubectl not found" "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
  print_summary
  exit 1
fi
print_pass "kubectl available"

# Require curl
if ! command -v curl >/dev/null 2>&1; then
  print_fail "curl not found" "Install curl: brew install curl (macOS) or apt-get install curl (Linux)"
  print_summary
  exit 1
fi
print_pass "curl available"

#-------------------------------------------------------------------------------
# Step 2: Check IVIA connectivity (requires active port-forward)
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}--- Step 2: IVIA connectivity ---${NC}"

if ! curl --silent --max-time 5 "${IVIA_BASE}/mga/sps/oauth/oauth20/clients" \
     --user "${IVIA_ADMIN_USERNAME}:${IVIA_ADMIN_PASSWORD}" \
     --output /dev/null --write-out "%{http_code}" | grep -qE "^(200|401|403)"; then
  print_fail "IVIA admin API reachable at ${IVIA_BASE}" \
    "Start port-forward: kubectl -n verify-access port-forward svc/isvaop ${IVIA_PORT}:${IVIA_PORT} &"
  print_summary
  exit 1
fi
print_pass "IVIA admin API reachable at ${IVIA_BASE}"

#-------------------------------------------------------------------------------
# Step 3: Get banking app ALB hostname from Ingress
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}--- Step 3: Discover banking app ALB hostname ---${NC}"

ALB_HOSTNAME=$(kubectl get ingress -n "${BANKING_APP_NAMESPACE}" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "${ALB_HOSTNAME:-}" ]; then
  print_fail "banking-app Ingress ALB hostname" \
    "Ensure uc2_app is deployed via HCP Terraform workspace run; then re-run this script"
  print_summary
  exit 1
fi

REDIRECT_URI="http://${ALB_HOSTNAME}${CALLBACK_PATH}"
print_pass "Banking app ALB hostname: ${ALB_HOSTNAME}"
print_info "Redirect URI will be set to: ${REDIRECT_URI}"

#-------------------------------------------------------------------------------
# Step 4: Create test users in IVIA local user registry (idempotent)
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}--- Step 4: Create IVIA test users ---${NC}"

OSCAR_PASSWORD="${OSCAR_PASSWORD:-Workshop@123}"
ADRIANA_PASSWORD="${ADRIANA_PASSWORD:-Workshop@123}"

create_ivia_user() {
  local username="$1"
  local password="$2"
  local display_name="$3"
  local email="$4"

  # GET first — idempotency check
  local existing
  existing=$(ivia_curl GET "/mga/sps/mga/user/mgmt/users/${username}" 2>/dev/null || true)
  if echo "$existing" | grep -q "\"uid\":"; then
    print_pass "User '${username}' already exists in IVIA — skipping"
    return 0
  fi

  # POST — create user
  local user_payload
  user_payload=$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
  "userName": "${username}",
  "password": "${password}",
  "displayName": "${display_name}",
  "emails": [{"value": "${email}", "primary": true}],
  "active": true
}
JSON
)

  local response
  response=$(ivia_curl POST "/mga/sps/mga/user/mgmt/users" "${user_payload}" 2>&1)
  if echo "$response" | grep -qE '"id"|"userName"'; then
    print_pass "Created IVIA user: ${username}"
  else
    print_fail "Create IVIA user: ${username}" \
      "Response: ${response} — Check IVIA admin logs: kubectl -n verify-access logs -l app=isvaop"
  fi
}

create_ivia_user "oscar"   "${OSCAR_PASSWORD}"   "Oscar Medina"   "oscar@cdlbank.example"
create_ivia_user "adriana" "${ADRIANA_PASSWORD}" "Adriana Medina" "adriana@cdlbank.example"

#-------------------------------------------------------------------------------
# Step 5: Update UC2 OAuth client redirect_uri to ALB hostname
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}--- Step 5: Update agent-uc2 redirect_uri ---${NC}"

# GET current client config
current_client=$(ivia_curl GET "/mga/sps/oauth/oauth20/clients/${UC2_CLIENT_ID}" 2>/dev/null || true)

if echo "$current_client" | grep -q "\"${REDIRECT_URI}\""; then
  print_pass "agent-uc2 redirect_uri already set to ${REDIRECT_URI} — skipping"
else
  # PATCH: update redirect_uris
  patch_payload=$(cat <<JSON
{
  "redirect_uris": ["${REDIRECT_URI}"]
}
JSON
)
  patch_response=$(ivia_curl PATCH "/mga/sps/oauth/oauth20/clients/${UC2_CLIENT_ID}" "${patch_payload}" 2>&1)
  if echo "$patch_response" | grep -q "\"${REDIRECT_URI}\""; then
    print_pass "agent-uc2 redirect_uri updated to ${REDIRECT_URI}"
  else
    print_fail "Update agent-uc2 redirect_uri" \
      "Response: ${patch_response} — Verify agent-uc2 client exists in IVIA. Terraform isva_config component must be deployed first."
  fi
fi

#-------------------------------------------------------------------------------
# Step 6: Verification
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}--- Step 6: Verification ---${NC}"

# Verify agent-uc2 config
client_verify=$(ivia_curl GET "/mga/sps/oauth/oauth20/clients/${UC2_CLIENT_ID}" 2>/dev/null || true)
if echo "$client_verify" | grep -q "\"${REDIRECT_URI}\""; then
  print_pass "Verified: agent-uc2 redirect_uri = ${REDIRECT_URI}"
else
  print_fail "Verify agent-uc2 redirect_uri" \
    "GET /mga/sps/oauth/oauth20/clients/agent-uc2 did not return expected redirect URI ${REDIRECT_URI}"
fi

# Verify Oscar exists
oscar_verify=$(ivia_curl GET "/mga/sps/mga/user/mgmt/users/oscar" 2>/dev/null || true)
if echo "$oscar_verify" | grep -q '"userName"'; then
  print_pass "Verified: IVIA user 'oscar' exists"
else
  print_fail "Verify IVIA user 'oscar'" \
    "GET /mga/sps/mga/user/mgmt/users/oscar returned unexpected response"
fi

# Verify Adriana exists
adriana_verify=$(ivia_curl GET "/mga/sps/mga/user/mgmt/users/adriana" 2>/dev/null || true)
if echo "$adriana_verify" | grep -q '"userName"'; then
  print_pass "Verified: IVIA user 'adriana' exists"
else
  print_fail "Verify IVIA user 'adriana'" \
    "GET /mga/sps/mga/user/mgmt/users/adriana returned unexpected response"
fi

# print_summary is called automatically by the EXIT trap in common-checks.sh
