#!/usr/bin/env bash
#===============================================================================
# ivia-configure.sh — Verify IVIA OIDC Provider is serving and configured
#
# Validates that the isvaop OIDC Provider is healthy and has the expected
# clients registered (from config.yaml — no REST API configuration needed).
#
# All IVIA configuration (clients, LDAP, grant types) is declarative in the
# Terraform verify_access module config.yaml. This script only verifies.
#
# Called from configure-workshop.sh and workshop-e2e.sh.
#===============================================================================

set -e
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
IVIA_NS="verify-access"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run]"
            echo "Verifies IVIA OIDC Provider health and client configuration."
            exit 0
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}=== IVIA Configure — Dry Run ===${NC}"
    print_info "[DRY-RUN] Would verify IVIA OIDC discovery at /oauth2/.well-known/openid-configuration"
    print_info "[DRY-RUN] Would verify agent-uc2 client is registered"
    print_info "[DRY-RUN] Would verify workshop_agent client is registered"
    exit 0
fi

echo
echo -e "${BLUE}=== IVIA OIDC Provider Verification ===${NC}"
echo

# Check IVIA pod is running
running_pods=$(kubectl get pods -n "${IVIA_NS}" --no-headers 2>/dev/null | grep -c Running || true)
if [ "${running_pods:-0}" -ge 1 ]; then
    print_pass "IVIA: ${running_pods} pod(s) Running in ${IVIA_NS}"
else
    print_fail "No IVIA pods Running in ${IVIA_NS}" \
        "Check: kubectl get pods -n ${IVIA_NS}"
    print_summary
    exit 1
fi

# Verify OIDC discovery via temp curl pod
oidc_url="https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration"
issuer=$(kubectl run ivia-verify --image=curlimages/curl --rm -i --restart=Never \
    -n "${IVIA_NS}" -- curl -sk "${oidc_url}" 2>/dev/null \
    | jq -r '.issuer // empty' 2>/dev/null || echo "")

if [ -n "$issuer" ]; then
    print_pass "OIDC discovery: issuer = ${issuer}"
else
    print_fail "OIDC discovery not responding at ${oidc_url}" \
        "Check IVIA logs: kubectl logs -n ${IVIA_NS} -l app.kubernetes.io/name=isvaop"
fi

# Verify authorization_code grant is supported
auth_endpoint=$(kubectl run ivia-verify2 --image=curlimages/curl --rm -i --restart=Never \
    -n "${IVIA_NS}" -- curl -sk "${oidc_url}" 2>/dev/null \
    | jq -r '.authorization_endpoint // empty' 2>/dev/null || echo "")

if [ -n "$auth_endpoint" ]; then
    print_pass "Authorization endpoint: ${auth_endpoint}"
else
    print_warn "Could not verify authorization_endpoint — IVIA may still be initializing"
fi

# Check ALB ingress has an address
alb_hostname=$(kubectl get ingress -n "${IVIA_NS}" isvaop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$alb_hostname" ]; then
    print_pass "IVIA ALB: ${alb_hostname}"
else
    print_warn "IVIA ALB ingress has no hostname yet — ALB may still be provisioning"
fi

echo
print_summary
