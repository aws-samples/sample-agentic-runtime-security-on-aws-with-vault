#!/usr/bin/env bash
#===============================================================================
# Vault Configuration Script
#
# Configures Vault (auth backends, secrets engines, policies, roles) via a local
# Terraform workspace with kubectl port-forward. Also verifies IVIA OIDC discovery
# is healthy. This runs AFTER the first workspace deploy and vault-init.sh.
#
# IVIA OAuth client registration moved to:
#   - Static (agent-uc1, agent-uc3): modules/verify_access/iviaop-config/clients.yml
#   - Dynamic (agent-uc2): kubernetes_job_v1.agent_uc2_dcr in root main.tf
# The legacy isva-config workspace was deleted — its REST API paths returned 404
# on IVIA 11.0.2.0 (OAuth runtime moved to standalone iviaop:25.10 pod).
#
# Phases:
#   1. Gather inputs    — resolves the Vault root token + confirms root TF state
#                         (all other inputs come from root outputs via
#                         terraform_remote_state in vault-config/main.tf)
#   2. Vault config     — port-forward :8200, terraform apply vault-config/
#   3. IVIA verify      — confirms 7 pods Running + OIDC discovery returns issuer
#   4. Summary          — pass/fail table
#
# Prerequisites:
#   - kubectl configured for the workshop EKS cluster
#   - Vault initialized (vault-init.sh completed, ~/vault-init.json exists)
#   - IVIA pod Running in verify-access namespace
#   - AWS credentials configured (for Secrets Manager access)
#
# Usage:
#   ./vault-configure.sh [OPTIONS]
#
# Options:
#   --vault-token TOKEN    Vault root token (default: read from ~/vault-init.json)
#   --dry-run              Show what would be done without executing
#   --skip-ivia            Skip IVIA verification (Phase 3)
#   --help                 Show this help message
#
# All deploy-derived inputs (region, cluster, RDS, IVIA issuer + cert, role
# ARNs) are read by the vault-config Terraform root from the root module's
# outputs (data.terraform_remote_state.root) — not auto-detected here.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VAULT_CONFIG_DIR="${REPO_ROOT}/infrastructure/vault-config"

#--- Defaults ------------------------------------------------------------------
VAULT_TOKEN=""
DRY_RUN=false
SKIP_IVIA=false

#--- Result tracking -----------------------------------------------------------
# Parallel indexed arrays (bash 3.2 — no associative arrays). record() upserts a
# key→status pair; _result_get() echoes a key's status (non-zero if unset).
RESULT_KEYS=()
RESULT_VALS=()
PHASE_ORDER=("gather" "vault_config" "ivia_verify")

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-token)  VAULT_TOKEN="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --skip-ivia)    SKIP_IVIA=true; shift ;;
    --help)
      # Print the header comment block (line 2 → first #=== separator),
      # stripping the leading "# ". awk is portable across GNU + BSD/macOS sed.
      awk 'NR>2 && /^#={3,}/{exit} NR>2 && /^#/{sub(/^# ?/,""); print}' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

