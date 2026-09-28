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
#   2. Vault config     — port-forward :8200, terraform apply vault-config/ (Vault
#                         2.1.x needs no oauth-resource-server activation flag),
#                         then a deploy-time license-module
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
# tier-2 state FILE — read-only here, and read with jq rather than
# `terraform -chdir=services output`. Same channel the module reads
# (vault-config/main.tf: data.terraform_remote_state.services), and the same file
# phase_gather already hard-requires. `terraform output` would add an init
# dependency on the tier-2 workspace: a wiped plugin cache or a removed
# .terraform/ makes it fail, and a failed name lookup silently drops the very
# rows #83 was filed for (the orphaned uc3-actor entity).
SERVICES_STATE="${REPO_ROOT}/infrastructure/services/terraform.tfstate"
# Generated-then-deleted config-driven import file. Named here so the cleanup
# trap and the pre-init sweep both reference exactly one path. NEVER committed: a
# copy left behind makes every later apply fail with "resource already managed".
ORPHAN_IMPORT_TF="${VAULT_CONFIG_DIR}/zz-orphan-reconcile.tf"

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

#--- Local port 8200 -----------------------------------------------------------
# Phase 2 needs local port 8200 for its own `kubectl port-forward`. A listener
# left over from a walkthrough step holds it, and the previous implementation
# fired `kill` at whatever lsof reported, slept one second and bound regardless:
# a socket still in the kernel's hands after a second, or a holder that ignores
# SIGTERM, took the whole step down with a bare "failed to start" (#84).

# True when something answers on 8200, whether or not lsof can see it.
_port_8200_occupied() {
  (exec 3<>/dev/tcp/127.0.0.1/8200) 2>/dev/null
}

# PIDs listening on 8200, empty when lsof is absent or sees nothing.
_port_8200_pids() {
  lsof -tiTCP:8200 -sTCP:LISTEN 2>/dev/null || true
}

# The port is free only when BOTH agree: nothing listed AND nothing answering.
# Either alone is a lie in one direction — lsof misses what it cannot see, and a
# socket in the kernel's hands can still answer after its owner is gone.
_port_8200_free() {
  [[ -z "$(_port_8200_pids)" ]] && ! _port_8200_occupied
}

# Say what is known about the current holder of 8200. lsof may have nothing to
# say — not installed, or another user's socket — so say THAT rather than print
# an empty list under a "here is what is holding it" heading.
_port_8200_report_holder() {
  local listing line
  listing="$(lsof -nP -iTCP:8200 -sTCP:LISTEN 2>/dev/null | tail -n +2)"
  if [[ -n "$listing" ]]; then
    while IFS= read -r line; do fail "  ${line}"; done <<< "$listing"
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    fail "  the port answers connections but lsof cannot name the process — it is"
    fail "  most likely owned by another user. Try: sudo lsof -nP -iTCP:8200 -sTCP:LISTEN"
  else
    fail "  'lsof' is not installed, so this script cannot name the holder."
    fail "  Install lsof, or stop whatever is on port 8200 yourself."
  fi
}

# Free local port 8200 so our own port-forward can bind it. Polls until the port
# is genuinely free, escalates to SIGKILL when it is not, and — when it still
# cannot be freed — names the PID and command actually holding it, so the
# attendee is told what to close instead of reading a generic start failure.
#
# Every decision is driven by _port_8200_free (lsof AND the probe), never by the
# lsof list alone: lsof can stop reporting a LISTEN entry while the socket still
# answers, and keying off the list alone skips the escalation and prints an empty
# holder listing — the exact dead end #84 exists to remove.
#
# Returns 0 when the port is free, including when it was never held.
_free_local_port_8200() {
  local pids i

  _port_8200_free && return 0

  pids="$(_port_8200_pids)"
  if [[ -z "$pids" ]]; then
    # Occupied, but nothing lsof can see: there is nothing to signal, only to report.
    fail "Port 8200 is in use, but the process holding it could not be identified:"
    _port_8200_report_holder
    info "Fix: stop whatever is on port 8200, confirm with"
    info "     'lsof -nP -iTCP:8200 -sTCP:LISTEN', then re-run this script."
    return 1
  fi

  info "Port 8200 already bound (PID(s): $(echo "$pids" | tr '\n' ' ')) — clearing"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true

  for i in $(seq 1 10); do
    _port_8200_free && { ok "Port 8200 released"; return 0; }
    sleep 1
  done

  pids="$(_port_8200_pids)"
  if [[ -n "$pids" ]]; then
    warn "Port 8200 still held after SIGTERM — escalating to SIGKILL"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    for i in $(seq 1 5); do
      _port_8200_free && { ok "Port 8200 released"; return 0; }
      sleep 1
    done
  else
    warn "Port 8200 still answers, but no listening process can be identified"
  fi

  fail "Port 8200 could not be freed — a process is holding it that this script cannot stop:"
  _port_8200_report_holder
  info "Fix: stop that process (it is usually a manual 'kubectl port-forward ... 8200'),"
  info "     confirm with 'lsof -nP -iTCP:8200 -sTCP:LISTEN', then re-run this script."
  return 1
}

