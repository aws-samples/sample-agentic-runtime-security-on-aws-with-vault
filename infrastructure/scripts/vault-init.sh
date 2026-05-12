#!/usr/bin/env bash
#===============================================================================
# Vault Initialization Script — Two-Phase Bootstrap (Phase 1)
#
# Run after the first workspace deploy (Waves 0-4) succeeds and Vault pods are
# Running. Initializes Vault via `vault operator init`, saves the root token
# and recovery keys to ~/vault-init.json, and prints next steps.
#
# Idempotent: if Vault is already initialized, prints the existing status
# and reminds the user to run vault-enable-config.sh for Phase 2.
#
# Prerequisites:
#   - kubectl configured for the workshop EKS cluster
#   - Vault pods 1/1 Running in the vault namespace
#
# Usage:
#   ./vault-init.sh [OPTIONS]
#
# Options:
#   --output FILE    Save init output to FILE (default: ~/vault-init.json)
#   --namespace NS   Vault namespace (default: vault)
#   --dry-run        Show what would be done without executing
#   --help           Show this help message
#===============================================================================
set -euo pipefail

#--- Defaults ------------------------------------------------------------------
OUTPUT_FILE="${HOME}/vault-init.json"
VAULT_NS="vault"
VAULT_POD="vault-0"
DRY_RUN=false

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)     OUTPUT_FILE="$2"; shift 2 ;;
    --namespace)  VAULT_NS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --help)
      sed -n '2,/^#=====/{ /^#/s/^# \{0,1\}//p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

#--- Helpers -------------------------------------------------------------------
info()  { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

#--- Pre-flight checks ---------------------------------------------------------
info "Checking kubectl connectivity..."
kubectl get namespace "${VAULT_NS}" &>/dev/null \
  || fail "Namespace '${VAULT_NS}' not found. Is kubectl configured for the workshop cluster?"

info "Checking Vault pods..."
READY_COUNT=$(kubectl get pods -n "${VAULT_NS}" -l app.kubernetes.io/name=vault,component=server \
  --no-headers 2>/dev/null | grep -c '1/1' || true)

if [[ "${READY_COUNT}" -lt 1 ]]; then
  PODS=$(kubectl get pods -n "${VAULT_NS}" --no-headers 2>/dev/null || true)
  fail "No Vault server pods are 1/1 Running in namespace '${VAULT_NS}'.
  Current pods:
${PODS}
  Fix: Ensure the first workspace run (enable_vault_config=false) succeeded and Vault pods are scheduling.
  Check: kubectl describe statefulset vault -n ${VAULT_NS}"
fi
ok "${READY_COUNT} Vault server pod(s) running"

#--- Check if already initialized ----------------------------------------------
info "Checking Vault initialization status..."
VAULT_STATUS=$(kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- vault status -format=json 2>/dev/null || true)

if echo "${VAULT_STATUS}" | grep -q '"initialized": true'; then
  SEALED=$(echo "${VAULT_STATUS}" | grep -o '"sealed": [a-z]*' | head -1)
  ok "Vault is already initialized (${SEALED})"

  if [[ -f "${OUTPUT_FILE}" ]]; then
    ok "Init output previously saved to ${OUTPUT_FILE}"
    ROOT_TOKEN=$(jq -r '.root_token // empty' "${OUTPUT_FILE}" 2>/dev/null || true)
    if [[ -n "${ROOT_TOKEN}" ]]; then
      info "Root token (from saved file): ${ROOT_TOKEN}"
    fi
  else
    warn "No saved init output at ${OUTPUT_FILE} — if you lost the root token, you need to use recovery keys."
  fi

  echo ""
  info "Next step: run ./vault-configure.sh to configure Vault auth backends and policies."
  exit 0
fi

#--- Dry run -------------------------------------------------------------------
if [[ "${DRY_RUN}" == true ]]; then
  info "[DRY RUN] Would execute: kubectl exec -n ${VAULT_NS} ${VAULT_POD} -- vault operator init -format=json"
  info "[DRY RUN] Would save output to: ${OUTPUT_FILE}"
  exit 0
fi

#--- Initialize Vault ----------------------------------------------------------
info "Initializing Vault..."
INIT_OUTPUT=$(kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- vault operator init -format=json 2>&1) \
  || fail "vault operator init failed:
${INIT_OUTPUT}"

echo "${INIT_OUTPUT}" > "${OUTPUT_FILE}"
chmod 600 "${OUTPUT_FILE}"
ok "Init output saved to ${OUTPUT_FILE} (mode 600)"

#--- Extract and display -------------------------------------------------------
ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')
RECOVERY_KEYS=$(echo "${INIT_OUTPUT}" | jq -r '.recovery_keys_b64[]')

echo ""
echo "============================================================"
echo "  VAULT INITIALIZED SUCCESSFULLY"
echo "============================================================"
echo ""
echo "  Root Token:  ${ROOT_TOKEN}"
echo ""
echo "  Recovery Keys (3-of-5 threshold):"
echo "${RECOVERY_KEYS}" | while read -r key; do
  echo "    ${key}"
done
echo ""
echo "  IMPORTANT: Store recovery keys securely — needed only if"
echo "  KMS auto-unseal becomes unavailable."
echo ""
echo "============================================================"
echo ""

#--- Verify unsealed -----------------------------------------------------------
info "Verifying Vault is unsealed (KMS auto-unseal)..."
VAULT_STATUS=$(kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- vault status -format=json 2>/dev/null || true)

if echo "${VAULT_STATUS}" | grep -q '"sealed": false'; then
  ok "Vault is unsealed via KMS auto-unseal"
else
  warn "Vault is still sealed — check KMS key permissions and Pod Identity association."
fi

#--- Summary -------------------------------------------------------------------
echo ""
info "Next step:"
echo "  Run ./vault-configure.sh to configure Vault auth backends, secrets engines,"
echo "  and policies via local Terraform apply with kubectl port-forward."
echo ""
echo "  Example:"
echo "    ./vault-configure.sh --vault-token ${ROOT_TOKEN}"
