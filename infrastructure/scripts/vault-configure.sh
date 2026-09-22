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
  info "Fix: 'alias already exists for issuer and external_id' means a previous TLS"
  info "     host left OAuth entity aliases behind and one of them squats the issuer"
  info "     this run needs. List them and delete the ones whose mount_accessor is"
  info "     NOT oauth-resource-server_root_<the config_id below>, then re-run tier 2:"
  info "       vault read sys/config/oauth-resource-server/ivia   # -> config_id"
  info "       vault list identity/entity-alias/id"
  info "       vault delete identity/entity-alias/id/<alias-id>"
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

# Self-heal orphaned OAuth entity aliases. Vault enforces (issuer, external_id)
# UNIQUE per namespace — not (mount_accessor, name) — so a single stale alias is
# enough to make every alias write fail with "alias already exists for issuer and
# external_id in this namespace".
#
# They accumulate because nothing deletes them. The aliases are written with
# vault_generic_endpoint (the first-class vault_identity_entity_alias resource
# carries neither `issuer` nor `external_id`, which native OBO resolution needs),
# and that resource's state id is the literal collection path
# `identity/entity-alias` — Terraform cannot address an individual alias, so it
# has `disable_delete = true`. Destroying the oauth-resource-server profile does
# NOT cascade to the aliases bound to its accessor either. So every time the
# profile is replaced — which a TLS host change forces, because issuer_id is
# ForceNew — the previous generation is stranded in Vault forever.
#
# Harmless while each generation holds a distinct issuer. Fatal the moment an
# issuer value RECURS: the workshop's host names embed the ALB's IP, and an ALB
# that is re-created can be handed an address it held before. The stranded alias
# from that earlier generation then squats the exact (issuer, external_id) the
# new profile needs. Issue #5.
#
# What makes deletion safe is NOT merely that the alias sits on an accessor other
# than the live profile's. It is that the alias is one the WORKSHOP itself wrote —
# its name appears in the set this deploy's own Terraform outputs declare — AND it
# sits on an oauth-resource-server accessor that is not the profile this deploy
# binds. Both conditions are required, and the name condition is what bounds the
# blast radius: an OAuth alias this workshop never created is left alone whatever
# accessor carries it, so adding a second oauth-resource-server profile later
# cannot turn this sweep into a destroyer of someone else's identities.
# Kubernetes auth aliases are never touched — their accessors do not carry the
# oauth-resource-server_root_ prefix.
#
# Reads and deletes go through vault_exec (kubectl exec), NOT the 127.0.0.1:8200
# port-forward. A tunnel that never bound or died mid-run turned this whole sweep
# into a silent no-op, and the collision it exists to clear then surfaced as four
# unexplained 400s inside the apply — the one symptom this function was written to
# prevent. kubectl exec needs no local port, so there is no tunnel to lose.
#
# Runs UNCONDITIONALLY before the apply, not in response to an apply error. The
# squatter is removed before it can collide rather than recovered from after, and
# deleting an alias whose owning profile is gone is correct whether or not an
# apply has failed. On a cluster whose aliases are all current it finds nothing
# and is a no-op.
#
# Exit status is a HEALTH verdict, not a count of deletions:
#   0  the sweep did its job — including the ordinary case of finding nothing.
#   2  there is no oauth-resource-server profile yet, so there is nothing this
#      sweep could be about. That is the state of every FIRST deploy, and it is
#      not a fault. Distinguished from an unreadable Vault by probing `vault
#      status` — Vault answering while the profile is absent is a clean install.
#   1  the sweep could not carry out its job: Vault unreadable, aliases present
#      that Terraform declares nothing about, or a delete that failed.
# The previous version returned non-zero for an empty alias list — an ordinary
# no-op reported as a failure — which is precisely why the call site learned to
# swallow the status with `|| true` and stopped noticing real ones.
heal_orphan_oauth_aliases() {
  local deleted=0 failed=0 skipped=0 live_id live_accessor names alias_ids id acc name entry

  live_id=$(vault_exec "vault read -format=json sys/config/oauth-resource-server/ivia" \
    2>/dev/null | jq -r '.data.config_id // empty' 2>/dev/null || echo "")
  if [[ -z "$live_id" ]]; then
    if vault_exec "vault status -format=json" >/dev/null 2>&1; then
      info "No oauth-resource-server profile in Vault yet — nothing to sweep (first deploy)"
      return 2
    fi
    warn "Vault is unreadable — cannot identify the live OAuth profile, so no alias will be deleted"
    return 1
  fi
  live_accessor="oauth-resource-server_root_${live_id}"

  alias_ids=$(vault_exec "vault list -format=json identity/entity-alias/id" 2>/dev/null \
    | jq -r '.[]? // empty' 2>/dev/null || echo "")
  if [[ -z "$alias_ids" ]]; then
    info "No entity aliases in Vault — nothing to sweep"
    return 0
  fi

  # Pass 1 — find the aliases that sit on a DEAD oauth-resource-server profile.
  # An alias on the profile this deploy binds is current by definition, and an
  # alias belonging to any other auth method is none of this sweep's business.
  local candidates="" _tab
  _tab=$'\t'
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    entry=$(vault_exec "vault read -format=json identity/entity-alias/id/${id}" 2>/dev/null || echo "")
    acc=$(jq -r '.data.mount_accessor // empty' <<<"$entry" 2>/dev/null || echo "")
    name=$(jq -r '.data.name // empty' <<<"$entry" 2>/dev/null || echo "")
    case "$acc" in
      oauth-resource-server_root_*) ;;
      *) continue ;;
    esac
    [[ "$acc" == "$live_accessor" ]] && continue
    candidates="${candidates}${id}${_tab}${name}${_tab}${acc}"$'\n'
  done <<< "$alias_ids"

  if [[ -z "$candidates" ]]; then
    info "No orphaned OAuth entity aliases — every OAuth alias in Vault is already on the live profile"
    return 0
  fi

  # Only NOW does the expected set matter, and asking for it any earlier is a
  # deploy-stopping bug: `terraform output -json` answers {} with exit 0 when
  # vault-config has no state yet (fresh checkout, or state lost while the
  # cluster lives), so demanding a non-empty set up front aborts a phase that
  # had nothing to sweep in the first place.
  #
  # The identity names this workshop owns come from the same declaration the
  # gate below asserts against, so an identity added to the workshop is swept
  # and gated from one source.
  names=$(_workshop_oauth_expected_aliases | cut -f1)
  if [[ -z "$names" ]]; then
    warn "Orphaned OAuth aliases exist but terraform declares no OAuth identities — refusing to delete any alias"
    warn "  Expected human_entity_ids / agent_uc2_entity_id / uc3_actor_entity_id from"
    warn "  infrastructure/vault-config/outputs.tf. Deleting on an unknown expected set"
    warn "  would be deleting blind."
    return 1
  fi

  # Pass 2 — delete the ones this workshop owns by name. The name scope is a
  # blast-radius guard, not a correctness rule: an alias on a dead profile whose
  # name terraform no longer declares is LEFT IN PLACE and named in the log, so
  # an identity removed between generations is visible rather than silently
  # swept or silently ignored.
  while IFS=$'\t' read -r id name acc; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$name" <<<"$names"; then
      skipped=$(( skipped + 1 ))
      warn "  left alias ${id} (name ${name}) on dead profile ${acc} — terraform does not declare that identity"
      continue
    fi
    if vault_exec "vault delete identity/entity-alias/id/${id}" >/dev/null 2>&1; then
      deleted=$(( deleted + 1 ))
      # Name every deletion. An unauditable "deleted some" line cannot be checked
      # by a reviewer, and cannot be cited honestly in a status report.
      info "  deleted orphaned OAuth alias ${id} (name ${name}, dead profile accessor ${acc})"
    else
      failed=$(( failed + 1 ))
      warn "Failed to delete orphaned OAuth alias ${id} (name ${name}, accessor ${acc})"
    fi
  done <<< "$candidates"

  if (( deleted > 0 )); then
    ok "Deleted ${deleted} orphaned OAuth entity alias(es) whose oauth-resource-server profile this deploy no longer binds"
  else
    info "No orphaned OAuth entity aliases — every workshop alias is already on the live profile"
  fi
  if (( skipped > 0 )); then
    warn "${skipped} alias(es) on a dead profile were left in place because terraform no longer declares their identity"
  fi
  if (( failed > 0 )); then
    warn "${failed} orphaned alias(es) could not be deleted — the apply may still collide on (issuer, external_id)"
    return 1
  fi
  return 0
}