# Recovery hint printed when a terraform apply fails on an orphaned Vault mount
# and self-heal could not clear it (or the conflict was not an auth backend).
_vault_orphan_fix_hint() {
  info "Fix: 'path is already in use at <path>/' means a prior interrupted run left"
  info "     an object in Vault that is absent from this workspace's terraform state."
  info "     Adopt it by IMPORT — never by deleting the live object, which revokes"
  info "     every token issued through it, including the ones tier-3 pods hold:"
  info "       VT=\$(jq -r .root_token ~/vault-init.json)"
  info "       terraform -chdir=${VAULT_CONFIG_DIR} state list"
  info "       kubectl exec -n vault vault-0 -- sh -c \"VAULT_TOKEN=\$VT vault secrets list\""
  info "       kubectl exec -n vault vault-0 -- sh -c \"VAULT_TOKEN=\$VT vault auth list\""
  info "       terraform -chdir=${VAULT_CONFIG_DIR} import <address> <id>"
  info "     Import ids by kind — mounts, auth backends and audit devices by PATH;"
  info "     agent registrations by display_name; the OAuth profile by profile_name;"
  info "     identity entities by UUID:"
  info "       vault read identity/entity/name/<name>              # -> .data.id"
  info "     and an entity ALIAS has no read-by-name endpoint, so look it up by alias:"
  info "       vault write identity/lookup/entity alias_name=<name> \\"
  info "            alias_mount_accessor=\$(vault auth list -format=json | jq -r '.\"kubernetes/\".accessor')"
  info "     Then re-run: bash infrastructure/scripts/deploy-workshop.sh --tier 2 --skip-vault-init --skip-acme"
  info "Fix: 'alias already exists for issuer and external_id' means a previous TLS"
  info "     host left OAuth entity aliases behind and one of them squats the issuer"
  info "     this run needs. List them and delete the ones whose mount_accessor is"
  info "     NOT oauth-resource-server_root_<the config_id below>, then re-run tier 2:"
  info "       vault read sys/config/oauth-resource-server/ivia   # -> config_id"
  info "       vault list identity/entity-alias/id"
  info "       vault delete identity/entity-alias/id/<alias-id>"
}

# A tier-2 output value, read straight from the state file the vault-config root
# reads (data.terraform_remote_state.services). Echoes nothing and returns
# non-zero when the value is absent, so callers can fail LOUD — a name that
# cannot be resolved must never quietly drop a row from the reconcile table.
_services_output() {
  local v
  v="$(jq -r --arg k "$1" '.outputs[$k].value // empty' "${SERVICES_STATE}" 2>/dev/null)"
  [[ -z "$v" || "$v" == "null" ]] && return 1
  printf '%s' "$v"
}