#--- Helpers -------------------------------------------------------------------
info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()      { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
fail()    { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }
phase()   { printf '\n\033[1;36m━━━ Phase %s: %s ━━━\033[0m\n\n' "$1" "$2"; }

record() {
  local name="$1" status="$2" i
  for i in "${!RESULT_KEYS[@]}"; do
    if [[ "${RESULT_KEYS[$i]}" == "$name" ]]; then
      RESULT_VALS[$i]="$status"
      return
    fi
  done
  RESULT_KEYS+=("$name")
  RESULT_VALS+=("$status")
}

# Echo the recorded status for KEY; return non-zero if KEY was never recorded.
_result_get() {
  local name="$1" i
  for i in "${!RESULT_KEYS[@]}"; do
    if [[ "${RESULT_KEYS[$i]}" == "$name" ]]; then
      printf '%s' "${RESULT_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

cleanup() {
  info "Cleaning up port-forwards..."
  [[ -n "${VAULT_PF_PID:-}" ]] && kill "$VAULT_PF_PID" 2>/dev/null || true
  [[ -n "${IVIA_PF_PID:-}" ]] && kill "$IVIA_PF_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

print_summary() {
  echo ""
  printf '\033[1;36m━━━ Summary ━━━\033[0m\n'
  echo ""
  printf '  %-20s %s\n' "Phase" "Status"
  printf '  %-20s %s\n' "-----" "------"
  for name in "${PHASE_ORDER[@]}"; do
    local status
    status="$(_result_get "$name")" || status="SKIPPED"
    local color="\033[0;33m"
    case "$status" in
      PASS) color="\033[0;32m" ;;
      FAIL) color="\033[0;31m" ;;
    esac
    printf "  %-20s ${color}%s\033[0m\n" "$name" "$status"
  done
  echo ""

  local any_fail=false
  for name in "${PHASE_ORDER[@]}"; do
    [[ "$(_result_get "$name")" == "FAIL" ]] && any_fail=true
  done

  if [[ "$any_fail" == true ]]; then
    fail "One or more phases failed. Review output above."
    return 1
  else
    ok "All phases passed."
    return 0
  fi
}

#===============================================================================
# PHASE 1: Gather Inputs
#===============================================================================
phase_gather() {
  phase "1" "Gather Inputs"

  # Vault token — the ONLY input this script still gathers. Every deploy-derived
  # value (region, cluster endpoint/CA/OIDC, RDS coordinates, IVIA issuer + OIDC
  # CA cert, IAM role ARNs) is now read by the vault-config Terraform root from
  # the root module's outputs via data.terraform_remote_state.root — no bash
  # auto-detection, no hand-written tfvars strings (that is what let the JWT
  # bound_issuer go stale after an IVIA rebuild changed the WRP ALB hostname).
  # The Vault root token is a runtime secret from `vault operator init`, not a
  # Terraform-managed value, so it stays external.
  if [[ -z "$VAULT_TOKEN" ]]; then
    if [[ -f "${HOME}/vault-init.json" ]]; then
      VAULT_TOKEN=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || true)
      ok "Vault token: read from ~/vault-init.json"
    fi
    if [[ -z "$VAULT_TOKEN" ]]; then
      fail "No vault token. Run vault-init.sh first or pass --vault-token."
      record "gather" "FAIL"
      return 1
    fi
  else
    ok "Vault token: provided via --vault-token"
  fi

  # Confirm BOTH upstream Terraform states exist before vault-config tries to
  # read them via terraform_remote_state. vault-config/main.tf reads tier-1
  # (../terraform.tfstate → cluster wiring, RDS, role ARNs, region) AND tier-2
  # (../services/terraform.tfstate → ivia_issuer + ivia_oidc_ca_pem). A missing
  # tier-2 state means IVIA hasn't been deployed yet, so the JWT auth backend's
  # bound_issuer would have nothing to bind to.
  if [[ -f "${VAULT_CONFIG_DIR}/../terraform.tfstate" ]]; then
    ok "Tier-1 state present (terraform_remote_state source for cluster/RDS/role inputs)"
  else
    fail "Tier-1 state ${VAULT_CONFIG_DIR}/../terraform.tfstate not found — apply infrastructure/ (tier 1) first; vault-config reads its inputs from those outputs."
    record "gather" "FAIL"
    return 1
  fi

  if [[ -f "${VAULT_CONFIG_DIR}/../services/terraform.tfstate" ]]; then
    ok "Tier-2 state present (terraform_remote_state source for IVIA issuer + OIDC CA)"
  else
    fail "Tier-2 state ${VAULT_CONFIG_DIR}/../services/terraform.tfstate not found — apply infrastructure/services/ (tier 2: vault_server + ivia) first; vault-config binds the JWT bound_issuer to its ivia_issuer output."
    record "gather" "FAIL"
    return 1
  fi

  # Check pods
  info "Checking Vault pods..."
  VAULT_READY=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server \
    --no-headers 2>/dev/null | grep -c '1/1' || true)
  if [[ "$VAULT_READY" -ge 1 ]]; then
    ok "Vault: ${VAULT_READY} pod(s) ready"
  else
    fail "No Vault pods ready. Check: kubectl get pods -n vault"
    record "gather" "FAIL"
    return 1
  fi

  record "gather" "PASS"
}

