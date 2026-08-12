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
#   2. Vault config     — port-forward :8200, activate the oauth-resource-server
#                         Enterprise feature (idempotent, pre-reconcile), terraform
#                         apply vault-config/, then a deploy-time license-module
#                         gate (database+aws mounts + agent-registry/oauth respond —
#                         fails loud if the license is pki-only / lacks platform-standard)
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

#--- License-module gate remediation (Phase 9) ---------------------------------
# The Vault Enterprise binary gates secret engines by license MODULE: `pki-only`
# is a RESTRICTION that blocks database/aws/kv/transit; `platform-standard`
# bundles `agentic-iam`, which unlocks the Agent Registry + OAuth resource server.
# A wrong license silently breaks ALL credential vending, so the deploy-time gate
# fails loud with this single remediation string (09-CONTEXT Decision 1).
LICENSE_REMEDIATION="Vault Enterprise license MUST carry the 'platform-standard' module and MUST NOT carry 'pki-only'. Replace the license (VAULT_ENTERPRISE_LICENSE_PATH, default ~/Downloads/vault-ent.hclic — injected into the vault-ent-license secret) with a platform-standard .hclic, then re-run: bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init"

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

# Recovery hint printed when a terraform apply fails on an orphaned Vault mount
# and self-heal could not clear it (or the conflict was not an auth backend).
_vault_orphan_fix_hint() {
  info "Fix: 'path is already in use at <path>/' means a prior interrupted run left"
  info "     a Vault mount that is absent from this workspace's terraform state."
  info "     Inspect the auth mounts, unmount the orphan, then re-run tier 2:"
  info "       curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" http://127.0.0.1:8200/v1/sys/auth | jq 'keys'"
  info "       curl -sf -X DELETE -H \"X-Vault-Token: \$VAULT_TOKEN\" http://127.0.0.1:8200/v1/sys/auth/<path>"
  info "       bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init --skip-acme"
}

# Self-heal an interrupted prior run. Vault emits "path is already in use at
# <path>/" ONLY when terraform tries to CREATE a mount that already exists in
# Vault — which, by definition, means the mount is absent from this workspace's
# state (the apply created it, then the run died before the state write). The
# error message is itself the orphan signal. For each conflicting AUTH path that
# is present in GET /sys/auth, unmount it so the retry re-creates it. These auth
# backends are fully declarative (kubernetes/, jwt/) — terraform recreates them
# identically — so unmount+retry is non-destructive. Returns 0 if it unmounted
# at least one orphan (caller should retry apply), non-zero otherwise.
heal_orphan_auth_mounts() {
  local apply_log="$1" healed=false p conflicts auth_json
  conflicts=$(grep -oE 'path is already in use at [A-Za-z0-9_-]+/' "$apply_log" \
    | sed -E 's#.*at ([A-Za-z0-9_-]+)/#\1#' | sort -u)
  [[ -z "$conflicts" ]] && return 1

  auth_json=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    http://127.0.0.1:8200/v1/sys/auth 2>/dev/null || echo '{}')

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # Only heal auth-backend orphans — confirm the path is actually mounted under
    # sys/auth before deleting (a secrets-mount conflict is left to the Fix hint).
    if ! echo "$auth_json" | jq -e --arg k "${p}/" 'has($k)' >/dev/null 2>&1; then
      warn "Conflict path ${p}/ is not an auth backend (not in /sys/auth) — skipping self-heal"
      continue
    fi
    warn "Auth backend ${p}/ is orphaned (exists in Vault, absent from terraform state) — unmounting to recover"
    if curl -sf -X DELETE -H "X-Vault-Token: ${VAULT_TOKEN}" \
         "http://127.0.0.1:8200/v1/sys/auth/${p}" >/dev/null 2>&1; then
      ok "Unmounted orphaned auth backend ${p}/"
      healed=true
    else
      warn "Failed to unmount ${p}/ — manual recovery may be required"
    fi
  done <<< "$conflicts"

  [[ "$healed" == true ]]
}