# The human `sub` values, one per line: uc2_human_subs (a list) plus uc3_human_sub.
# Mirrors the module's local.obo_human_subs = toset(concat(uc2_human_subs, [uc3_human_sub])).
#
# Each source is required INDEPENDENTLY. A `// []` fallback on one of them and a
# single both-are-empty guard downstream is not fail-loud: uc3_human_sub alone
# resolving would return success with every uc2 human missing from the table, and
# the retry apply then collides on exactly the row that was dropped.
_obo_human_names() {
  local subs uc3
  subs="$(jq -r 'if (.outputs.uc2_human_subs.value | type) == "array"
                 then .outputs.uc2_human_subs.value[] else empty end' \
          "${SERVICES_STATE}" 2>/dev/null)"
  [[ -z "$subs" ]] && return 1
  uc3="$(_services_output uc3_human_sub)" || return 2
  printf '%s\n%s\n' "$subs" "$uc3"
}

# The explicit set of resources an interrupted apply can leave behind in Vault.
# Emits "address<TAB>kind<TAB>vault-identifier". Deliberately explicit rather than
# derived from the plan: every row is reviewable, and a resource that cannot be
# safely imported simply is not listed.
#
# A row belongs here when creating it a SECOND time is an error — that is what
# makes it orphan-able:
#   audit device   PUT  /v1/sys/audit/file        -> "path already in use"
#   auth backend   POST /v1/sys/auth/kubernetes   -> "path is already in use"
#   secrets mount  POST /v1/sys/mounts/database   -> "path is already in use"
#   identity entity                               -> "Identity Entity ... already exists"
#   entity alias                                  -> "entity alias ... already exists"
#   agent registration                            -> display_name already in use
#   oauth resource-server profile                 -> profile_name already in use
# Everything else the module writes (policies, database/aws/kubernetes roles, the
# database connection, the audit request-header allowlist, the generic_endpoint
# OAuth aliases) is an upsert, so a second create overwrites and never fails —
# those are not orphan-able and must NOT be listed.
#
# Diagnostics go to STDERR: this function's stdout IS the table, captured by the
# caller, so a warn() on stdout would be swallowed into the variable and the
# operator would see only a generic message naming every possible cause.
#
# Returns non-zero if a tier-2 name could not be resolved; the caller aborts the
# reconcile rather than run with a table that silently omits rows.
_vault_reconcile_table() {
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_audit.stdout'              audit  file
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_auth_backend.kubernetes'   auth   kubernetes
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_mount.database'            mount  database
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_aws_secret_backend.this'   mount  aws
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_identity_entity.uc1_agent' entity uc1-agent

  # The UC1 Kubernetes-mount alias. Identified by "<auth path>|<alias name>"
  # because an alias is unique on (mount_accessor, name), and the accessor is only
  # knowable from the LIVE mount — importing the auth backend preserves it, so the
  # alias collides on the retry unless it is adopted too.
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_identity_entity_alias.uc1_agent' \
    entity_alias 'kubernetes|uc1/uc1-retriever-sa'

  # agent-uc2 / uc3-actor: the resource names are fixed, the Vault entity names
  # come from tier 2 (var.uc2_agent_identity / var.uc3_agent_identity).
  local n
  n="$(_services_output uc2_agent_identity)" \
    || { warn "tier-2 output uc2_agent_identity is unreadable in ${SERVICES_STATE}" >&2; return 1; }
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_identity_entity.agent_uc2' entity "$n"
  n="$(_services_output uc3_agent_identity)" \
    || { warn "tier-2 output uc3_agent_identity is unreadable in ${SERVICES_STATE}" >&2; return 1; }
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_identity_entity.uc3_actor' entity "$n"

  # Agent Registry records. display_name is required, unique and IMMUTABLE, so a
  # second create is an error — orphan-able. A registration is created strictly
  # AFTER its entity (entity_id references it), so any apply that orphans one has
  # already orphaned the entity: adopting the entity alone leaves the retry to
  # collide on the registration, which is the failure this reconcile promises to
  # remove. The provider imports these by display_name.
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_agent_registration.uc1_agent' agent_reg uc1-agent
  n="$(_services_output uc2_agent_identity)" \
    || { warn "tier-2 output uc2_agent_identity is unreadable in ${SERVICES_STATE}" >&2; return 1; }
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_agent_registration.agent_uc2' agent_reg "$n"
  n="$(_services_output uc3_agent_identity)" \
    || { warn "tier-2 output uc3_agent_identity is unreadable in ${SERVICES_STATE}" >&2; return 1; }
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_agent_registration.uc3_actor' agent_reg "$n"

  # The OAuth resource-server profile. profile_name names it and a second create
  # collides; the provider imports it by profile_name. Deliberately listed even
  # though main sweeps stale entity ALIASES before the apply — the sweep clears
  # aliases on a dead profile, it does not adopt the profile itself.
  printf '%s\t%s\t%s\n' 'module.vault_config.vault_oauth_resource_server_config_profile.ivia' oauth_profile ivia

  # vault_identity_entity.human is for_each over toset(obo_human_subs), so each
  # instance address carries the sub as its key AND its name (name = each.value on
  # a set => key == value). Enumerate the same set tier 2 publishes.
  local humans rc=0
  humans="$(_obo_human_names)" || rc=$?
  case "$rc" in
    1) warn "tier-2 output uc2_human_subs is unreadable in ${SERVICES_STATE}" >&2; return 1 ;;
    2) warn "tier-2 output uc3_human_sub is unreadable in ${SERVICES_STATE}"  >&2; return 1 ;;
  esac
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    printf '%s\t%s\t%s\n' "module.vault_config.vault_identity_entity.human[\"${n}\"]" entity "$n"
  done <<< "$(printf '%s\n' "$humans" | sort -u)"
}