# The OAuth identities this workshop owns, as "<alias name>\t<entity id>" lines,
# read from Terraform's own outputs so that adding a human to the workshop does
# not silently narrow either the sweep above or the gate below. Empty output means
# the expected set is unknown — never that the set is empty.
_workshop_oauth_expected_aliases() {
  local tf_out
  tf_out=$(terraform -chdir="${VAULT_CONFIG_DIR}" output -json 2>/dev/null || echo '{}')
  jq -r '
      ((.human_entity_ids.value // {}) | to_entries[] | "\(.key)\t\(.value)"),
      (select(.agent_uc2_entity_id.value  != null) | "agent-uc2\t"  + .agent_uc2_entity_id.value),
      (select(.uc3_actor_entity_id.value  != null) | "uc3-actor\t"  + .uc3_actor_entity_id.value)
    ' <<<"$tf_out" 2>/dev/null || true
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

# ---- Vault verification reads run through `kubectl exec`, never the tunnel ----
#
# The port-forward is one long-lived tunnel shared by an entire phase. When it
# dies mid-verification, every remaining read fails with curl exit 7 ("could not
# connect") and this script reports the dead tunnel as a wrong Enterprise
# license. A real deploy failed exactly that way — see
# infrastructure/scripts/logs/tier2-alias-cleared-1786604400.log lines 523-525,
# where the gates called the agent-registry, the oauth profile and uc1-readonly
# missing seconds after terraform had refreshed those very objects over the same
# tunnel. curl tells the two apart even though the script cannot: a dead tunnel
# gives exit 7, while every genuine Vault fault (bad token, missing path, wrong
# license) gives 22.
#
# `kubectl exec` opens a fresh connection per read, so one failure cannot cascade
# into the rest of the gates. It is also the pattern test-vault-verify.sh already
# uses — it passed 13/13 on a cluster where these gates were failing. The tunnel
# is kept only for `terraform apply`, which genuinely needs a local endpoint.
#
# Reads are safe on any Ready pod: Raft standbys request-forward to the active
# node and answer all of these paths with 200 (measured on vault-0/1/2).
VAULT_EXEC_POD=""
vault_pod() {
  if [[ -z "$VAULT_EXEC_POD" ]] || ! kubectl get pod -n vault "$VAULT_EXEC_POD" &>/dev/null; then
    VAULT_EXEC_POD=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server \
      --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running" {print $1; exit}')
  fi
  [[ -n "$VAULT_EXEC_POD" ]] || return 1
  printf '%s' "$VAULT_EXEC_POD"
}

# vault_exec <vault-cli-command> — run a Vault CLI read inside a Vault pod.
# The token is exported inside the pod's throwaway `sh` so it never lands in the
# pod's process list under a separate `vault login`.
#
# It is `export VAULT_TOKEN=...; <cmd>` and NOT the shorter `VAULT_TOKEN=... <cmd>`
# prefix form: an assignment prefix is only valid before a SIMPLE command, so the
# prefix form makes the pod's busybox sh reject any compound command with
# "syntax error: unexpected \"do\"" — silently, since callers discard stderr. The
# export form accepts loops and pipelines, and is identical for simple commands.
vault_exec() {
  local pod
  pod="$(vault_pod)" || return 1
  kubectl exec -n vault "$pod" -- sh -c "export VAULT_TOKEN='${VAULT_TOKEN}'; $1"
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

  # Activation ordering (09-CONTEXT Decision 1): enable the oauth-resource-server
  # Enterprise feature BEFORE terraform applies the profile + agent registrations,
  # since the profile resource depends on the activation flag. Idempotent and
  # non-fatal here — the terraform apply and the post-apply license gate below are
  # authoritative if the license is wrong.
  info "Activating oauth-resource-server feature (pre-reconcile, idempotent)..."
  activate_oauth_resource_server || true

  # Sweep OAuth entity aliases left behind by oauth-resource-server profiles this
  # deploy no longer binds, BEFORE the apply writes this generation's aliases. A
  # stale alias holding the same (issuer, external_id) makes every alias write
  # fail, and the issuer recurs whenever a re-created ALB is handed an address it
  # held before (issue #5). No-op when every alias is current.
  #
  # The status is acted on rather than swallowed. `|| true` here was how a sweep
  # that could not run at all — the port-forward it used to read Vault through was
  # gone — became invisible, and the collision it exists to clear then arrived as
  # four unexplained 400s inside the apply. rc=2 is the clean-install case (no
  # profile yet) and is not a fault; rc=1 means the sweep could not do its job, and
  # the apply that follows would collide or fail on the same unreachable Vault, so
  # stopping here with the real reason beats failing later with the symptom.
  local _heal_rc=0
  heal_orphan_oauth_aliases || _heal_rc=$?
  if (( _heal_rc == 1 )); then
    fail "Could not sweep orphaned OAuth entity aliases before the apply"
    fail "  The apply writes identity/entity-alias entries that Vault rejects with 400"
    fail "  \"alias already exists for issuer and external_id\" when a stale generation"
    fail "  still holds them. Re-run once Vault is readable: ${BASH_SOURCE[0]}"
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
  # Capture apply output (pipefail is set, so the pipeline reflects terraform's
  # exit, not tee's) so we can detect the "path is already in use" orphan signal
  # and self-heal an interrupted prior run before failing the deploy.
  local apply_log
  apply_log="$(mktemp)"
  if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1 | tee "$apply_log"; then
    ok "Vault configuration applied successfully"
  elif grep -q 'path is already in use' "$apply_log" && heal_orphan_auth_mounts "$apply_log"; then
    # An interrupted prior run strands an auth MOUNT. Cleared non-destructively,
    # then the apply is retried. (The OAuth entity ALIAS class is swept before the
    # apply above, so it never reaches this error path.)
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
  # Reads go through vault_exec (kubectl exec), NOT the port-forward above — see
  # the helper's comment for why a shared tunnel turns one transport failure into
  # a phantom license error.
  #
  # Each gate below captures its output into a variable and matches with a
  # herestring rather than piping into `grep -q`. Under `set -uo pipefail`,
  # `grep -q` exits on its first match and SIGPIPEs the upstream `jq`, so the
  # pipeline reports 141 and the gate reads FALSE even when the mount/policy is
  # present — a license-gate FAIL on a correctly licensed Vault.
  info "Verifying Vault configuration..."
  local verify_pass=true

  _vc_auth=$(vault_exec "vault auth list -format=json" 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'kubernetes/' <<<"${_vc_auth}"; then
    ok "Kubernetes auth backend: enabled"
  else
    fail "Kubernetes auth backend: not found"
    verify_pass=false
  fi

  # NOTE: the IVIA `jwt/` auth backend check was REMOVED here — Plan 05's native
  # There is deliberately no vault_jwt_auth_backend resource in this config
  # (UC2/UC3 present the OAuth JWT directly via X-Vault-Token, never traversing
  # auth/jwt). Asserting a backend that must not exist would always FAIL. The OAuth resource
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
  _vc_mounts_db=$(vault_exec "vault secrets list -format=json" 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'database/' <<<"${_vc_mounts_db}"; then
    ok "License gate: database/ secrets engine mounted (pki-only absent)"
  else
    fail "License gate: database/ secrets engine NOT mounted — license appears pki-only. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  _vc_mounts_aws=$(vault_exec "vault secrets list -format=json" 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
  if grep -q 'aws/' <<<"${_vc_mounts_aws}"; then
    ok "License gate: aws/ secrets engine mounted (pki-only absent)"
  else
    fail "License gate: aws/ secrets engine NOT mounted — license appears pki-only. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  # agent-registry responds → agentic-iam / platform-standard present. Read back
  # the uc1-agent registration the apply just reconciled (agent-registry/
  # registration/display-name/<name> — 09-DISCOVERY confirmed path).
  if vault_exec "vault read -format=json agent-registry/registration/display-name/uc1-agent" \
       >/dev/null 2>&1; then
    ok "License gate: agent-registry responds (agentic-iam / platform-standard present)"
  else
    fail "License gate: agent-registry did not respond — license lacks platform-standard/agentic-iam. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  # oauth-resource-server config profile 'ivia' responds → feature active +
  # profile reconciled (sys/config/oauth-resource-server/<name> — reference contract).
  if vault_exec "vault read sys/config/oauth-resource-server/ivia" >/dev/null 2>&1; then
    ok "License gate: oauth-resource-server profile 'ivia' responds (feature active)"
  else
    fail "License gate: oauth-resource-server profile 'ivia' did not respond — activation/license issue. ${LICENSE_REMEDIATION}"
    verify_pass=false
  fi

  _vc_policies=$(vault_exec "vault policy list -format=json" 2>/dev/null | jq -r '.[]' 2>/dev/null || true)
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
# Reading issuer_id back off the profile proves nothing on its own: the apply a
# moment earlier WROTE that profile, so the value is true by construction. It
# stays true even when every entity-alias write in the same apply failed, which
# is exactly what happened when a recurring ALB IP let a stale alias squat the
# issuer — four 400s, and this phase still reported PASS.
#
# The thing that actually has to hold is on the ALIAS objects, not the profile:
# every identity the OAuth path resolves must have an alias bound to the LIVE
# profile's accessor and stamped with the live issuer. Without it, UC2/UC3 token
# validation fails at run time with "no alias found" even though the issuer reads
# correct here. Expected identities come from terraform's own outputs, so adding
# a human to the workshop does not silently narrow the gate. Issue #5.
assert_oauth_aliases_current() {
  local want_issuer="$1" live_id live_accessor expected found ent missing=0 n_expected n_found

  live_id=$(vault_exec "vault read -format=json sys/config/oauth-resource-server/ivia" \
    2>/dev/null | jq -r '.data.config_id // empty' 2>/dev/null || echo "")
  if [[ -z "$live_id" ]]; then
    # A gate that cannot read its subject must FAIL, never pass. Returning 0 here
    # would reproduce the exact defect this gate replaced: green while unverified.
    fail "Could not read the live oauth-resource-server config_id — OAuth aliases are UNVERIFIED"
    fail "  Vault unreachable, profile absent, or the token lacks access. Not a pass."
    return 1
  fi
  live_accessor="oauth-resource-server_root_${live_id}"

  # Same single declaration the sweep above deletes by, so the set this gate
  # asserts and the set the sweep is allowed to touch can never drift apart.
  expected=$(_workshop_oauth_expected_aliases)
  if [[ -z "$expected" ]]; then
    fail "No OAuth identity ids in terraform output — the alias gate cannot run"
    fail "  Expected human_entity_ids / agent_uc2_entity_id / uc3_actor_entity_id from"
    fail "  infrastructure/vault-config/outputs.tf. A gate that cannot read its expected"
    fail "  set must fail, not pass silently."
    return 1
  fi

  # One pass over Vault's aliases: name -> canonical_id, for the live accessor
  # at the live issuer only. Anything on a dead accessor is deliberately invisible
  # here, so a surviving stale generation can never satisfy this gate.
  found=$(vault_exec "for i in \$(vault list -format=json identity/entity-alias/id | tr -d '[]\", '); do [ -n \"\$i\" ] && vault read -format=json identity/entity-alias/id/\$i; done" 2>/dev/null \
    | jq -rs --arg acc "$live_accessor" --arg iss "$want_issuer" '
        .[] | .data | select(.mount_accessor == $acc and .issuer == $iss)
        | "\(.name)\t\(.canonical_id)"' 2>/dev/null || true)

  while IFS=$'\t' read -r name ent; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "${name}"$'\t'"${ent}" <<<"$found"; then
      fail "OAuth alias '${name}' is missing at the live profile (accessor ${live_accessor}, issuer ${want_issuer})"
      missing=$(( missing + 1 ))
    fi
  done <<< "$expected"

  if (( missing > 0 )); then
    fail "${missing} OAuth entity alias(es) are absent — UC2/UC3 token validation will fail with \"no alias found\""
    fail "  The issuer_id above is correct, but the aliases that resolve an identity from it were not written."
    fail "  Re-run: bash infrastructure/scripts/vault-configure.sh"
    return 1
  fi
  # Count what was actually READ OUT OF VAULT against what was expected. Printing
  # the expected count on both sides of "N of N" makes the one line a reader takes
  # as the gate's receipt true by construction — the same tautology this gate
  # exists to replace, moved from the verdict into the evidence.
  n_expected=$(grep -c . <<<"$expected" || true)
  n_found=$(grep -c . <<<"$found" || true)
  ok "OAuth entity aliases present for every identity at the live profile (${n_found} found at accessor ${live_accessor}, ${n_expected} expected)"
  return 0
}

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
  # Read via vault_exec, not a port-forward. This used to open a second tunnel on
  # 18200 purely to read one field, and inherited every failure mode of the first:
  # a tunnel that never bound (stale listener) or died mid-read produced
  # "Could not read Vault's oauth-resource-server issuer_id" — a warning about
  # ACME on a deploy where ACME was fine. kubectl exec needs no local port, so
  # there is no port to clash over and no orphan to reap.
  vault_issuer=$(vault_exec "vault read -format=json sys/config/oauth-resource-server/ivia" \
    2>/dev/null | jq -r '.data.issuer_id // empty' 2>/dev/null || echo "")

  if [[ -z "$vault_issuer" ]]; then
    # FAIL, not WARN. This is the same fail-open the alias gate below was changed
    # to close: the value that decides whether UC2/UC3 tokens validate at all could
    # not be read, so the phase knows nothing about it. A WARN here let a run whose
    # Vault was unreadable finish with a green summary — unverified reported as
    # merely noisy.
    fail "Could not read Vault's oauth-resource-server issuer_id — the OAuth binding is UNVERIFIED"
    fail "  Vault unreachable, profile absent, or the token lacks access. Not a pass."
    fail "  Check: kubectl exec -n vault vault-0 -- vault read sys/config/oauth-resource-server/ivia"
    record "ivia_verify" "FAIL"
  elif [[ "$vault_issuer" == *".invalid"* ]]; then
    warn "Vault's OAuth issuer_id is a pre-ACME placeholder: ${vault_issuer}"
    warn "  Vault validates UC2/UC3 tokens against this value, so a placeholder"
    warn "  here means ACME (deploy Step 7) did not complete. Re-run Step 7:"
    warn "    bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init"
    record "ivia_verify" "WARN"
  elif ! assert_oauth_aliases_current "$vault_issuer"; then
    record "ivia_verify" "FAIL"
  else
    ok "Vault OAuth issuer_id: ${vault_issuer}"
    record "ivia_verify" "PASS"
  fi

  # iviaop discovery — see (b) above. A `.invalid` placeholder here is EXPECTED
  # until tier 3 runs, so this must not warn during tier 2. But once tier 3 HAS
  # performed the flip and the issuer is STILL a placeholder, that is a genuine
  # fault and staying silent hides it.
  #
  # TWO things must both happen before the issuer becomes the real FQDN:
  #   1. deploy Step 7 (ACME) issues the cert and re-applies module.ivia, AND
  #   2. tier 3 applies kubernetes_config_map_v1_data.iviaop_clients_patch
  #      (infrastructure/workloads/main.tf) and restarts iviaop.
  # The patch carries `depends_on = [module.uc2_app]` because it needs the
  # banking-UI ALB hostname that only tier 3 creates, so the flip is DEFERRED to
  # tier 3 BY DESIGN — a circular-dependency break documented in
  # modules/verify_access/main.tf. So "has the flip run?" is answered by that
  # resource being present in tier-3 state.
  #
  # Presence of the RESOURCE, not merely of the state FILE: a `terraform init` or
  # a partially-failed apply leaves a state file behind with the patch absent, and
  # gating on the file would then report a real tier-2 placeholder as a tier-3
  # failure. Absent/unreadable state is treated as "tier 3 has not run", which is
  # the no-false-alarm direction.
  local issuer tier3_state tier3_flip_applied=false
  tier3_state="${VAULT_CONFIG_DIR}/../workloads/terraform.tfstate"
  if [[ -f "$tier3_state" ]] && \
     [[ "$(jq -r '[.resources[]? | select(.type=="kubernetes_config_map_v1_data" and .name=="iviaop_clients_patch")] | length' "$tier3_state" 2>/dev/null || echo 0)" -gt 0 ]]; then
    tier3_flip_applied=true
  fi

  issuer=$(kubectl exec -n verify-access deploy/iviawrprp1 -- \
    curl -sk --max-time 15 \
    https://localhost:9443/isvaop/oauth2/.well-known/openid-configuration \
    2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")

  if [[ -z "$issuer" ]]; then
    info "iviaop OIDC discovery not responding yet — IVIA may still be initializing (informational)"
  elif [[ "$issuer" == *".invalid"* ]]; then
    if [[ "$tier3_flip_applied" == true ]]; then
      warn "iviaop discovery issuer is STILL a placeholder after tier 3: ${issuer}"
      warn "  Tier 3 applied iviaop_clients_patch, so the issuer should already be"
      warn "  the real nip.io FQDN. Check that iviaop actually restarted to reload"
      warn "  the patched ConfigMap (it reads provider.yml/clients.yml only at startup):"
      warn "    kubectl rollout restart deploy/iviaop -n verify-access"
      record "ivia_verify" "WARN"
    else
      info "iviaop discovery issuer: ${issuer} (placeholder — expected; tier 3 patches it)"
    fi
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