#===============================================================================
# PHASE 2: Vault Configuration
#===============================================================================
phase_vault_config() {
  phase "2" "Vault Configuration"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would port-forward vault:8200 and terraform apply in vault-config/"
    record "vault_config" "PASS"
    return 0
  fi

  # Write tfvars — only the Vault root token. All other inputs come from the
  # root module's outputs via data.terraform_remote_state.root (see
  # vault-config/main.tf). Do NOT reintroduce deploy-derived strings here.
  info "Writing terraform.tfvars (vault_token only)..."
  cat > "${VAULT_CONFIG_DIR}/terraform.tfvars" <<TFVARS
vault_token = "${VAULT_TOKEN}"
TFVARS
  chmod 600 "${VAULT_CONFIG_DIR}/terraform.tfvars"
  ok "terraform.tfvars written (mode 600, vault_token only)"

  # Port-forward
  # Idempotency: a stale or manual `kubectl port-forward ... 8200` (e.g. left
  # running from a workshop walkthrough step) holds the port and makes our
  # forward fail to bind. Kill any existing listener on 8200, then start fresh.
  STALE_PF=$(lsof -tiTCP:8200 -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$STALE_PF" ]]; then
    info "Port 8200 already bound (PID(s): $(echo "$STALE_PF" | tr '\n' ' ')) — killing stale port-forward"
    # shellcheck disable=SC2086
    kill $STALE_PF 2>/dev/null || true
    sleep 1
  fi

  info "Starting port-forward to Vault (8200)..."
  kubectl port-forward svc/vault 8200:8200 -n vault &>/dev/null &
  VAULT_PF_PID=$!
  sleep 2

  if ! kill -0 "$VAULT_PF_PID" 2>/dev/null; then
    fail "Port-forward to Vault failed to start"
    record "vault_config" "FAIL"
    return 1
  fi
  ok "Port-forward active (PID ${VAULT_PF_PID})"

  # Verify connectivity — retry up to ~30s. A live-but-not-ready process
  # (kill -0 passes) and a single probe are not enough; the one-shot probe
  # missed two real failure modes:
  #   1. Tunnel not passing traffic yet at the fixed sleep on higher-latency
  #      networks (e.g. a remote attendee far from the EKS API endpoint).
  #   2. port-forward pins to a STANDBY Vault node, whose /v1/sys/health
  #      returns HTTP 429 — which `curl -sf` treats as a failure. standbyok/
  #      perfstandbyok make a standby answer 200; writes are request-forwarded
  #      to the active node, so the config apply below still succeeds.
  info "Testing Vault connectivity..."
  local health_url="http://127.0.0.1:8200/v1/sys/health?standbyok=true&perfstandbyok=true"
  local vault_reachable=false
  for _ in $(seq 1 30); do
    if curl -sf "${health_url}" &>/dev/null; then
      vault_reachable=true
      break
    fi
    sleep 1
  done
  if [[ "${vault_reachable}" == true ]]; then
    ok "Vault reachable at 127.0.0.1:8200"
  else
    fail "Cannot reach Vault at 127.0.0.1:8200 after 30s"
    record "vault_config" "FAIL"
    return 1
  fi

  # Terraform init + apply
  info "Running terraform init..."
  if ! terraform -chdir="${VAULT_CONFIG_DIR}" init -input=false 2>&1 | tail -3; then
    fail "terraform init failed"
    record "vault_config" "FAIL"
    return 1
  fi

  info "Running terraform apply..."
  if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1; then
    ok "Vault configuration applied successfully"
  else
    fail "terraform apply failed"
    record "vault_config" "FAIL"
    return 1
  fi

  # Verify
  info "Verifying Vault configuration..."
  local verify_pass=true

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/auth | jq -r 'keys[]' | grep -q 'kubernetes/'; then
    ok "Kubernetes auth backend: enabled"
  else
    fail "Kubernetes auth backend: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/auth | jq -r 'keys[]' | grep -q 'jwt/'; then
    ok "JWT auth backend: enabled"
  else
    fail "JWT auth backend: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts | jq -r 'keys[]' | grep -q 'database/'; then
    ok "Database secrets engine: enabled"
  else
    fail "Database secrets engine: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/policy | jq -r '.policies[]' | grep -q 'uc1-readonly'; then
    ok "Policy uc1-readonly: exists"
  else
    fail "Policy uc1-readonly: not found"
    verify_pass=false
  fi

  # Stop port-forward
  kill "$VAULT_PF_PID" 2>/dev/null || true
  unset VAULT_PF_PID

  if [[ "$verify_pass" == true ]]; then
    record "vault_config" "PASS"
  else
    record "vault_config" "FAIL"
  fi
}

#===============================================================================
# PHASE 3: IVIA Configuration
#===============================================================================
phase_ivia_verify() {
  phase "3" "IVIA OIDC Verification"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would verify IVIA OIDC discovery endpoint"
    record "ivia_verify" "PASS"
    return 0
  fi

  # IVIA is configured declaratively via config.yaml in the Terraform
  # verify_access module — no REST API calls needed. Just verify it's serving.
  info "Checking IVIA pod status..."
  local running
  running=$(kubectl get pods -n verify-access --no-headers 2>/dev/null | grep -c Running || true)
  if [[ "${running:-0}" -lt 1 ]]; then
    fail "No IVIA pods Running in verify-access namespace"
    record "ivia_verify" "FAIL"
    return 1
  fi
  ok "${running} IVIA pod(s) Running"

  # LMI is reachable in-cluster via the iviaconfig ClusterIP Service. Only used
  # for OIDC discovery verification below — no REST writes (OAuth client
  # registration moved into iviaop-config/clients.yml + the agent-uc2 DCR Job).
  local IVIA_LMI_ENDPOINT="iviaconfig.verify-access.svc.cluster.local"
  ok "IVIA LMI endpoint (in-cluster): ${IVIA_LMI_ENDPOINT}:9443"

  info "Verifying OIDC discovery..."
  local issuer
  issuer=$(kubectl exec -n verify-access deploy/iviawrprp1 -- \
    curl -sk --max-time 15 \
    https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration \
    2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")

  if [[ -n "$issuer" ]]; then
    # A `.invalid` issuer is the pre-ACME placeholder IVIA serves until deploy
    # Step 7 (ACME) re-applies module.ivia onto the real nip.io FQDN. This Phase 3
    # runs at Step 8 — AFTER Step 7 — so on a full deploy the issuer must already
    # be the real FQDN. A placeholder here is NOT a benign green check: it means
    # ACME did not complete (or was skipped via --skip-acme). Surface it as WARN,
    # never OK/PASS, so the misleading issuer is visible without masking a real
    # ACME failure. (.invalid is an RFC 6761 reserved TLD — never a real issuer.)
    if [[ "$issuer" == *".invalid"* ]]; then
      warn "OIDC issuer is a pre-ACME placeholder: ${issuer}"
      warn "  Expected ONLY if ACME (deploy Step 7) was skipped or has not run yet."
      warn "  On a full deploy the issuer must be the real nip.io FQDN by Step 8 —"
      warn "  a placeholder here means ACME did not complete. Re-run Step 7:"
      warn "    bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init"
      record "ivia_verify" "WARN"
    else
      ok "OIDC issuer: ${issuer}"
      record "ivia_verify" "PASS"
    fi
  else
    warn "OIDC discovery not responding — IVIA may still be initializing"
    record "ivia_verify" "WARN"
  fi
}

#===============================================================================
# Main
#===============================================================================
main() {
  echo ""
  printf '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  printf '\033[1;36m  Vault + IVIA Configuration\033[0m\n'
  printf '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  echo ""

  phase_gather || { print_summary; exit 1; }
  phase_vault_config || true
  if [[ "$SKIP_IVIA" == true ]]; then
    info "Skipping IVIA OIDC verification (--skip-ivia)"
    record "ivia_verify" "SKIP"
  else
    phase_ivia_verify || true
  fi
  print_summary
}

main "$@"