#--- Vault reads for the reconcile ---------------------------------------------
# Every read below goes through vault_exec (kubectl exec), NEVER the 127.0.0.1:8200
# tunnel. The reconcile runs only AFTER an apply has failed, and a killed
# port-forward is one of the named causes of that failure — so the tunnel is at
# its least trustworthy exactly here. A transient tunnel read returning "not
# found" would drop a genuinely orphaned row, produce an incomplete import file,
# and make the retry fail on the dropped row with no indication why.

# The three mount tables, fetched ONCE per reconcile pass into these caches.
# Empty string means "not fetched"; a fetch failure aborts the whole pass rather
# than letting an unreadable Vault masquerade as "nothing is orphaned".
VAULT_TBL_AUTH=""
VAULT_TBL_MOUNTS=""
VAULT_TBL_AUDIT=""

# `vault audit list -format=json` exits 0 and prints {} when no device is enabled
# (measured against Vault 1.20.4), so the hard-fail below fires on a genuine read
# failure only. That is also why the emptiness check that follows deliberately
# omits VAULT_TBL_AUDIT: an empty audit table is legitimate, an empty auth or
# mount table is not.
_vault_load_mount_tables() {
  VAULT_TBL_AUTH="$(vault_exec "vault auth list -format=json" 2>/dev/null)"   || return 1
  VAULT_TBL_MOUNTS="$(vault_exec "vault secrets list -format=json" 2>/dev/null)" || return 1
  VAULT_TBL_AUDIT="$(vault_exec "vault audit list -format=json" 2>/dev/null)"  || return 1
  [[ -n "$VAULT_TBL_AUTH" && -n "$VAULT_TBL_MOUNTS" ]] || return 1
  return 0
}

# True when the cached table for <kind> already carries <path>/.
_vault_path_mounted() {
  local kind="$1" p="$2" tbl
  case "$kind" in
    auth)  tbl="$VAULT_TBL_AUTH" ;;
    mount) tbl="$VAULT_TBL_MOUNTS" ;;
    audit) tbl="$VAULT_TBL_AUDIT" ;;
    *)     return 1 ;;
  esac
  [[ -n "$tbl" ]] || return 1
  jq -e --arg k "${p}/" 'has($k)' <<<"$tbl" >/dev/null 2>&1
}

# Does <path> read back? 0 = yes, 2 = no such object, 1 = Vault itself could not
# be read. The caller must treat 1 as "abort", never as "absent" — the whole
# reason this pass exists is that state and Vault disagree, and a read that did
# not happen is not evidence about either.
_vault_read_exists() {
  vault_exec "vault read -format=json '$1'" >/dev/null 2>&1 && return 0
  vault_exec "vault auth list -format=json" >/dev/null 2>&1 || return 1
  return 2
}

