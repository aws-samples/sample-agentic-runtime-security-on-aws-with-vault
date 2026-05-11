#!/usr/bin/env bash
#===============================================================================
# Vault Enable Config Script — Two-Phase Bootstrap (Phase 2)
#
# Run after vault-init.sh. Sets enable_vault_config=true in
# deployments.tfdeploy.hcl, commits, and pushes to main to trigger the
# second Stacks run that deploys vault_config + isva_config + uc1_agent.
#
# Idempotent: if enable_vault_config is already true, prints status and exits.
#
# Prerequisites:
#   - vault-init.sh completed successfully
#   - vault_token stored in HCP variable set
#   - Working directory is the repo root or infrastructure/
#
# Usage:
#   ./vault-enable-config.sh [OPTIONS]
#
# Options:
#   --dry-run    Show what would be done without executing
#   --help       Show this help message
#===============================================================================
set -euo pipefail

#--- Defaults ------------------------------------------------------------------
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_FILE="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
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
[[ -f "${DEPLOY_FILE}" ]] \
  || fail "deployments.tfdeploy.hcl not found at ${DEPLOY_FILE}"

#--- Check current state -------------------------------------------------------
CURRENT_VALUE=$(grep 'enable_vault_config' "${DEPLOY_FILE}" | grep -o 'true\|false' || true)

if [[ "${CURRENT_VALUE}" == "true" ]]; then
  ok "enable_vault_config is already true in deployments.tfdeploy.hcl"
  info "If the Stacks run hasn't been triggered yet, push to main."
  exit 0
fi

if [[ "${CURRENT_VALUE}" != "false" ]]; then
  fail "Could not find enable_vault_config in ${DEPLOY_FILE}.
  Fix: Add 'enable_vault_config = false' to the deployment inputs block."
fi

#--- Check vault-init.sh was run -----------------------------------------------
INIT_FILE="${HOME}/vault-init.json"
if [[ ! -f "${INIT_FILE}" ]]; then
  warn "~/vault-init.json not found — make sure you ran vault-init.sh first"
  warn "and stored vault_token in the HCP variable set before proceeding."
  read -rp "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

#--- Dry run -------------------------------------------------------------------
if [[ "${DRY_RUN}" == true ]]; then
  info "[DRY RUN] Would change enable_vault_config = false → true in:"
  info "          ${DEPLOY_FILE}"
  info "[DRY RUN] Would commit and push to main."
  exit 0
fi

#--- Update deployments.tfdeploy.hcl -------------------------------------------
info "Setting enable_vault_config = true..."
sed -i '' 's/enable_vault_config = false/enable_vault_config = true/' "${DEPLOY_FILE}"
ok "Updated ${DEPLOY_FILE}"

#--- Verify the change ---------------------------------------------------------
NEW_VALUE=$(grep 'enable_vault_config' "${DEPLOY_FILE}" | grep -o 'true\|false' || true)
[[ "${NEW_VALUE}" == "true" ]] \
  || fail "Substitution failed — enable_vault_config is '${NEW_VALUE}', expected 'true'"

#--- Commit and push -----------------------------------------------------------
info "Committing and pushing to main..."
cd "${REPO_ROOT}"

git add infrastructure/deployments.tfdeploy.hcl
git commit -m "feat(vault): enable vault_config for second Stacks deploy

Two-phase bootstrap Phase 2: Vault is initialized and vault_token is
stored in HCP variable set. Enable Wave 5-6 components (vault_config,
isva_config, uc1_agent)."

CURRENT_BRANCH=$(git branch --show-current)
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
  info "On branch '${CURRENT_BRANCH}' — merging to main..."
  git checkout main
  git merge "${CURRENT_BRANCH}" --no-edit
  git push origin main
  git checkout "${CURRENT_BRANCH}"
else
  git push origin main
fi

ok "Pushed to main — Stacks run will deploy vault_config + isva_config + uc1_agent"

#--- Summary -------------------------------------------------------------------
echo ""
info "Next steps:"
echo "  1. Approve the Stacks plan in HCP Terraform (within 15 min for K8s token TTL)"
echo "  2. Verify: kubectl get pods -n uc1"
echo "  3. Run: ./verify-uc1.sh"
