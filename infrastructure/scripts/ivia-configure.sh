#!/usr/bin/env bash
#
# ivia-configure.sh — Verify IVIA OIDC Provider is serving and configured
# correctly. CONTEXT exit-gate command for Phase 7:
#
#   kubectl exec deploy/iviawrprp1 -- curl -sk \
#     https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration
#
# Asserts the response JSON contains:
#   - issuer
#   - backchannel_authentication_endpoint  (CIBA)
#   - pushed_authorization_request_endpoint (PAR)
#   - registration_endpoint
#
# Also asserts iviawrprp1 was restarted after autoconf publish
# (RESEARCH Pitfall 6 — WRP backoff on stale snapshot pull).
#
# Idempotent. Safe to re-run.

set -euo pipefail

IVIA_NS="verify-access"
WRP_DEPLOY="iviawrprp1"

# Source common color/log helpers if available (same pattern as sibling scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "${SCRIPT_DIR}/common-checks.sh" ] && . "${SCRIPT_DIR}/common-checks.sh"

print_info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
print_success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
print_warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
print_error()   { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; }

# --- 1. WRP pod Ready ---
if ! kubectl get deploy "${WRP_DEPLOY}" -n "${IVIA_NS}" >/dev/null 2>&1; then
  print_error "Deployment ${WRP_DEPLOY} not found in namespace ${IVIA_NS}"
  exit 1
fi
ready=$(kubectl get deploy "${WRP_DEPLOY}" -n "${IVIA_NS}" -o jsonpath='{.status.readyReplicas}')
if [ "${ready:-0}" -lt 1 ]; then
  print_error "Deployment ${WRP_DEPLOY} has 0 ready replicas — autoconf may not have completed"
  exit 1
fi
print_success "Deployment ${WRP_DEPLOY}: ${ready}/1 Ready"

# --- 2. Cycle the WRP pod so it pulls the published autoconf snapshot ---
# The autoconf Job imports junctions/stanzas AND the OscarVault-branded login
# page into the LMI config, then calls deploy_pending_changes. In container mode
# IVIA reports "server needs restarting" but does NOT restart the WRP itself
# (restart_instance is gated on is_docker()==False; container.k8s_deployments
# auto-restart is disabled — SDK 0.3.34 bug). A running WRP keeps serving its
# stale boot-time snapshot until its pod is recreated and config-pulls again.
#
# We DELETE the pod (not `kubectl rollout restart`): rollout restart patches the
# deployment's pod-template `restartedAt` annotation, which Terraform manages and
# would then report as perpetual drift. Deleting the pod leaves the deployment
# spec untouched — the ReplicaSet recreates it, the fresh pod config-pulls the
# published snapshot, and `terraform plan` stays clean. Idempotent.
print_info "Cycling ${WRP_DEPLOY} pod to pull the published autoconf snapshot..."
kubectl delete pod -n "${IVIA_NS}" -l app=iviawrprp1 --wait=true
# Wait for the ReplicaSet's replacement pod to become Ready (poll past the brief
# gap where no pod exists yet).
for _ in $(seq 1 60); do
  ready=$(kubectl get pods -n "${IVIA_NS}" -l app=iviawrprp1 \
    -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null)
  [ "${ready}" = "true" ] && break
  sleep 5
done
if [ "${ready:-}" != "true" ]; then
  print_error "${WRP_DEPLOY} replacement pod did not become Ready within 300s"
  exit 1
fi
print_success "${WRP_DEPLOY} pod recreated — now serving the latest published config"

# --- 2b. Verify the served login page is the OscarVault-branded build ---
WRP_POD=$(kubectl get pods -n "${IVIA_NS}" -l app=iviawrprp1 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
LOGIN_PATH="/var/pdweb/rp1/server-root/lib/management/C/login.html"
if kubectl exec -n "${IVIA_NS}" "${WRP_POD}" -- grep -q "OscarVault" "${LOGIN_PATH}" 2>/dev/null; then
  print_success "Login page is OscarVault-branded (management_root import served)"
else
  print_error "Login page is NOT branded — autoconf management_root import did not land. Fix: re-run terraform apply (autoconf Job) then re-run this script."
  exit 1
fi

# --- 3. OIDC discovery via WRP exec curl (CONTEXT exit gate) ---
print_info "Fetching OIDC discovery via kubectl exec deploy/${WRP_DEPLOY}..."
resp=$(kubectl exec -n "${IVIA_NS}" "deploy/${WRP_DEPLOY}" -- \
  curl -sk --max-time 15 \
  https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration)

if [ -z "${resp}" ]; then
  print_error "Empty response from OIDC discovery endpoint"
  exit 1
fi

# --- 4. Assert all four required keys ---
fail=0
for key in issuer backchannel_authentication_endpoint pushed_authorization_request_endpoint registration_endpoint; do
  val=$(printf '%s' "${resp}" | jq -r --arg k "${key}" '.[$k] // empty')
  if [ -n "${val}" ]; then
    print_success "${key} = ${val}"
  else
    print_error "${key} missing from OIDC discovery JSON"
    fail=1
  fi
done

if [ "${fail}" -ne 0 ]; then
  printf '\nFull response:\n%s\n' "${resp}"
  exit 1
fi

print_success "IVIA OIDC discovery exit gate passed."