# Vault's UUID for an identity entity name. Echoes nothing when the entity does
# not exist; returns non-zero only when Vault itself could not be read, which the
# caller must treat as "abort", never as "absent".
_vault_entity_id() {
  local out
  out="$(vault_exec "vault read -format=json identity/entity/name/'$1'" 2>/dev/null)" || {
    # A missing entity and an unreadable Vault both fail the CLI. Ask a question
    # we know the answer to: if the auth table still reads, the entity is simply
    # absent; if it does not, the channel is down and the pass must abort.
    vault_exec "vault auth list -format=json" >/dev/null 2>&1 || return 1
    return 0
  }
  jq -r '.data.id // empty' <<<"$out" 2>/dev/null
}

# Vault's UUID for an entity alias, given "<auth mount path>|<alias name>".
# There is no read-by-name endpoint for an alias, so resolve it the documented
# way: look the entity up BY its alias, then pick the matching alias off it. The
# mount accessor comes from the live auth table, never from terraform state —
# the whole point is that state does not know about this object.
_vault_entity_alias_id() {
  local mount_path="${1%%|*}" alias_name="${1#*|}" accessor out
  accessor="$(jq -r --arg k "${mount_path}/" '.[$k].accessor // empty' <<<"$VAULT_TBL_AUTH" 2>/dev/null)"
  [[ -z "$accessor" ]] && return 0   # mount absent => the alias cannot exist yet

  out="$(vault_exec "vault write -format=json identity/lookup/entity alias_name='${alias_name}' alias_mount_accessor='${accessor}'" 2>/dev/null)" || {
    vault_exec "vault auth list -format=json" >/dev/null 2>&1 || return 1
    return 0
  }
  jq -r --arg n "$alias_name" --arg a "$accessor" \
    '[.data.aliases[]? | select(.name == $n and .mount_accessor == $a) | .id][0] // empty' \
    <<<"$out" 2>/dev/null
}