# Activate the oauth-resource-server Enterprise feature BEFORE terraform reconciles
# the OAuth resource-server profile + agent registrations. Ordering matters: the
# vault_oauth_resource_server_config_profile resource depends on the activation
# flag (09-CONTEXT Decision 1). Activation flags are one-way and server-side
# idempotent, so an already-active re-run is SUCCESS, not failure.
#
# NOTE: deliberately NOT `curl -sf` — under `set -e` a non-2xx response from an
# already-active flag would abort the whole script and break the idempotency
# contract. Capture the HTTP code with `|| echo 000` and decide explicitly.
# Non-fatal on failure: the terraform apply below (and the post-apply license
# gate) is authoritative if the license genuinely lacks platform-standard.
activate_oauth_resource_server() {
  local url="http://127.0.0.1:8200/v1/sys/activation-flags/oauth-resource-server/activate"
  local body http_code
  body="$(mktemp)"
  http_code=$(curl -s -o "$body" -w '%{http_code}' -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
    ok "oauth-resource-server feature activated (or already active — idempotent)"
    rm -f "$body"
    return 0
  fi
  # Some builds answer an already-activated re-request with 400 + an explicit
  # message — treat that as idempotent success too.
  if grep -qiE 'already[ -]?activated|already been activated' "$body" 2>/dev/null; then
    ok "oauth-resource-server feature already activated (idempotent)"
    rm -f "$body"
    return 0
  fi
  warn "oauth-resource-server activation returned HTTP ${http_code} — the license may lack platform-standard/agentic-iam"
  warn "  ${LICENSE_REMEDIATION}"
  rm -f "$body"
  return 1
}

cleanup() {
  info "Cleaning up port-forwards..."
  [[ -n "${VAULT_PF_PID:-}" ]] && kill "$VAULT_PF_PID" 2>/dev/null || true
  [[ -n "${IVIA_PF_PID:-}" ]] && kill "$IVIA_PF_PID" 2>/dev/null || true
  [[ -n "${VAULT_ISSUER_PF_PID:-}" ]] && kill "$VAULT_ISSUER_PF_PID" 2>/dev/null || true
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

  # Activation ordering (09-CONTEXT Decision 1): enable the oauth-resource-server
  # Enterprise feature BEFORE terraform applies the profile + agent registrations,
  # since the profile resource depends on the activation flag. Idempotent and
  # non-fatal here — the terraform apply and the post-apply license gate below are
  # authoritative if the license is wrong.
  info "Activating oauth-resource-server feature (pre-reconcile, idempotent)..."
  activate_oauth_resource_server || true

  # Terraform init + apply
  info "Running terraform init..."
  if ! terraform -chdir="${VAULT_CONFIG_DIR}" init -input=false 2>&1 | tail -3; then
    fail "terraform init failed"
    record "vault_config" "FAIL"
    return 1
  fi

  info "Running terraform apply..."
  # Capture apply output (pipefail is set, so the pipeline reflects terraform's
  # exit, not tee's) so we can detect the "path is already in use" orphan signal
  # and self-heal an interrupted prior run before failing the deploy.
  local apply_log
  apply_log="$(mktemp)"
  if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1 | tee "$apply_log"; then
    ok "Vault configuration applied successfully"
  elif grep -q 'path is already in use' "$apply_log" && heal_orphan_auth_mounts "$apply_log"; then
    info "Retrying terraform apply after self-heal..."
    if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1; then
      ok "Vault configuration applied successfully (after self-heal)"
    else
      fail "terraform apply still failing after self-heal"
      _vault_orphan_fix_hint
      rm -f "$apply_log"
      record "vault_config" "FAIL"
      return 1
    fi
  else
    fail "terraform apply failed"
    grep -q 'path is already in use' "$apply_log" && _vault_orphan_fix_hint
    # License-module gate (fast path): a pki-only license makes Vault refuse the
    # database/aws/kv/transit mounts with "not supported by license", which is NOT
    # the orphan signal above — it lands here. Surface the platform-standard /
    # pki-only remediation LOUD instead of leaving the attendee a cryptic mount
    # error (09-CONTEXT Decision 1; threat T-09-07-01).
    if grep -q 'not supported by license' "$apply_log"; then
      fail "Vault refused a secret-engine mount — the license appears to be pki-only (or lacks platform-standard)."
      fail "  ${LICENSE_REMEDIATION}"
    fi
    rm -f "$apply_log"
    record "vault_config" "FAIL"
    return 1
  fi
  rm -f "$apply_log"

  # Verify
  #
  # Each gate below captures its output into a variable and matches with a
  # herestring rather than piping into `grep -q`. Under `set -uo pipefail`,
  # `grep -q` exits on its first match and SIGPIPEs the upstream `jq`, so the
  # pipeline reports 141 and the gate reads FALSE even when the mount/policy is
  # present — a license-gate FAIL on a correctly licensed Vault.
  info "Verifying Vault configuration..."
  local verify_pass=true

  _vc_auth=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/auth 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'kubernetes/' <<<"${_vc_auth}"; then
    ok "Kubernetes auth backend: enabled"
  else
    fail "Kubernetes auth backend: not found"
    verify_pass=false
  fi

  # NOTE: the IVIA `jwt/` auth backend check was REMOVED here — Plan 05's native
  # cutover (09-CONTEXT decision (e)) RETIRED vault_jwt_auth_backend.ivia entirely
  # (UC2/UC3 present the OAuth JWT directly via X-Vault-Token, never traversing
  # auth/jwt). Asserting a retired backend would always FAIL. The OAuth resource
  # server surface is verified by the license-module gate below instead.

  # ---- Deploy-time license-module gate (Phase 9 — 09-CONTEXT Decision 1) --------
  # The Enterprise binary gates secret engines by license MODULE. Assert the
  # load-bearing surfaces are live and fail LOUD with remediation if not, instead
  # of a cryptic mount error reaching the attendee (threat T-09-07-01):
  #   - database/ + aws/ mounted  → proves `pki-only` is ABSENT (core engines).
  #   - agent-registry responds   → proves `agentic-iam` (bundled in
  #                                  platform-standard) is present.
  #   - oauth profile responds    → proves the feature is active + profile applied.
  # (Auth engines kubernetes/pki are module-independent — always available.)
  _vc_mounts_db=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'database/' <<<"${_vc_mounts_db}"; then
    ok "License gate: database/ secrets engine mounted (pki-only absent)"
  else
    fail "License gate: database/ secrets engine NOT mounted — license appears pki-only. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  _vc_mounts_aws=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'aws/' <<<"${_vc_mounts_aws}"; then
    ok "License gate: aws/ secrets engine mounted (pki-only absent)"
  else
    fail "License gate: aws/ secrets engine NOT mounted — license appears pki-only. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  # agent-registry responds → agentic-iam / platform-standard present. Read back
  # the uc1-agent registration the apply just reconciled (agent-registry/
  # registration/display-name/<name> — 09-DISCOVERY confirmed path).
  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
       http://127.0.0.1:8200/v1/agent-registry/registration/display-name/uc1-agent >/dev/null 2>&1; then
    ok "License gate: agent-registry responds (agentic-iam / platform-standard present)"
  else
    fail "License gate: agent-registry did not respond — license lacks platform-standard/agentic-iam. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  # oauth-resource-server config profile 'ivia' responds → feature active +
  # profile reconciled (sys/config/oauth-resource-server/<name> — reference contract).
  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
       http://127.0.0.1:8200/v1/sys/config/oauth-resource-server/ivia >/dev/null 2>&1; then
    ok "License gate: oauth-resource-server profile 'ivia' responds (feature active)"
  else
    fail "License gate: oauth-resource-server profile 'ivia' did not respond — activation/license issue. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  _vc_policies=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/policy 2>/dev/null | jq -r '.policies[]' 2>/dev/null || true)
  if grep -q 'uc1-readonly' <<<"${_vc_policies}"; then
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

  # There are TWO issuer values in this workshop and only one of them is
  # authoritative HERE:
  #
  #   (a) Vault's oauth-resource-server profile `issuer_id` — the value Vault
  #       actually validates UC2/UC3 tokens against. Written by this script's
  #       own Phase 2 apply from the tier-2 ivia_issuer output, so by the time
  #       Phase 3 runs it MUST already be the real ACME'd nip.io FQDN. This is
  #       what we gate on.
  #
  #   (b) iviaop's own OIDC discovery document — serves the pre-ACME
  #       `.invalid` placeholder until TIER 3 patches it. This script runs at
  #       deploy Step 8, i.e. during tier 2, so a placeholder here is EXPECTED
  #       and is not evidence that ACME failed. Gating on it produced a false
  #       "ACME did not complete. Re-run Step 7" on healthy deploys.
  #
  # (.invalid is an RFC 6761 reserved TLD — never a real issuer.)
  info "Verifying Vault's configured OAuth issuer..."
  local vault_issuer=""
  # Local port 18200, not 8200: Phase 2's forward has already been torn down and
  # an attendee may well have their own `port-forward ... 8200` open by now.
  # Binding a distinct port keeps this read from failing on a port clash and
  # emitting a warning that has nothing to do with the issuer.
  #
  # Same idempotency treatment Phase 2 gives 8200: an earlier run interrupted
  # between the fork and the kill below leaves an orphan holding 18200, the new
  # forward then fails to bind, and this phase WARNs about an issuer it never
  # actually read. Clear the port first, and register the PID in a script-scoped
  # variable so the EXIT trap reaps it even if we are interrupted mid-read.
  STALE_ISSUER_PF=$(lsof -tiTCP:18200 -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$STALE_ISSUER_PF" ]]; then
    info "Port 18200 already bound (PID(s): $(echo "$STALE_ISSUER_PF" | tr '\n' ' ')) — killing stale port-forward"
    # shellcheck disable=SC2086
    kill $STALE_ISSUER_PF 2>/dev/null || true
    sleep 1
  fi

  kubectl port-forward svc/vault 18200:8200 -n vault &>/dev/null &
  VAULT_ISSUER_PF_PID=$!
  sleep 3
  if kill -0 "$VAULT_ISSUER_PF_PID" 2>/dev/null; then
    vault_issuer=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
      http://127.0.0.1:18200/v1/sys/config/oauth-resource-server/ivia \
      2>/dev/null | jq -r '.data.issuer_id // empty' 2>/dev/null || echo "")
  fi
  kill "$VAULT_ISSUER_PF_PID" 2>/dev/null || true
  VAULT_ISSUER_PF_PID=""

  if [[ -z "$vault_issuer" ]]; then
    warn "Could not read Vault's oauth-resource-server issuer_id"
    warn "  Check: vault read sys/config/oauth-resource-server/ivia"
    record "ivia_verify" "WARN"
  elif [[ "$vault_issuer" == *".invalid"* ]]; then
    warn "Vault's OAuth issuer_id is a pre-ACME placeholder: ${vault_issuer}"
    warn "  Vault validates UC2/UC3 tokens against this value, so a placeholder"
    warn "  here means ACME (deploy Step 7) did not complete. Re-run Step 7:"
    warn "    bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init"
    record "ivia_verify" "WARN"
  else
    ok "Vault OAuth issuer_id: ${vault_issuer}"
    record "ivia_verify" "PASS"
  fi

  # iviaop discovery — informational only (see (b) above).
  local issuer
  issuer=$(kubectl exec -n verify-access deploy/iviawrprp1 -- \
    curl -sk --max-time 15 \
    https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration \
    2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")

  if [[ -z "$issuer" ]]; then
    info "iviaop OIDC discovery not responding yet — IVIA may still be initializing (informational)"
  elif [[ "$issuer" == *".invalid"* ]]; then
    info "iviaop discovery issuer: ${issuer} (placeholder — expected until tier 3 patches it)"
  else
    info "iviaop discovery issuer: ${issuer}"
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