# Reconcile an interrupted prior run. A terraform apply that dies partway through
# (provider panic, killed port-forward, lost session) leaves the objects it already
# wrote in Vault while never persisting them to state, so the next apply tries to
# CREATE them and fails.
#
# Recovery is CONFIG-DRIVEN import: write an `import` block per orphan and let the
# retry apply adopt them. `terraform import` on the CLI cannot do this job — it
# materialises only the single instance being imported, so importing one for_each
# instance of vault_identity_entity.human while its sibling is also missing makes
# the module's own local.oauth_aliases fail with "Invalid index". Import blocks are
# expanded during plan, where for_each is whole, and the same apply then creates
# everything genuinely missing. Requires Terraform >= 1.5; the repo floor is 1.10.
#
# This replaces an unmount-based heal that (a) only ever covered auth backends, so
# orphaned secrets engines and identity entities were unrecoverable, and (b) removed
# the live object: deleting kubernetes/ auth revokes every token issued through it,
# including the ones running tier-3 pods hold. Nothing here mutates Vault.
#
# Runs ONLY after a failed apply. Returns 0 when it wrote a verified import file
# (caller retries the apply, then deletes the file), non-zero otherwise.
reconcile_orphaned_vault_resources() {
  local state_list addr kind vid import_id blocks=0 plan_log table rc
  info "Apply failed — reconciling Vault against terraform state..."

  # Never build on a previous attempt's file.
  rm -f "${ORPHAN_IMPORT_TF}"

  # Build the table FIRST and abort if it is incomplete. A table missing rows
  # because a tier-2 name would not resolve reconciles only part of the drift and
  # reports success — worse than the hint, because the retry then fails on the row
  # that was dropped. stderr passes through so the specific warn() is seen.
  if ! table="$(_vault_reconcile_table)"; then
    fail "Cannot build the reconcile table — the tier-2 output named above is unreadable."
    fail "  Expected in: ${SERVICES_STATE}"
    return 1
  fi

  if ! _vault_load_mount_tables; then
    fail "Cannot read Vault's mount tables through 'kubectl exec' — not reconciling."
    fail "  An unreadable Vault must not be reported as 'nothing is orphaned'."
    fail "  Check: kubectl get pods -n vault"
    return 1
  fi

  # State is the other half of this comparison, and gets the same treatment as an
  # unreadable Vault. `state list` exits 0 with no output on a genuinely empty
  # state, so a non-zero exit means lock contention or a damaged state file — and
  # swallowing it would make every row look orphaned, writing import blocks for
  # resources terraform already manages.
  if ! state_list="$(terraform -chdir="${VAULT_CONFIG_DIR}" state list 2>&1)"; then
    fail "Cannot read terraform state — not reconciling:"
    printf '%s\n' "$state_list" | head -5 | while IFS= read -r line; do fail "  ${line}"; done
    return 1
  fi

  while IFS=$'\t' read -r addr kind vid; do
    [[ -z "$addr" || -z "$kind" || -z "$vid" ]] && continue
    # Already tracked — an import block for a managed resource is a hard error, so
    # only genuine orphans may be written. -x -F so the for_each brackets and quotes
    # in an instance address match literally and never as a pattern.
    if printf '%s\n' "$state_list" | grep -qxF "$addr"; then
      continue
    fi

    import_id=""
    rc=0
    case "$kind" in
      # Mounts, auth backends and audit devices adopt by PATH. vault_audit's id is
      # the DEVICE PATH, which defaults to the type ("file") — not the file_path
      # option ("stdout"): the failing call is PUT /v1/sys/audit/file.
      auth|mount|audit) _vault_path_mounted "$kind" "$vid" && import_id="$vid" ;;
      entity)           import_id="$(_vault_entity_id "$vid")" || rc=$? ;;        # adopts by UUID
      entity_alias)     import_id="$(_vault_entity_alias_id "$vid")" || rc=$? ;;  # adopts by UUID
      # These two adopt by NAME, so existence is the only question.
      agent_reg)     _vault_read_exists "agent-registry/registration/display-name/${vid}"
                     case "$?" in 0) import_id="$vid" ;; 1) rc=1 ;; esac ;;
      oauth_profile) _vault_read_exists "sys/config/oauth-resource-server/${vid}"
                     case "$?" in 0) import_id="$vid" ;; 1) rc=1 ;; esac ;;
      *) warn "Reconcile row '${addr}' has unknown kind '${kind}' — skipped"; continue ;;
    esac
    if (( rc != 0 )); then
      fail "Vault became unreadable while checking '${vid}' — not reconciling."
      fail "  Reconciling on partial reads writes an incomplete import file, and the"
      fail "  retry then fails on the row that was silently dropped."
      rm -f "${ORPHAN_IMPORT_TF}"
      return 1
    fi
    # Absent from state AND absent from Vault is not drift — the retry creates it.
    [[ -z "$import_id" ]] && continue

    warn "${vid} exists in Vault but is absent from terraform state — will import ${addr}"
    {
      printf 'import {\n'
      printf '  to = %s\n' "$addr"
      printf '  id = "%s"\n' "$import_id"
      printf '}\n'
    } >> "${ORPHAN_IMPORT_TF}"
    blocks=$((blocks + 1))
  done <<< "$table"

  if [[ "$blocks" -eq 0 ]]; then
    info "Nothing orphaned — the apply failed for another reason"
    rm -f "${ORPHAN_IMPORT_TF}"
    return 1
  fi

  # Verify before handing a generated file to an -auto-approve apply. A bad block
  # must surface as "reconcile failed, here is why", never as a second apply
  # failure on config the script wrote.
  info "Verifying ${blocks} import block(s) with terraform plan..."
  plan_log="$(mktemp)"
  if ! terraform -chdir="${VAULT_CONFIG_DIR}" plan -input=false -no-color >"$plan_log" 2>&1; then
    fail "Reconcile plan failed — not applying the generated import blocks:"
    grep -E '^(Error|╷|│|╵)' "$plan_log" | head -15 | while IFS= read -r line; do
      fail "  ${line}"
    done
    rm -f "$plan_log" "${ORPHAN_IMPORT_TF}"
    return 1
  fi
  ok "Reconcile plan clean — $(grep -c 'will be imported' "$plan_log" || true) resource(s) to adopt"
  rm -f "$plan_log"
  return 0
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
  local deleted=0 failed=0 skipped=0 unreadable=0 _read_rc=0
  local live_id live_accessor names alias_ids id acc name entry

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
    # `vault list` answers empty BOTH when the namespace genuinely holds no
    # aliases and when the read failed, so the two are told apart the same way
    # the live_id branch above tells them apart — by asking Vault whether it is
    # answering at all — rather than by assuming the happy case. Assuming it is
    # how a sweep that could not read anything reported that there was nothing
    # to read.
    if vault_exec "vault status -format=json" >/dev/null 2>&1; then
      info "No entity aliases in Vault — nothing to sweep"
      return 0
    fi
    warn "Could not list entity aliases — Vault answered the profile read and then stopped"
    warn "  The sweep cannot certify it saw the alias list, so no alias will be deleted"
    return 1
  fi

  # Pass 1 — find the aliases that sit on a DEAD oauth-resource-server profile.
  # An alias on the profile this deploy binds is current by definition, and an
  # alias belonging to any other auth method is none of this sweep's business.
  local candidates="" _tab
  _tab=$'\t'
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    # A read that FAILED must not be confused with a read that SUCCEEDED and
    # returned an alias belonging to another auth method. Both leave the accessor
    # empty, and answering both with `continue` is what let a transport that went
    # blind mid-walk report a clean sweep: the aliases it could not read are
    # precisely the ones that might be squatting the issuer. Three conditions are
    # all "could not read", none of them "not my business":
    #   - vault_exec exited non-zero (pod gone, exec refused, CLI error)
    #   - it exited 0 but the body is not parseable JSON (truncated/partial)
    #   - the JSON parses but carries no mount_accessor, the one field the
    #     decision turns on
    # jq -e covers the middle case (parse error) and the null case; the emptiness
    # test after it covers a present-but-empty accessor.
    #
    # An alias legitimately deleted between the list and this read lands here too
    # and is treated as a read failure — deliberately. During a deploy this sweep
    # is the only writer of these aliases and it runs before the apply, so an
    # alias vanishing mid-walk is not an expected state; and the two costs are not
    # symmetric. A false "could not read" stops the phase with an accurate message
    # and is cleared by re-running. A false "clean sweep" lets the deploy walk into
    # the 400 this function exists to prevent, while the log says the opposite.
    _read_rc=0
    entry=$(vault_exec "vault read -format=json identity/entity-alias/id/${id}" 2>/dev/null) || _read_rc=$?
    acc=""
    if (( _read_rc == 0 )); then
      acc=$(jq -re '.data.mount_accessor' <<<"$entry" 2>/dev/null) || acc=""
    fi
    if [[ -z "$acc" ]]; then
      unreadable=$(( unreadable + 1 ))
      warn "  could not read entity alias ${id} — it is neither confirmed current nor confirmed orphaned"
      continue
    fi
    name=$(jq -r '.data.name // empty' <<<"$entry" 2>/dev/null || echo "")
    case "$acc" in
      oauth-resource-server_root_*) ;;
      *) continue ;;
    esac
    [[ "$acc" == "$live_accessor" ]] && continue
    candidates="${candidates}${id}${_tab}${name}${_tab}${acc}"$'\n'
  done <<< "$alias_ids"

  # Refuse to act on a partial view BEFORE deciding anything, and before deleting
  # anything. Same posture as an unreadable Vault at the top: the sweep's contract
  # is that rc=0 means it saw the whole alias list and acted on all of it, so an
  # alias it could not classify makes rc=0 a lie whatever the visible candidates
  # look like. Deleting the ones it did see would add mutation to a run the call
  # site is about to stop anyway.
  if (( unreadable > 0 )); then
    warn "${unreadable} entity alias(es) could not be read — the sweep cannot certify it saw the whole list"
    warn "  Refusing to delete on a partial view: a stale (issuer, external_id) may still be squatting"
    warn "  one of them. Re-run once Vault is readable: ${BASH_SOURCE[0]}"
    return 1
  fi

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
  # A surviving zz-orphan-reconcile.tf makes EVERY later apply fail with
  # "resource already managed", so it is removed on every path out of the script.
  rm -f "${ORPHAN_IMPORT_TF}" 2>/dev/null || true
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
  # forward fail to bind. Free it first, and VERIFY it is actually free — the
  # unverified kill+sleep this replaces is #84.
  if ! _free_local_port_8200; then
    record "vault_config" "FAIL"
    return 1
  fi

  # Bind with retries. `kubectl port-forward` can also exit immediately on a
  # transient API-server hiccup, which is not a reason to fail the deploy, and a
  # single attempt made that indistinguishable from an occupied port.
  info "Starting port-forward to Vault (8200)..."
  local pf_attempt
  VAULT_PF_PID=""
  for pf_attempt in 1 2 3; do
    kubectl port-forward svc/vault 8200:8200 -n vault &>/dev/null &
    VAULT_PF_PID=$!
    sleep 2
    kill -0 "$VAULT_PF_PID" 2>/dev/null && break
    VAULT_PF_PID=""
    warn "Port-forward attempt ${pf_attempt}/3 exited immediately — retrying"
    _free_local_port_8200 || true
    sleep 2
  done

  if [[ -z "$VAULT_PF_PID" ]]; then
    fail "Port-forward to Vault failed to start after 3 attempts. Check both:"
    fail "  port 8200 is free      — lsof -nP -iTCP:8200 -sTCP:LISTEN"
    fail "  the cluster is reachable — kubectl get pods -n vault"
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

  # No activation step: Vault 2.1.x has no oauth-resource-server activation flag
  # ("The Agentic IAM no longer requires an activation flag to use" — 2.1.0 release
  # notes), and the activate endpoint answers 404. The vault_config module forgets
  # the flag from older states with a `removed` block. The post-apply license gate
  # below is what catches a license without platform-standard.

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
  # Belt one of three against a generated import file surviving a crash: an EXIT
  # trap cannot cover kill -9, which is the very class of interruption that
  # creates this drift in the first place. Sweep unconditionally before init.
  rm -f "${ORPHAN_IMPORT_TF}"

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
  # Any failure that is not a license refusal gets a reconcile pass. Deliberately
  # NOT gated on the "path is already in use" string: the interrupted apply that
  # causes this drift can die on a provider panic while creating identity
  # entities, which never emits that message, and entities are not mounts so they
  # never matched it anyway. The pass is a no-op when nothing is orphaned. A
  # pki-only license short-circuits it — importing nothing would be pointless work
  # ahead of the license gate below, which is the real diagnosis.
  elif ! grep -q 'not supported by license' "$apply_log" && reconcile_orphaned_vault_resources; then
    info "Retrying terraform apply — adopting the orphans and creating the rest..."
    # Captured like the first apply. The retry now fires on ANY non-license
    # failure, so it can get further than apply 1 did and hit a license refusal
    # that apply 1 never reached — and an attendee on a pki-only license must get
    # the licence remediation, not the orphan-import hint.
    local retry_log
    retry_log="$(mktemp)"
    if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1 | tee "$retry_log"; then
      # Belt two: the file has done its job the instant the apply lands, and is
      # removed on BOTH paths out of the retry, not just the happy one.
      rm -f "${ORPHAN_IMPORT_TF}"
      ok "Vault configuration applied successfully (orphans adopted by import)"
      rm -f "$retry_log"
    else
      rm -f "${ORPHAN_IMPORT_TF}"
      fail "terraform apply still failing after reconciliation"
      if grep -q 'not supported by license' "$retry_log"; then
        fail "Vault refused a secret-engine mount — the license appears to be pki-only (or lacks platform-standard)."
        fail "  ${LICENSE_REMEDIATION}"
      else
        _vault_orphan_fix_hint
      fi
      rm -f "$retry_log" "$apply_log"
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

  # oauth-resource-server config profile 'ivia' responds → feature licensed +
  # profile reconciled (sys/config/oauth-resource-server/<name> — reference contract).
  if vault_exec "vault read sys/config/oauth-resource-server/ivia" >/dev/null 2>&1; then
    ok "License gate: oauth-resource-server profile 'ivia' responds"
  else
    fail "License gate: oauth-resource-server profile 'ivia' did not respond — license issue. ${LICENSE_REMEDIATION}"
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
