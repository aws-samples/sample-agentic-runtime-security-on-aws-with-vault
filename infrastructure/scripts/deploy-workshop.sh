#!/usr/bin/env bash
#===============================================================================
# deploy-workshop.sh — End-to-End Workshop Deploy Orchestrator
#
# Single entry point that applies the three Terraform roots IN ORDER and
# interleaves the configuration each tier needs. Provisioning order lives in
# Terraform's dependency graph (terraform_remote_state between roots), NOT in
# bash -target staging — this script just drives the roots in sequence and runs
# the bash configuration steps that cannot be expressed as Terraform resources.
#
#   Step  1: terraform apply — tier 1 (infrastructure/)        core infra, no pods
#   Step  2: Configure kubectl (aws eks update-kubeconfig)
#   Step  3: Build & push application images (build-images.sh)
#   Step  4: LBC readiness gate (kubectl wait aws-load-balancer-controller)
#   Step  5: terraform apply — tier 2 (infrastructure/services/) vault_server + ivia
#   Step  6: Initialize Vault (vault-init.sh)
#   Step  7: ACME cert issuance + ACM sync + tier-2 module.ivia re-apply to nip.io
#   Step  8: Configure Vault (vault-configure.sh) — reads tier-1 + tier-2 state
#   Step  9: Configure IVIA (ivia-configure.sh)
#   Step 10: terraform apply — tier 3 (infrastructure/workloads/) uc1/uc2/uc3 + roll
#   Step 11: Post-tier-3 shared-ALB assertion + iviaop agent-uc2 redirect reconcile
#   Step 12: Verify OpenLDAP user 'oscar' seeded by IVIA autoconf
#   Step 13: Seed banking DB (seed-banking-db.sh)
#   Step 14: Ingest Bedrock Knowledge Base corpus (sync-bedrock-kb.sh)
#
# Idempotent — safe to re-run end-to-end. Each tier apply is a no-op when
# nothing diverged; the ACME step early-returns when the cert is already
# Let's Encrypt-trusted. The three terraform roots auto-load their own
# terraform.tfvars (tier 1: core; tier 2: registry/MMFA secrets; tier 3: image
# URIs + bedrock_model_id).
#
# Usage: ./deploy-workshop.sh [OPTIONS]
#
# Options:
#   --region REGION          AWS region (default: parsed from terraform.tfvars)
#   --cluster-name NAME      EKS cluster name (default: parsed from terraform.tfvars)
#   --tier <1|2|3>           Run only one deploy tier (default: all 14 steps).
#                            tier 1 = steps 1-4 (core infra + kubectl + images + LBC gate)
#                            tier 2 = steps 5-9 (vault + ivia + ACME + vault/ivia configure)
#                            tier 3 = steps 10-14 (workloads + ALB assert + seed + KB ingest)
#                            Required for the Instruqt distribution (one tier per challenge);
#                            bare invocation is the Workshop Studio path (all 14 steps).
#   --image-source <ghcr|ecr>     Image source mode (default: ecr). ecr builds the five
#                                 images locally and pushes them to the account's private
#                                 ECR (container runtime required). ghcr pulls pre-built
#                                 public images from GHCR — no build, no runtime. Invalid
#                                 value fails loud. Env fallback: WORKSHOP_IMAGE_SOURCE.
#   --ghcr-registry-base <base>   GHCR registry base for pre-built images
#                                 (e.g. ghcr.io/<githubusername>). REQUIRED in ghcr
#                                 mode — no default; bring your own published images.
#                                 Only meaningful in ghcr mode.
#                                 Env fallback: WORKSHOP_GHCR_REGISTRY_BASE.
#   --skip-infra             Skip the tier-1 apply (cluster + core infra already up)
#   --skip-vault-init        Skip Vault initialization (Vault already initialized)
#   --skip-build             Skip image build+push (images already in ECR; ecr mode only)
#   --skip-acme              Skip ACME cert issuance + ACM first-sync (cert already valid)
#   --dry-run                Print planned actions without executing
#   --help                   Show this help message
#
# Env vars:
#   VAULT_ENTERPRISE_LICENSE_PATH  Path to the Vault Enterprise .hclic license file.
#                                  Defaults to ~/Downloads/vault-ent.hclic. Attendees supply
#                                  their own platform-standard Vault Enterprise license file
#                                  (never committed to the repo). Read fresh and written into
#                                  infrastructure/services/terraform.tfvars on every
#                                  tier-2 run. Override the env var to use a different license.
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - kubectl, Vault CLI, terraform >= 1.10 installed
#   - In ecr mode: Docker or Podman required (for image build+push)
#   - infrastructure/terraform.tfvars, infrastructure/services/terraform.tfvars,
#     and infrastructure/workloads/terraform.tfvars populated
#   - A Vault Enterprise platform-standard license file (see VAULT_ENTERPRISE_LICENSE_PATH)
#
# Examples:
#   ./deploy-workshop.sh                              # full deploy, ecr mode (default) — build+push to ECR
#   ./deploy-workshop.sh --image-source ghcr --ghcr-registry-base ghcr.io/<githubusername>  # no build; pull your own pre-built GHCR images
#   ./deploy-workshop.sh --tier 1                    # only steps 1-4 (Instruqt tier-1 challenge)
#   ./deploy-workshop.sh --tier 2                    # only steps 5-9 (Instruqt tier-2 challenge)
#   ./deploy-workshop.sh --tier 3                    # only steps 10-14 (Instruqt tier-3 challenge)
#   ./deploy-workshop.sh --skip-infra                # re-run config against a live cluster
#   ./deploy-workshop.sh --skip-build                # re-run when images are already pushed (ecr mode)
#   ./deploy-workshop.sh --dry-run          # preview every step
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# The three Terraform roots, applied in order.
INFRA_DIR="${PROJECT_ROOT}/infrastructure"
SERVICES_DIR="${INFRA_DIR}/services"
WORKLOADS_DIR="${INFRA_DIR}/workloads"

# Suppress the common-checks EXIT trap — we emit our own summary at end.
# shellcheck disable=SC2034
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults
#
# IMAGE_SOURCE / GHCR_REGISTRY_BASE resolution order (set -u safe — always bound):
#   1. --image-source / --ghcr-registry-base flag (explicit CLI)
#   2. WORKSHOP_IMAGE_SOURCE / WORKSHOP_GHCR_REGISTRY_BASE env var
#   3. image_source from the persisted tier-1 terraform.tfvars (after parsing)
#   4. Hard default: ecr (the GHCR base has no default — it is required only in the ghcr opt-out)
# Steps 3-4 happen after arg-parse (needs TFVARS path) and before step functions.
# The GHCR base is a bring-your-own image-source URI base (no default namespace).
#-------------------------------------------------------------------------------
REGION=""
CLUSTER_NAME=""
IMAGE_SOURCE="${WORKSHOP_IMAGE_SOURCE:-}"        # flag or env; resolved from tfvar below
GHCR_REGISTRY_BASE="${WORKSHOP_GHCR_REGISTRY_BASE:-}"  # flag or env; no default (ghcr mode requires it)
SKIP_INFRA=false
SKIP_VAULT_INIT=false
SKIP_BUILD=false
# shellcheck disable=SC2034  # consumed by _run_acme_step
SKIP_ACME=false
DRY_RUN=false
# Per-tier execution gate (empty = run all 14 steps, the Workshop Studio path;
# 1|2|3 = run only that tier's steps, the Instruqt per-challenge path).
TIER=""

# Vault port-forward PID (cleaned up on exit)
VAULT_PF_PID=""

# Application Deployments rolled AFTER the tier-3 apply (Step 10) so a re-run
# picks up freshly pushed :latest images (same tag → kubelet won't re-pull on
# its own). Format "<namespace>:<deployment>". Created by the tier-3 apply.
APP_DEPLOYMENTS=(
    "uc1:uc1-agent"
    "banking-app:banking-ui"
    "banking-app:banking-agent"
    "banking-app:banking-mcp-server"
    "banking-app:uc3-agent"
)

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    awk 'NR>2 && /^#={3,}/{exit} NR>2 && /^#/{sub(/^# ?/,""); print}' "$0"
    exit 0
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)          usage ;;
        --region)           REGION="$2"; shift ;;
        --cluster-name)     CLUSTER_NAME="$2"; shift ;;
        --tier)
            TIER="$2"; shift
            case "$TIER" in
                1|2|3) : ;;
                *) echo "ERROR: --tier must be 1, 2, or 3 (got: '${TIER}')"; usage ;;
            esac
            ;;
        --image-source)     IMAGE_SOURCE="$2"; shift ;;
        --ghcr-registry-base) GHCR_REGISTRY_BASE="$2"; shift ;;
        --skip-infra)       SKIP_INFRA=true ;;
        --skip-vault-init)  SKIP_VAULT_INIT=true ;;
        --skip-build)       SKIP_BUILD=true ;;
        --skip-acme)        SKIP_ACME=true ;;
        --dry-run)          DRY_RUN=true ;;
        -*) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

#-------------------------------------------------------------------------------
# Resolve REGION and CLUSTER_NAME from terraform.tfvars if not supplied
#-------------------------------------------------------------------------------
TFVARS="${INFRA_DIR}/terraform.tfvars"
TFVARS_EXAMPLE="${INFRA_DIR}/terraform.tfvars.example"

# Resolve a hostname to its IPv4 address(es) without depending on `dig`.
# AWS CloudShell (and stock WSL2) do not ship `dig`/bind-utils, which silently
# broke Step 7 ALB resolution. Try resolvers in order of availability:
#   getent hosts (glibc — CloudShell/Linux/WSL2), then dig (macOS/if installed),
#   then python3 socket (ultimate fallback). Prints one IP per line.
_resolve_host_ips() {
    local host="$1" out=""
    out=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -z "$out" ] && command -v dig >/dev/null 2>&1 && out=$(dig +short "$host" 2>/dev/null | grep -Eo '^[0-9.]+')
    [ -z "$out" ] && command -v python3 >/dev/null 2>&1 && out=$(python3 -c 'import socket,sys
try:
    print("\n".join(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except Exception:
    pass' "$host" 2>/dev/null)
    printf '%s\n' "$out"
}

_resolve_tfvar() {
    local key="$1"
    local file=""
    if [[ -f "$TFVARS" ]]; then
        file="$TFVARS"
    elif [[ -f "$TFVARS_EXAMPLE" ]]; then
        file="$TFVARS_EXAMPLE"
    fi
    if [[ -n "$file" ]]; then
        grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
            | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
    fi
}

if [[ -z "$REGION" ]]; then
    REGION=$(_resolve_tfvar "region")
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(_resolve_tfvar "cluster_name")
fi

if [[ -z "$REGION" ]]; then
    print_fail "REGION" "Pass --region <region> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    print_fail "CLUSTER_NAME" "Pass --cluster-name <name> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi

#-------------------------------------------------------------------------------
# Resolve IMAGE_SOURCE: flag (already set) → env (already set above) →
# persisted tier-1 tfvar (so --tier 3 partial re-runs hold the mode set at
# full-run time, even without repeating the flag) → hard default ecr.
#-------------------------------------------------------------------------------
if [[ -z "$IMAGE_SOURCE" ]]; then
    _tfvar_mode=$(_resolve_tfvar "image_source")
    IMAGE_SOURCE="${_tfvar_mode:-ecr}"
fi
case "$IMAGE_SOURCE" in
    ghcr|ecr) : ;;
    *) echo "ERROR: --image-source must be 'ghcr' or 'ecr' (got: '${IMAGE_SOURCE}')" >&2; exit 1 ;;
esac

# ghcr is a bring-your-own path: it has no default registry base. Fail fast (before
# any AWS/terraform work) if the operator selected ghcr mode without supplying one.
if [[ "$IMAGE_SOURCE" = "ghcr" && -z "$GHCR_REGISTRY_BASE" ]]; then
    echo "ERROR: --image-source ghcr requires --ghcr-registry-base <base> (e.g. ghcr.io/<githubusername>)" >&2
    echo "       or the WORKSHOP_GHCR_REGISTRY_BASE env var. There is no default namespace —" >&2
    echo "       publish the five workshop images to your own GHCR first (see the repo README:" >&2
    echo "       'Optional: pre-built images from GHCR (bring your own)'), then pass the base." >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# EXIT cleanup — kill port-forward on any exit, then emit our summary
#-------------------------------------------------------------------------------
_cleanup() {
    if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
        kill "$VAULT_PF_PID" 2>/dev/null || true
    fi
    print_summary
}
trap '_cleanup' EXIT

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
# Hard-abort: record the failure (surfaced by the EXIT-trap summary) and stop.
# Used for the ordering gates — a failed tier apply / readiness gate makes every
# downstream step meaningless, so we halt instead of cascading red.
_die() {
    print_fail "$1" "${2:-No remediation provided}"
    exit 1
}

# terraform init + apply for one root, with dry-run + hard-abort on failure.
# $1=label  $2=chdir dir  $3..=extra apply args (e.g. -target=module.ivia)
_tf_apply_tier() {
    local label="$1" dir="$2"
    shift 2
    local extra=("$@")
    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: terraform -chdir=${dir} init -input=false"
        print_info "[DRY-RUN] Would run: terraform -chdir=${dir} apply -auto-approve -input=false ${extra[*]:-}"
        print_pass "${label} (dry-run)"
        return 0
    fi

    print_info "${label}: terraform init"
    # Clear a stale/dangling provider dir before init. With a shared
    # TF_PLUGIN_CACHE_DIR on an ephemeral volume (e.g. /tmp in CloudShell), a
    # session reset can wipe the cache while .terraform/providers symlinks into
    # it survive on the persistent home volume, making init fail with "cannot
    # install package ... because it is a symlink". Removing the provider dir
    # lets init repopulate from the shared cache cleanly. (No-op when the dir
    # is absent or contains real copies.)
    [ -n "${TF_PLUGIN_CACHE_DIR:-}" ] && rm -rf "${dir}/.terraform/providers" 2>/dev/null || true
    if ! terraform -chdir="${dir}" init -input=false >/dev/null; then
        _die "${label}: terraform init" "Re-run: terraform -chdir=${dir} init"
    fi
    print_info "${label}: terraform apply"
    if ! terraform -chdir="${dir}" apply -auto-approve -input=false ${extra[@]+"${extra[@]}"}; then
        _die "${label}: terraform apply" "Re-run with TF_LOG=DEBUG: terraform -chdir=${dir} apply ${extra[*]:-}"
    fi
    print_pass "${label}"
}

# LBC admission-webhook readiness gate. The monolithic root used a
# time_sleep.alb_webhook_ready; the structural ordering (tier-1 addons applied
# before any tier-2/tier-3 Ingress) already enforces the dependency — this just
# confirms the controller is Available before an Ingress is created.
_wait_lbc_ready() {
    local label="${1:-LBC readiness gate}"
    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would wait: kubectl --context workshop wait --for=condition=Available deploy/aws-load-balancer-controller -n kube-system --timeout=300s"
        print_pass "${label} (dry-run)"
        return 0
    fi
    if ! kubectl --context workshop wait --for=condition=Available \
            deploy/aws-load-balancer-controller -n kube-system --timeout=300s >/dev/null 2>&1; then
        _die "${label}" "aws-load-balancer-controller not Available within 300s. Inspect: kubectl --context workshop -n kube-system get deploy aws-load-balancer-controller; kubectl --context workshop -n kube-system logs deploy/aws-load-balancer-controller"
    fi
    print_pass "${label} (aws-load-balancer-controller Available)"
}

_run_subscript() {
    local label="$1"
    local script_path="$2"
    shift 2
    local args=("$@")

    if [[ ! -f "$script_path" ]]; then
        print_warn "${label}: ${script_path} not found — skipping"
        return 0
    fi

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: ${script_path} ${args[*]:-}"
        return 0
    fi

    "${script_path}" ${args[@]+"${args[@]}"}
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        print_fail "${label}" "Re-run: ${script_path} ${args[*]:-}"
        return 1
    fi
    return 0
}

_wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf "http://localhost:${port}/v1/sys/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Per-tier gate. When --tier is unset (Workshop Studio path), every step runs.
# When --tier=N, only steps whose step_tier matches N run. Steps gated out are
# silent — no echo, no PASS/SKIP marker — so an Instruqt tier-2 challenge does
# not visually replay tier-1 work the previous challenge already completed.
#
# Step → tier mapping (also encoded by the main flow's _run_if_tier calls):
#   steps 1-4  → tier 1   core infra + kubectl + images + LBC gate
#   steps 5-9  → tier 2   vault + ivia + ACME + vault/ivia configure
#   steps 10-14 → tier 3  workloads + ALB assert + LDAP + DB seed + KB ingest
_run_if_tier() {
    local step_tier="$1"; shift
    if [[ -z "$TIER" ]] || [[ "$TIER" = "$step_tier" ]]; then
        "$@"
    fi
}

#-------------------------------------------------------------------------------
# Header
#-------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Workshop End-to-End Deploy (3-tier)${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""
print_info "Region:            ${REGION}"
print_info "Cluster:           ${CLUSTER_NAME}"
print_info "Image source:      ${IMAGE_SOURCE}"
if [[ "$IMAGE_SOURCE" = "ghcr" ]]; then
    print_info "GHCR base:         ${GHCR_REGISTRY_BASE}"
fi
print_info "Skip tier-1 apply: ${SKIP_INFRA}"
print_info "Skip Vault init:   ${SKIP_VAULT_INIT}"
print_info "Skip image build:  ${SKIP_BUILD} (ecr mode only)"
if [[ "$DRY_RUN" = true ]]; then
    print_warn "DRY-RUN mode — no changes will be made"
fi
echo ""

#===============================================================================
# PREFLIGHT: Resolve the non-committable inputs (LE email + IVIA secrets +
# Vault Enterprise license)
#
# These cannot live in the tracked terraform.tfvars.example files — one is an
# identity (the Let's Encrypt contact email), two are typed secrets, and one is
# a license FILE — so bootstrap seeds them empty. We collect them ONCE here,
# before any tier apply, and write them into the gitignored terraform.tfvars
# files Terraform actually reads:
#   acme_email                   -> tier-1 infrastructure/terraform.tfvars
#   icr_entitlement_key          -> tier-2 infrastructure/services/terraform.tfvars
#   ivia_mmfa_push_client_secret -> tier-2 infrastructure/services/terraform.tfvars
#   vault_enterprise_license     -> tier-2 infrastructure/services/terraform.tfvars
#
# Idempotent: a value already present is reused silently (for acme_email a real
# address — the *@example.com placeholder Let's Encrypt rejects counts as unset).
# The Vault Enterprise license is the one exception: it is re-read from its
# source file and overwritten on EVERY run (never appended/duplicated) so a
# rotated license file always propagates without manual tfvars surgery.
# Interactive only: when stdin is not a TTY we cannot prompt, so we fail fast
# with a clear message instead of hanging an automated run.
#===============================================================================
# Banner reflects only the inputs actually collected for the tier(s) in scope, so a
# --tier 1 run (e.g. the Workshop Studio CodeBuild wrapper) doesn't imply it needs the
# tier-2 IVIA secrets. Matches the tier-gated checks below.
case "$TIER" in
    1) _pf_inputs="Let's Encrypt email" ;;
    2) _pf_inputs="IVIA secrets + Vault Enterprise license" ;;
    3) _pf_inputs="none — tier-3 has no non-committable inputs" ;;
    *) _pf_inputs="Let's Encrypt email + IVIA secrets + Vault Enterprise license" ;;
esac
echo -e "${YELLOW}> Preflight: required inputs (${_pf_inputs})${NC}"

SERVICES_TFVARS="${SERVICES_DIR}/terraform.tfvars"

# Read a `key = "value"` entry from a tfvars file (empty string if absent).
_tfvars_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}

# Replace (or append) a `key = "value"` entry in a tfvars file. Uses awk rather
# than sed so a secret containing sed-replacement metacharacters (& \ |) is
# written verbatim. The value is passed through the environment (ENVIRON), NOT
# via `awk -v`, because -v escape-processes backslashes (a `\` in the value
# would be silently swallowed); ENVIRON delivers it byte-for-byte.
_tfvars_set() {
    local file="$1" key="$2" value="$3" tmp
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        tmp="$(mktemp)"
        _tfk="$key" _tfv="$value" awk '
            BEGIN { k = ENVIRON["_tfk"]; v = ENVIRON["_tfv"] }
            !done && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") { print k " = \"" v "\""; done=1; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '%s = "%s"\n' "$key" "$value" >> "$file"
    fi
}

# Fail fast when a value is unset and there is no terminal to prompt on.
_require_tty() {
    if [[ ! -t 0 ]]; then
        _die "Preflight: $1 is unset and no terminal is available to prompt" \
             "Set $1 in $2, then re-run: bash infrastructure/scripts/deploy-workshop.sh"
    fi
}

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would ensure each in-scope tier's inputs are set (acme_email for tier-1; icr_entitlement_key + ivia_mmfa_push_client_secret + vault_enterprise_license for tier-2), prompting for any that are missing (license is read from a file, never prompted)"
    print_pass "Preflight: required inputs (dry-run)"
else
    # Only the tiers actually in scope (see --tier) have their inputs checked. A
    # tier-1-only run — e.g. the Workshop Studio CodeBuild wrapper (deploy-workshop.sh
    # --tier 1) — therefore never demands the two tier-2 IVIA secrets; those are
    # attendee-supplied when tier-2 runs. The tfvars are created by bootstrap.sh.
    if [[ ! -f "$TFVARS" ]]; then
        _die "Preflight: terraform.tfvars not found" \
             "Seed the roots first: bash infrastructure/scripts/bootstrap.sh"
    fi

    # 1) acme_email (tier-1) — OPTIONAL. Empty is valid and needs no prompt: the
    #    ClusterIssuer registers the Let's Encrypt account with no contact address
    #    (LE turned off account emails and deleted stored addresses 2025-06-04, and
    #    accepts no-contact accounts), so a tier-1 CodeBuild run with a blank
    #    acme_email proceeds without a TTY. A non-empty *@example.com placeholder is
    #    still rejected — if that leaked in, prompt for a real address (or Enter to
    #    clear it to no-contact); a valid non-empty address is reused as-is.
    if [[ -z "$TIER" || "$TIER" == "1" ]]; then
        acme_email="$(_tfvars_get "$TFVARS" acme_email)"
        if [[ -z "$acme_email" ]]; then
            print_info "Preflight: acme_email empty — Let's Encrypt account will be registered with no contact email (accepted by LE)"
        elif [[ "$acme_email" == *@example.com ]]; then
            _require_tty "acme_email" "$TFVARS"
            email_re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
            while :; do
                read -r -p "  $(echo -e "${YELLOW}?${NC}") Let's Encrypt contact email (optional — press Enter for no contact): " acme_email < /dev/tty
                [[ -z "$acme_email" ]] && break
                [[ "$acme_email" =~ $email_re && "$acme_email" != *@example.com ]] && break
                print_warn "Enter a real, deliverable email, or press Enter to register with no contact."
            done
            _tfvars_set "$TFVARS" acme_email "$acme_email"
            if [[ -z "$acme_email" ]]; then
                print_pass "Preflight: acme_email cleared — no-contact Let's Encrypt account"
            else
                print_pass "Preflight: acme_email set (${acme_email})"
            fi
        else
            print_info "Preflight: acme_email already set (${acme_email}) — reusing"
        fi
    fi

    # 2+3) tier-2 IVIA secrets — only checked when tier-2 is in scope, so --tier 1
    # never touches them (bootstrap.sh still seeds SERVICES_TFVARS for later tiers).
    if [[ -z "$TIER" || "$TIER" == "2" ]]; then
        if [[ ! -f "$SERVICES_TFVARS" ]]; then
            _die "Preflight: services terraform.tfvars not found" \
                 "Seed the roots first: bash infrastructure/scripts/bootstrap.sh"
        fi

        # 2) icr_entitlement_key (tier-2) — required secret. Precedence:
        #    already-in-tfvars -> ICR_ENTITLEMENT_KEY env var -> hidden prompt.
        #    The env var lets attendees paste an organizer-provided value (or run
        #    non-interactively) without hand-editing tfvars; when it is unset we
        #    fall through to the interactive hidden prompt exactly as before.
        icr_key="$(_tfvars_get "$SERVICES_TFVARS" icr_entitlement_key)"
        if [[ -z "$icr_key" || "$icr_key" == \<*\> ]]; then
            if [[ -n "${ICR_ENTITLEMENT_KEY:-}" ]]; then
                icr_key="$ICR_ENTITLEMENT_KEY"
                _tfvars_set "$SERVICES_TFVARS" icr_entitlement_key "$icr_key"
                print_pass "Preflight: icr_entitlement_key set from ICR_ENTITLEMENT_KEY (hidden)"
            else
            _require_tty "icr_entitlement_key" "$SERVICES_TFVARS"
            while :; do
                read -r -s -p "  $(echo -e "${YELLOW}?${NC}") IBM Container Registry entitlement key (input hidden): " icr_key < /dev/tty
                echo
                [[ -n "$icr_key" ]] && break
                print_warn "Entitlement key cannot be empty — IVIA image pull fails (ImagePullBackOff) without it."
            done
            _tfvars_set "$SERVICES_TFVARS" icr_entitlement_key "$icr_key"
            print_pass "Preflight: icr_entitlement_key set (hidden)"
            fi
        else
            print_info "Preflight: icr_entitlement_key already set — reusing"
        fi

        # 3) ivia_mmfa_push_client_secret (tier-2) — required secret. Precedence:
        #    already-in-tfvars -> IVIA_MMFA_PUSH_CLIENT_SECRET env var -> hidden
        #    prompt. The env var lets attendees paste an organizer-provided value
        #    (or run non-interactively) without hand-editing tfvars; when it is
        #    unset we fall through to the interactive hidden prompt as before.
        mmfa_secret="$(_tfvars_get "$SERVICES_TFVARS" ivia_mmfa_push_client_secret)"
        if [[ -z "$mmfa_secret" ]]; then
            if [[ -n "${IVIA_MMFA_PUSH_CLIENT_SECRET:-}" ]]; then
                mmfa_secret="$IVIA_MMFA_PUSH_CLIENT_SECRET"
                _tfvars_set "$SERVICES_TFVARS" ivia_mmfa_push_client_secret "$mmfa_secret"
                print_pass "Preflight: ivia_mmfa_push_client_secret set from IVIA_MMFA_PUSH_CLIENT_SECRET (hidden)"
            else
            _require_tty "ivia_mmfa_push_client_secret" "$SERVICES_TFVARS"
            while :; do
                read -r -s -p "  $(echo -e "${YELLOW}?${NC}") IBM Verify MMFA push client secret (input hidden): " mmfa_secret < /dev/tty
                echo
                [[ -n "$mmfa_secret" ]] && break
                print_warn "MMFA push client secret cannot be empty."
            done
            _tfvars_set "$SERVICES_TFVARS" ivia_mmfa_push_client_secret "$mmfa_secret"
            print_pass "Preflight: ivia_mmfa_push_client_secret set (hidden)"
            fi
        else
            print_info "Preflight: ivia_mmfa_push_client_secret already set — reusing"
        fi

        # 4) vault_enterprise_license (tier-2) — required secret, sourced from a
        # FILE. Defaults to ~/Downloads/vault-ent.hclic; attendees provide their
        # own platform-standard Vault Enterprise license file (licenses are
        # supplied per-deploy, never committed to the repo). Unlike the two
        # secrets above, this is NOT conditional on "already set" — it is
        # re-read from VAULT_ENTERPRISE_LICENSE_PATH and overwritten on EVERY
        # run so a rotated/updated license file always propagates. The license
        # must carry the platform-standard module (NOT pki-only) or Vault
        # rejects the database/aws/kv/transit mounts every UC depends on.
        vault_license_path="${VAULT_ENTERPRISE_LICENSE_PATH:-$HOME/Downloads/vault-ent.hclic}"
        if [[ ! -s "$vault_license_path" ]]; then
            _die "Preflight: Vault Enterprise license file missing or empty (VAULT_ENTERPRISE_LICENSE_PATH=${vault_license_path})" \
                 "Set VAULT_ENTERPRISE_LICENSE_PATH to your platform-standard .hclic license file, or place it at ${vault_license_path}, then re-run: bash infrastructure/scripts/deploy-workshop.sh"
        fi
        # Strip trailing/embedded newlines — HashiCorp .hclic files are a
        # single-line blob; the tfvars writer (_tfvars_set) assumes one line.
        vault_license_content="$(tr -d '\n\r' < "$vault_license_path")"
        if [[ -z "$vault_license_content" ]]; then
            _die "Preflight: Vault Enterprise license file is empty after read (VAULT_ENTERPRISE_LICENSE_PATH=${vault_license_path})" \
                 "Verify the file contains the license blob, then re-run: bash infrastructure/scripts/deploy-workshop.sh"
        fi
        _tfvars_set "$SERVICES_TFVARS" vault_enterprise_license "$vault_license_content"
        print_pass "Preflight: vault_enterprise_license set from ${vault_license_path}"
    fi
fi
echo ""

#===============================================================================
# STEP 1: terraform apply — tier 1 (core infrastructure, no pods)
#===============================================================================
step_01_apply_tier1() {
    echo -e "${YELLOW}> Step 1: Apply tier 1 (core infrastructure)${NC}"

    if [[ "$SKIP_INFRA" = true ]]; then
        print_info "Step 1: tier-1 apply skipped (--skip-infra)"
        PASSES+=("Step 1: Apply tier 1 (skipped)")
    else
        _tf_apply_tier "Step 1: Apply tier 1 (core infrastructure)" "${INFRA_DIR}" \
            -var "image_source=${IMAGE_SOURCE}"
    fi
}

#===============================================================================
# STEP 2: Configure kubectl
#===============================================================================
step_02_configure_kubectl() {
    echo ""
    echo -e "${YELLOW}> Step 2: Configure kubectl${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} --alias workshop"
        print_pass "Step 2: Configure kubectl (dry-run)"
    else
        if aws eks update-kubeconfig \
                --region "${REGION}" \
                --name "${CLUSTER_NAME}" \
                --alias workshop \
                >/dev/null 2>&1; then
            if kubectl --context workshop get nodes --no-headers >/dev/null 2>&1; then
                local_node_count=$(kubectl --context workshop get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
                print_pass "Step 2: Configure kubectl (${local_node_count} node(s) reachable)"
            else
                _die "Step 2: Configure kubectl — nodes not reachable" \
                    "Check EKS cluster status: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
            fi
        else
            _die "Step 2: Configure kubectl — update-kubeconfig failed" \
                "Ensure EKS cluster is Active: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
        fi
    fi
}

#===============================================================================
# STEP 3: Build & push application images
#
# Pushes uc1 / banking / uc3 images to the tier-1 ECR repos BEFORE the tier-3
# apply creates the Deployments — so the pods pull a real image on first create
# instead of sitting in ImagePullBackOff. Deployments are rolled in Step 10.
#===============================================================================
step_03_build_push_images() {
    echo ""
    echo -e "${YELLOW}> Step 3: Build & push application images${NC}"

    if [[ "$IMAGE_SOURCE" != "ecr" ]]; then
        print_info "Step 3: Image build skipped (${IMAGE_SOURCE} mode — pulling pre-built public images from GHCR)"
        PASSES+=("Step 3: Build & push application images (skipped — ghcr mode)")
        return 0
    fi

    if [[ "$SKIP_BUILD" = true ]]; then
        print_info "Step 3: Image build skipped (--skip-build)"
        PASSES+=("Step 3: Build & push application images (skipped)")
    elif [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: build-images.sh --region ${REGION}"
        print_pass "Step 3: Build & push application images (dry-run)"
    else
        if _run_subscript "Step 3: build-images" "${SCRIPT_DIR}/build-images.sh" --region "${REGION}"; then
            print_pass "Step 3: Build & push application images"
        else
            _die "Step 3: build-images" "Images are required before the tier-3 apply. Re-run: ${SCRIPT_DIR}/build-images.sh --region ${REGION}"
        fi
    fi
}

#===============================================================================
# STEP 4: LBC readiness gate (before any Ingress is created in tier 2 / tier 3)
#===============================================================================
step_04_lbc_readiness_gate() {
    echo ""
    echo -e "${YELLOW}> Step 4: LBC readiness gate${NC}"
    _wait_lbc_ready "Step 4: LBC readiness gate"
}

#===============================================================================
# STEP 5: terraform apply — tier 2 (shared services: vault_server + ivia)
#
# Stands up the Vault Helm release + IVIA OIDC provider. IVIA's WRP Ingress
# creates the shared workshop-acme ALB the ACME step (Step 7) resolves. On this
# FIRST apply .acme-state is absent, so IVIA falls back to its raw ALB ingress
# hostname (degraded but working); Step 7 re-applies module.ivia on nip.io.
#===============================================================================
step_05_apply_tier2() {
    echo ""
    echo -e "${YELLOW}> Step 5: Apply tier 2 (vault_server + ivia)${NC}"
    _tf_apply_tier "Step 5: Apply tier 2 (shared services)" "${SERVICES_DIR}"
}

#===============================================================================
# STEP 6: Initialize Vault (skip if --skip-vault-init)
#===============================================================================
step_06_initialize_vault() {
    echo ""
    echo -e "${YELLOW}> Step 6: Initialize Vault${NC}"

    if [[ "$SKIP_VAULT_INIT" = true ]]; then
        print_info "Step 6: Vault init skipped (--skip-vault-init)"
        PASSES+=("Step 6: Initialize Vault (skipped)")
    elif [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: vault-init.sh"
        print_pass "Step 6: Initialize Vault (dry-run)"
    else
        if _run_subscript "Step 6: vault-init" "${SCRIPT_DIR}/vault-init.sh"; then
            vault_sealed=$(kubectl --context workshop exec -n vault vault-0 -- \
                vault status -format=json 2>/dev/null \
                | jq -r '.sealed' 2>/dev/null || echo "true")
            if [[ "$vault_sealed" = "false" ]]; then
                print_pass "Step 6: Initialize Vault (initialized, unsealed)"
            else
                _die "Step 6: Initialize Vault" \
                    "Vault sealed or unreachable. Check: kubectl --context workshop exec -n vault vault-0 -- vault status"
            fi
        else
            _die "Step 6: vault-init" "Vault must be unsealed before vault-configure. Re-run: ${SCRIPT_DIR}/vault-init.sh"
        fi
    fi
}

#===============================================================================
# STEP 7: ACME cert issuance + ACM bootstrap sync (nip.io + Let's Encrypt)
#
# Resolves the shared workshop-acme ALB (tier-2 IVIA WRP Ingress), computes
# nip.io FQDNs wrp.<deploy_id>.<alb_ip_dashed>.nip.io and
# banking.<deploy_id>.<alb_ip_dashed>.nip.io, issues a Let's Encrypt cert with
# BOTH SANs (the banking SAN's HTTP-01 challenge validates on the shared ALB via
# the cert-manager solver Ingress even though the banking-ui Ingress does not
# exist until tier 3), imports it into the stable ACM ARN, then re-applies
# tier-2 module.ivia so IVIA re-wires its WRP host + MMFA endpoints to the
# LE-trusted nip.io FQDN. The tier-2 ivia_issuer output flips here, BEFORE
# vault-configure (Step 8) binds Vault's bound_issuer to it.
#
# Idempotency floor (D-12): a second run detects the existing LE-issued ACM cert
# and skips re-issuance, still running the catch-up module.ivia apply.
#===============================================================================
ACME_STATE_FILE="${INFRA_DIR}/.acme-state"

# Reconcile the MMFA AuthenticatorClient.redirectUri (QR-enrollment URL on the
# WRP FQDN) in the IVIA AAC DB. autoconf's `clients:` block is insert-if-not-
# exists in pyivia, so the DB redirectUri sticks to the FIRST deploy's FQDN and
# never updates when the WRP host flips on a teardown→redeploy — the browser
# completes login at the new FQDN, IVIA bounces to the stale FQDN baked in the
# DB, and QR enrollment dead-ends. This PUTs the corrected redirectUri when the
# live LMI value diverges from NIP_FQDN_WRP, then deploys + publishes the
# runtime snapshot. Idempotent: no-ops when already correct. Must run AFTER
# .acme-state is written and BEFORE the iviawrprp1 + iviaruntime restart.
_reconcile_mmfa_authenticator_client() {
    [[ -z "${NIP_FQDN_WRP:-}" ]] && return 0
    local target_uri="https://${NIP_FQDN_WRP}/mga/sps/mmfa/user/mgmt/html/mmfa/qr_code.html?client_id=AuthenticatorClient"
    local admin_pass
    admin_pass=$(kubectl --context workshop get secret -n verify-access iviaadmin \
        -o jsonpath='{.data.adminpw}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    if [[ -z "$admin_pass" ]]; then
        print_warn "Step 7: AuthenticatorClient reconcile skipped — iviaadmin secret unreadable"
        return 0
    fi

    local pf_port=$((30000 + RANDOM % 30000))
    kubectl --context workshop port-forward -n verify-access svc/iviaconfig "${pf_port}:9443" \
        >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 3

    local client_json
    client_json=$(curl -sk -u "admin:${admin_pass}" \
        "https://localhost:${pf_port}/iam/access/v8/clients" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d:
        if c.get('name') == 'AuthenticatorClient':
            print(json.dumps(c))
            break
except Exception:
    pass
" 2>/dev/null)

    if [[ -z "$client_json" ]]; then
        kill "$pf_pid" >/dev/null 2>&1
        wait "$pf_pid" 2>/dev/null
        print_warn "Step 7: AuthenticatorClient not found via LMI — skipping reconcile (autoconf may not have run yet)"
        return 0
    fi

    local live_uri client_id
    live_uri=$(echo "$client_json" | python3 -c "import json,sys;print(json.load(sys.stdin).get('redirectUri',''))" 2>/dev/null)
    client_id=$(echo "$client_json" | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

    if [[ "$live_uri" == "$target_uri" ]]; then
        print_info "Step 7: AuthenticatorClient redirectUri already staged on ${NIP_FQDN_WRP}"
    else
        print_info "Step 7: AuthenticatorClient redirectUri drift (live=${live_uri} target=${target_uri}); patching LMI"
        local put_body
        put_body=$(echo "$client_json" | TARGET_URI="$target_uri" python3 -c "
import json, os, sys
c = json.load(sys.stdin)
body = {
    'clientId': c.get('clientId', 'AuthenticatorClient'),
    'name': c.get('name', 'AuthenticatorClient'),
    'redirectUri': os.environ['TARGET_URI'],
    'companyName': c.get('companyName', 'OscarVault'),
    'contactType': c.get('contactType', 'TECHNICAL'),
    'requirePkce': c.get('requirePkce', False),
    'definition': c.get('definition', '1'),
    'introspectWithSecret': c.get('introspectWithSecret', True),
}
print(json.dumps(body))
" 2>/dev/null)

        local http_code
        http_code=$(curl -sk -u "admin:${admin_pass}" -X PUT \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -w '%{http_code}' -o /dev/null \
            "https://localhost:${pf_port}/iam/access/v8/clients/${client_id}" \
            --data-raw "$put_body" 2>/dev/null)

        if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
            print_pass "Step 7: AuthenticatorClient redirectUri patched → ${NIP_FQDN_WRP} (HTTP ${http_code})"
        else
            print_warn "Step 7: AuthenticatorClient LMI PUT returned HTTP ${http_code} — QR enrollment may dead-end on stale FQDN. Inspect: kubectl logs -n verify-access deploy/iviaconfig"
        fi
    fi

    # Publish LMI config to the runtime snapshot. iviaruntime boots from a
    # PUBLISHED snapshot, NOT the LMI live config — without regenerating +
    # publishing it, an iviaruntime restart re-downloads the OLD snapshot and
    # keeps enforcing the dead FQDN (issue #5). Canonical autoconf sequence:
    #   1. GET  /isam/pending_changes/deploy  (commit staged edits)
    #   2. PUT  /docker/publish               (regenerate the published snapshot)
    # Run unconditionally: the /iam client PUT does not always register as a
    # pending change, and deploy+publish from an unchanged config is idempotent.
    local deploy_code publish_code
    deploy_code=$(curl -sk -u "admin:${admin_pass}" \
        -H "Accept: application/json" -H "Content-type: application/json" \
        -w '%{http_code}' -o /dev/null \
        "https://localhost:${pf_port}/isam/pending_changes/deploy" 2>/dev/null)
    publish_code=$(curl -sk -u "admin:${admin_pass}" -X PUT \
        -H "Accept: application/json" -H "Content-type: application/json" \
        -w '%{http_code}' -o /dev/null \
        "https://localhost:${pf_port}/docker/publish" 2>/dev/null)
    if [[ "$publish_code" -ge 200 ]] && [[ "$publish_code" -lt 300 ]]; then
        print_pass "Step 7: deployed + published IVIA runtime snapshot (deploy HTTP ${deploy_code}, publish HTTP ${publish_code})"
    else
        print_warn "Step 7: IVIA /docker/publish returned HTTP ${publish_code} (deploy HTTP ${deploy_code}) — runtime may still serve stale OAuth client config; inspect: kubectl logs -n verify-access deploy/iviaconfig"
    fi

    kill "$pf_pid" >/dev/null 2>&1
    wait "$pf_pid" 2>/dev/null
    return 0
}

# Re-apply tier-2 module.ivia so the new NIP_FQDN_WRP flips effective_ivia_host
# → base_layer_hash re-render → autoconf re-publish → IVIA AAC DB MMFA endpoints
# + WRP Ingress host on nip.io, and the ivia_issuer output flips for Step 8.
# Idempotent: unchanged .acme-state produces no diff. vault_server is NOT
# targeted, so Vault is never touched (no re-seal risk).
_acme_apply_ivia() {
    if ! terraform -chdir="${SERVICES_DIR}" apply -auto-approve -input=false \
            -target=module.ivia; then
        print_fail "Step 7: tier-2 module.ivia re-apply" \
            "Re-run with TF_LOG=DEBUG. Check .acme-state has NIP_FQDN_WRP populated: cat ${ACME_STATE_FILE}"
        return 1
    fi
    return 0
}

# MANDATORY IVIA post-apply restart — autoconf omits k8s_deployments, so
# iviawrprp1 + iviaruntime keep stale base_layer/policy in memory (0x31 login
# error + FBTAUT003E policy reload). Surfaces failures as warnings (the ACM
# import already succeeded; a manual rollout restart resolves a stuck pod).
_acme_restart_ivia() {
    local _rc=0
    kubectl --context workshop -n verify-access rollout restart deploy/iviawrprp1 deploy/iviaruntime >/dev/null 2>&1
    _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        print_warn "Step 7: rollout restart iviawrprp1 + iviaruntime failed (rc=${_rc}). Run manually: kubectl --context workshop -n verify-access rollout restart deploy/iviawrprp1 deploy/iviaruntime"
        return 0
    fi
    kubectl --context workshop -n verify-access rollout status deploy/iviawrprp1 --timeout=180s >/dev/null 2>&1 \
        || print_warn "Step 7: rollout status iviawrprp1 did not reach Ready within 180s. Inspect: kubectl --context workshop -n verify-access describe deploy/iviawrprp1"
    kubectl --context workshop -n verify-access rollout status deploy/iviaruntime --timeout=180s >/dev/null 2>&1 \
        || print_warn "Step 7: rollout status iviaruntime did not reach Ready within 180s. Inspect: kubectl --context workshop -n verify-access describe deploy/iviaruntime"
    return 0
}

# Function wrapper allows `return 0/1` for the idempotency early-exit and the
# ALB-IP failure cases without aborting the whole script.
_run_acme_step() {
    # shellcheck disable=SC1090
    if [[ -f "$ACME_STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$ACME_STATE_FILE"
    fi

    # ALB-IP drift detection: on destroy+recreate the ALB gets new public IPs but
    # .acme-state survives — its NIP_FQDN_* then encode IPs that no longer route.
    # Multi-AZ ALBs publish 2-3 IPs; check whether the cached ALB_IP is STILL in
    # the live set (absent → real drift), not order-dependent dig head -1.
    if [[ -n "${ALB_IP:-}" ]]; then
        LIVE_ALB_HOST=$(kubectl --context workshop get ingress -n verify-access ivia-wrp \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [[ -n "$LIVE_ALB_HOST" ]]; then
            LIVE_ALB_IPS=$(_resolve_host_ips "$LIVE_ALB_HOST")
            # Herestring, not a pipe: a SIGPIPE-induced 141 under pipefail
            # would invert through the `!` and make this claim ALB drift on a
            # stable ALB — deleting .acme-state and forcing a needless re-issue.
            if [[ -n "$LIVE_ALB_IPS" ]] && ! grep -qx "$ALB_IP" <<<"$LIVE_ALB_IPS"; then
                LIVE_LIST=$(echo "$LIVE_ALB_IPS" | tr '\n' ',' | sed 's/,$//')
                print_info "Step 7: ALB IP drift detected (.acme-state=${ALB_IP} no longer in live ALB set [${LIVE_LIST}]). Clearing stale .acme-state and forcing re-issuance."
                rm -f "$ACME_STATE_FILE"
                rm -f "${ACME_STATE_FILE%.acme-state}.acme-rerun-marker"
                unset DEPLOY_ID ALB_IP ALB_IP_DASHED NIP_FQDN_WRP NIP_FQDN_BANKING STABLE_ACM_ARN
            fi
        fi
    fi

    ACME_RERUN_MARKER="${ACME_STATE_FILE%.acme-state}.acme-rerun-marker"
    # Idempotency early-return (D-12): when the stable ACM ARN is already LE-
    # issued, skip the slow ACME issuance + import path BUT still drive the
    # catch-up tier-2 module.ivia apply (reconciles post-source config changes)
    # + MMFA reconcile + IVIA restart. The iviaop agent-uc2 redirect_uri probe
    # is NOT here — that is a tier-3 concern handled unconditionally in Step 11.
    if [[ "$SKIP_ACME" != true ]] && [[ -n "${STABLE_ACM_ARN:-}" ]]; then
        CURRENT_ISSUER=$(aws acm describe-certificate \
            --certificate-arn "$STABLE_ACM_ARN" \
            --region "$REGION" \
            --query 'Certificate.Issuer' --output text 2>/dev/null || echo "")
        if [[ "$CURRENT_ISSUER" == *"Let's Encrypt"* ]]; then
            print_info "Step 7: ACME cert already Let's Encrypt-trusted; skipping issuance + import (D-12 idempotency floor) but running catch-up tier-2 module.ivia apply"
            _acme_apply_ivia || return 1
            _reconcile_mmfa_authenticator_client
            _acme_restart_ivia
            prior_skip_seen=$(grep -E '^SKIP_ACME_HONORED=' "${ACME_RERUN_MARKER}" 2>/dev/null | head -1 | cut -d= -f2 || echo "false")
            [[ "${prior_skip_seen}" = "true" ]] || prior_skip_seen="false"
            cat > "$ACME_RERUN_MARKER" <<MARKER
EXIT_CODE=0
LE_REISSUE_COUNT=0
SKIP_ACME_HONORED=${prior_skip_seen}
RERUN_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER
            print_pass "Step 7: ACME cert already trusted (Let's Encrypt issuer confirmed) + catch-up module.ivia apply reconciled"
            return 0
        fi
    fi

    if [[ "$SKIP_ACME" = true ]]; then
        cat > "$ACME_RERUN_MARKER" <<MARKER
EXIT_CODE=0
LE_REISSUE_COUNT=0
SKIP_ACME_HONORED=true
RERUN_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER
        print_info "Step 7: ACME skipped (--skip-acme)"
        PASSES+=("Step 7: ACME (skipped)")
        return 0
    fi

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would resolve shared workshop-acme ALB hostname (kubectl get ingress ivia-wrp)"
        print_info "[DRY-RUN] Would compute nip.io FQDNs and apply cert-manager Certificate CR (issuerRef.name=letsencrypt-prod)"
        print_info "[DRY-RUN] Would wait for Certificate Ready=true (timeout 300s)"
        print_info "[DRY-RUN] Would bootstrap: aws acm import-certificate --certificate-arn \$STABLE_ACM_ARN ..."
        print_info "[DRY-RUN] Would write ${ACME_STATE_FILE} with DEPLOY_ID/ALB_IP/NIP_FQDN_*/STABLE_ACM_ARN"
        print_info "[DRY-RUN] Would run: terraform -chdir=${SERVICES_DIR} apply -auto-approve -target=module.ivia"
        print_pass "Step 7: ACME cert issuance + ACM bootstrap sync (dry-run)"
        return 0
    fi

    # (1) Resolve the shared workshop-acme ALB hostname from the IVIA WRP Ingress.
    # The banking-UI Ingress does not exist yet (tier 3) — the WRP==banking
    # shared-ALB assertion runs post-tier-3 in Step 11.
    WRP_ALB=$(kubectl --context workshop get ingress -n verify-access ivia-wrp \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -z "$WRP_ALB" ]]; then
        print_fail "Step 7: workshop-acme ALB hostname" \
            "Could not resolve ALB hostname from IVIA WRP Ingress (ivia-wrp in verify-access). Wait for LBC reconciliation: kubectl --context workshop get ingress -n verify-access ivia-wrp"
        return 1
    fi

    # (2) Resolve ALB IP (nip.io encodes the IP into the hostname). Uses a
    # dig-free resolver (getent/python3 fallback) so it works in CloudShell.
    ALB_IP=$(_resolve_host_ips "$WRP_ALB" | head -1)
    if [[ -z "$ALB_IP" ]]; then
        print_fail "Step 7: ALB IP resolution" \
            "Could not resolve an IP for ${WRP_ALB} (tried getent/dig/python3). Confirm the ALB has converged: aws elbv2 describe-load-balancers --region ${REGION}"
        return 1
    fi
    ALB_IP_DASHED=$(echo "$ALB_IP" | tr '.' '-')

    # (3) DEPLOY_ID — generate fresh if missing, preserve on rerun (idempotency).
    if [[ -z "${DEPLOY_ID:-}" ]]; then
        DEPLOY_ID=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c6)
    fi
    if [[ -z "$DEPLOY_ID" ]] || [[ ${#DEPLOY_ID} -lt 6 ]]; then
        print_fail "Step 7: DEPLOY_ID generation" \
            "tr -dc 'a-z0-9' produced empty/short DEPLOY_ID='${DEPLOY_ID}' (expected 6 chars). Re-run with LC_ALL=C bash ${BASH_SOURCE[0]}"
        return 1
    fi
    NIP_FQDN_WRP="wrp.${DEPLOY_ID}.${ALB_IP_DASHED}.nip.io"
    NIP_FQDN_BANKING="banking.${DEPLOY_ID}.${ALB_IP_DASHED}.nip.io"

    # (4) STABLE_ACM_ARN — from tier-1 output (D-03 ARN-stability contract).
    STABLE_ACM_ARN=$(terraform -chdir="${INFRA_DIR}" \
        output -raw tls_certificate_arn 2>/dev/null || echo "")
    if [[ -z "$STABLE_ACM_ARN" ]]; then
        print_fail "Step 7: STABLE_ACM_ARN resolution" \
            "terraform -chdir=${INFRA_DIR} output -raw tls_certificate_arn returned empty. Confirm tier 1 is applied: cd ${INFRA_DIR} && terraform output tls_certificate_arn"
        return 1
    fi

    # (5) Render and apply the Certificate CR with both nip.io SANs. The banking
    # SAN's HTTP-01 challenge validates on the shared ALB via Plan 03's solver
    # Ingress (group.order=1) even before the tier-3 banking-ui Ingress exists.
    cat <<EOF | kubectl --context workshop apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: workshop-le-tls
  namespace: cert-manager
spec:
  secretName: workshop-le-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${NIP_FQDN_WRP}
    - ${NIP_FQDN_BANKING}
  renewBefore: 720h
EOF

    # (6) Wait for cert-manager to drive HTTP-01 to Ready, with auto-recovery.
    #
    # LE issues one authz per dnsNames entry (here: wrp + banking). Each authz
    # is validated by LE hitting the cert-manager solver pod through the shared
    # ALB. The ALB Load Balancer Controller takes 30-60s per solver Ingress to
    # register the target group + propagate the listener rule. If LE polls a
    # solver BEFORE its rule is live it gets EOF/connection-refused and marks
    # that single authz `errored` — even though the parallel banking authz
    # succeeds moments later when its rule IS live. The order stays `pending`
    # but the errored authz never auto-recovers, so the cert never goes Ready.
    #
    # Fix: poll for Ready up to 15 min; every cycle, delete any challenge in
    # state=errored — cert-manager auto-creates a fresh authz + solver Ingress,
    # the ALB has time to register, and LE re-validates against a live rule.
    # Attendees see one continuous spinner, no manual intervention.
    local _cert_deadline=$(( $(date +%s) + 900 ))   # 15 min hard ceiling
    local _cert_ready=false _cert_recovery_rounds=0
    while [[ $(date +%s) -lt ${_cert_deadline} ]]; do
        _cert_ready_status=$(kubectl --context workshop get certificate workshop-le-tls -n cert-manager \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "$_cert_ready_status" == "True" ]]; then
            _cert_ready=true
            break
        fi
        # Re-trigger any errored challenges by deleting them — cert-manager
        # owns the lifecycle and will issue a fresh authz + solver Ingress.
        local _errored
        _errored=$(kubectl --context workshop get challenges.acme.cert-manager.io \
            -n cert-manager -o jsonpath='{range .items[?(@.status.state=="errored")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        if [[ -n "${_errored}" ]]; then
            _cert_recovery_rounds=$(( _cert_recovery_rounds + 1 ))
            while IFS= read -r _ch; do
                kubectl --context workshop delete challenge "${_ch}" \
                    -n cert-manager --ignore-not-found >/dev/null 2>&1
            done <<< "${_errored}"
            print_info "Step 7: re-triggered $(echo "${_errored}" | wc -l | tr -d ' ') errored ACME challenge(s) (recovery round ${_cert_recovery_rounds}); continuing to wait"
        fi
        sleep 15
    done
    if [[ "${_cert_ready}" != true ]]; then
        print_fail "Step 7: Certificate Ready=true" \
            "cert-manager did not mark workshop-le-tls Ready within 900s (after ${_cert_recovery_rounds} auto-recovery rounds). Investigate: kubectl describe certificate/workshop-le-tls -n cert-manager; kubectl get challenges,orders -n cert-manager"
        return 1
    fi

    # (7) Bootstrap ACM import — extract the K8s Secret + upsert into the stable
    # ARN the ACM-sync CronJob uses. `base64 --decode` is the portable spelling
    # (BSD base64 on macOS rejects -d). cert-manager concatenates leaf +
    # intermediate(s) into tls.crt; ACM wants leaf in --certificate and the rest
    # in --certificate-chain, so split on the first BEGIN CERTIFICATE.
    kubectl --context workshop get secret workshop-le-tls-secret -n cert-manager \
        -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/tls-bundle.pem
    kubectl --context workshop get secret workshop-le-tls-secret -n cert-manager \
        -o jsonpath='{.data.tls\.key}' | base64 --decode > /tmp/tls.key
    awk '/-----BEGIN CERTIFICATE-----/{n++} n==1{print > "/tmp/tls.crt"} n>1{print > "/tmp/chain.pem"}' /tmp/tls-bundle.pem
    rm -f /tmp/tls-bundle.pem
    if [[ ! -s /tmp/tls.crt ]] || [[ ! -s /tmp/chain.pem ]]; then
        rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem
        print_fail "Step 7: split leaf/chain" \
            "Failed to split tls.crt bundle (leaf=$(stat -f%z /tmp/tls.crt 2>/dev/null || echo 0)B, chain=$(stat -f%z /tmp/chain.pem 2>/dev/null || echo 0)B). Inspect: kubectl get secret workshop-le-tls-secret -n cert-manager -o jsonpath='{.data.tls\\.crt}' | base64 --decode"
        return 1
    fi

    if ! aws acm import-certificate \
            --certificate-arn "$STABLE_ACM_ARN" \
            --certificate "fileb:///tmp/tls.crt" \
            --private-key "fileb:///tmp/tls.key" \
            --certificate-chain "fileb:///tmp/chain.pem" \
            --region "$REGION" >/dev/null; then
        rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem
        print_fail "Step 7: aws acm import-certificate" \
            "Bootstrap ACM upsert failed. Debug: aws acm describe-certificate --certificate-arn ${STABLE_ACM_ARN} --region ${REGION}"
        return 1
    fi
    rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem

    # (8) Persist .acme-state — consumed by tier-2 (nip_io_wrp_host) + tier-3
    # (NIP_FQDN_BANKING) + verify-tls.sh + this step on the next rerun.
    cat > "$ACME_STATE_FILE" <<EOF
DEPLOY_ID=${DEPLOY_ID}
ALB_IP=${ALB_IP}
ALB_IP_DASHED=${ALB_IP_DASHED}
NIP_FQDN_WRP=${NIP_FQDN_WRP}
NIP_FQDN_BANKING=${NIP_FQDN_BANKING}
STABLE_ACM_ARN=${STABLE_ACM_ARN}
EOF

    # (9) Re-apply tier-2 module.ivia so IVIA re-wires to the nip.io FQDN and the
    # ivia_issuer output flips before vault-configure (Step 8) reads it.
    _acme_apply_ivia || return 1

    # (10) Reconcile MMFA AuthenticatorClient.redirectUri, then restart WRP +
    # runtime so they re-read the AAC DB / base_layer.
    _reconcile_mmfa_authenticator_client
    _acme_restart_ivia

    print_pass "Step 7: ACME cert issued + imported (${NIP_FQDN_WRP}, ${NIP_FQDN_BANKING}); module.ivia converged on nip.io; iviawrprp1+iviaruntime rolled"
    return 0
}

step_07_acme_cert_issuance() {
    echo ""
    echo -e "${YELLOW}> Step 7: ACME cert issuance + ACM bootstrap sync${NC}"
    _run_acme_step
}

#===============================================================================
# STEP 8: Configure Vault (vault-configure.sh) — reads tier-1 + tier-2 state
#
# Creates the kubernetes/ + jwt/ auth backends, database/ + sts/ secrets
# engines, policies, and the uc1/uc2/uc3 roles the tier-3 pods authenticate
# with. MUST run before the tier-3 apply (Step 10) or the pods 403 on startup.
# Binds the JWT bound_issuer to tier-2's ivia_issuer (now nip.io after Step 7).
#===============================================================================
step_08_configure_vault() {
    echo ""
    echo -e "${YELLOW}> Step 8: Configure Vault${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: vault-configure.sh"
        print_pass "Step 8: Configure Vault (dry-run)"
    else
        if _run_subscript "Step 8: vault-configure" "${SCRIPT_DIR}/vault-configure.sh"; then
            # Best-effort confirm the post-cutover auth surface (warn-only):
            # kubernetes/ PRESENT and jwt/ ABSENT. The IVIA jwt auth backend was
            # retired in the native Agent Registry cutover (locked decision (e))
            # — UC2/UC3 present the OAuth JWT via X-Vault-Token against the
            # oauth-resource-server profile, so nothing mounts jwt/ any more.
            # This gate used to REQUIRE jwt/ and could therefore never pass;
            # it now mirrors test-vault-verify.sh Check 13.
            kubectl --context workshop port-forward svc/vault -n vault 8200:8200 \
                >/dev/null 2>&1 &
            VAULT_PF_PID=$!
            if _wait_for_port 8200 30; then
                ROOT_TOKEN=""
                if [[ -f "${HOME}/vault-init.json" ]]; then
                    ROOT_TOKEN=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || echo "")
                fi
                if [[ -n "$ROOT_TOKEN" ]]; then
                    AUTH_LIST=$(VAULT_ADDR="http://localhost:8200" VAULT_TOKEN="$ROOT_TOKEN" \
                        vault auth list -format=json 2>/dev/null || echo '{}')
                    K8S_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "kubernetes/")' 2>/dev/null || echo "")
                    JWT_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "jwt/")' 2>/dev/null || echo "")
                    if [[ -z "$K8S_ENABLED" ]]; then
                        print_warn "Step 8: kubernetes/ auth method not visible — vault-configure reported success; inspect manually if tier-3 pods 403"
                    elif [[ -n "$JWT_ENABLED" ]]; then
                        print_warn "Step 8: retired jwt/ auth mount is STILL present — the native cutover is incomplete. Disable it: kubectl exec -n vault vault-0 -- vault auth disable jwt"
                    else
                        print_pass "Step 8: Configure Vault (kubernetes/ auth enabled, retired jwt/ mount absent)"
                    fi
                else
                    print_warn "Step 8: Could not verify Vault auth — root token not found in ~/vault-init.json"
                fi
            else
                print_warn "Step 8: Could not verify Vault auth via port-forward"
            fi
            if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
                kill "$VAULT_PF_PID" 2>/dev/null || true
                VAULT_PF_PID=""
            fi
        else
            _die "Step 8: vault-configure" "tier-3 pods authenticate to Vault with the roles this step creates. Re-run: ${SCRIPT_DIR}/vault-configure.sh"
        fi
    fi
}

#===============================================================================
# STEP 9: Configure IVIA (ivia-configure.sh)
#===============================================================================
step_09_configure_ivia() {
    echo ""
    echo -e "${YELLOW}> Step 9: Configure IVIA${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: ivia-configure.sh"
        print_pass "Step 9: Configure IVIA (dry-run)"
    else
        if _run_subscript "Step 9: ivia-configure" "${SCRIPT_DIR}/ivia-configure.sh"; then
            # Step 7 has just rolled iviaruntime + iviawrprp1, so the OIDC
            # provider is normally still coming up when we get here. A single
            # curl after a fixed 3s sleep warned on a healthy deploy every time;
            # retry with backoff instead and only warn once the endpoint has
            # genuinely had time to answer.
            IVIA_HEALTH=""
            # NOT `kubectl ... | grep -q Running`: under `set -o pipefail`
            # (line 87) `grep -q` exits on its first match and SIGPIPEs kubectl
            # mid-write, so the pipeline reports 141 and this guard evaluates
            # FALSE on a perfectly healthy namespace. That is what produced the
            # "Could not verify IVIA OIDC health endpoint" WARN on green deploys
            # — the retry loop below never ran at all. Capture first, then match.
            _ivia_pods=$(kubectl --context workshop get pods -n verify-access --no-headers 2>/dev/null || true)
            if grep -q Running <<<"$_ivia_pods"; then
                kubectl --context workshop port-forward \
                    svc/iviaop -n verify-access 8436:8436 \
                    >/dev/null 2>&1 &
                _IVIA_PF_PID=$!
                # NOT _wait_for_port here — that helper probes Vault's
                # /v1/sys/health and can never succeed against IVIA. Retry the
                # real OIDC discovery call instead; the first attempts double as
                # the wait for the port-forward to come up.
                for _ivia_try in $(seq 1 12); do
                    IVIA_HEALTH=$(curl -sk --max-time 10 \
                        "https://localhost:8436/oauth2/.well-known/openid-configuration" \
                        2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")
                    [[ -n "$IVIA_HEALTH" ]] && break
                    print_info "Step 9: IVIA OIDC endpoint not answering yet (attempt ${_ivia_try}/12) — retrying in 10s"
                    sleep 10
                done
                kill "$_IVIA_PF_PID" 2>/dev/null || true
            fi
            if [[ -n "$IVIA_HEALTH" ]]; then
                print_pass "Step 9: Configure IVIA (OIDC issuer: ${IVIA_HEALTH})"
            else
                print_warn "Step 9: Could not verify IVIA OIDC health endpoint (IVIA may still be starting)"
            fi
        fi
    fi
}

#===============================================================================
# STEP 10: terraform apply — tier 3 (workloads: uc1/uc2/uc3 + iviaop patch)
#
# Creates the end-user app Deployments (images already in ECR from Step 3) +
# the agent-uc2 redirect_uri patch (banking nip FQDN from .acme-state). Then
# rolls each app Deployment so a re-run pulls the freshly pushed :latest image.
#===============================================================================
step_10_apply_tier3() {
    echo ""
    echo -e "${YELLOW}> Step 10: Apply tier 3 (workloads)${NC}"
    _tf_apply_tier "Step 10: Apply tier 3 (workloads)" "${WORKLOADS_DIR}" \
        -var "image_source=${IMAGE_SOURCE}" \
        -var "ghcr_registry_base=${GHCR_REGISTRY_BASE}"

    # Post-tier-3 repull/roll loop — ECR mode only: in ghcr mode the pinned :v1
    # tag + IfNotPresent pull policy needs no roll; kubelet uses the cached digest.
    if [[ "$IMAGE_SOURCE" = "ecr" ]]; then
        if [[ "$DRY_RUN" = true ]]; then
            print_info "[DRY-RUN] Would roll Deployments: ${APP_DEPLOYMENTS[*]}"
        else
            rolled=0
            for entry in "${APP_DEPLOYMENTS[@]}"; do
                ns="${entry%%:*}"
                dep="${entry#*:}"
                if kubectl --context workshop get deploy "$dep" -n "$ns" >/dev/null 2>&1; then
                    kubectl --context workshop rollout restart "deploy/${dep}" -n "$ns" >/dev/null 2>&1 \
                        && rolled=$((rolled + 1))
                fi
            done
            print_pass "Step 10: tier-3 Deployments rolled (${rolled}/${#APP_DEPLOYMENTS[@]})"
        fi
    else
        print_info "Step 10: Deployment roll skipped (${IMAGE_SOURCE} mode — pre-built :v1 images, IfNotPresent pull policy)"
    fi
}

#===============================================================================
# STEP 11: Post-tier-3 shared-ALB assertion + iviaop agent-uc2 redirect reconcile
#===============================================================================
_run_post_tier3_step() {
    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would assert IVIA WRP + banking-UI Ingresses share one ALB (workshop-acme group)"
        print_info "[DRY-RUN] Would probe iviaop agent-uc2 redirect_uri and recycle iviaop if stale"
        print_pass "Step 11: post-tier-3 reconcile (dry-run)"
        return 0
    fi

    # shellcheck disable=SC1090
    [[ -f "$ACME_STATE_FILE" ]] && source "$ACME_STATE_FILE"

    # (1) Shared-ALB assertion — both browser-facing Ingresses now exist and MUST
    # resolve to the SAME ALB (Plan 02 workshop-acme IngressGroup). Poll for the
    # banking ALB to converge (LBC attaches it ~30-60s after Ingress create).
    local wrp_alb banking_alb waited=0
    wrp_alb=$(kubectl --context workshop get ingress -n verify-access ivia-wrp \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    banking_alb=$(kubectl --context workshop get ingress -n banking-app banking-ui-ingress \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    while [[ -z "$banking_alb" ]] && [[ $waited -lt 180 ]]; do
        sleep 10
        waited=$((waited + 10))
        banking_alb=$(kubectl --context workshop get ingress -n banking-app banking-ui-ingress \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    done

    if [[ -z "$wrp_alb" ]] || [[ -z "$banking_alb" ]]; then
        print_warn "Step 11: could not resolve both Ingress ALBs (WRP='${wrp_alb}' banking='${banking_alb}') after ${waited}s — banking TLS may not be on the shared ALB yet. Inspect: kubectl --context workshop get ingress -A | grep alb"
    elif [[ "$wrp_alb" != "$banking_alb" ]]; then
        _die "Step 11: shared workshop-acme ALB" \
            "IVIA WRP and banking-UI Ingresses resolved to DIFFERENT ALBs (WRP=${wrp_alb}, banking=${banking_alb}). The alb.ingress.kubernetes.io/group.name=workshop-acme annotation is not effective on BOTH — verify: kubectl --context workshop get ingress -A -o yaml | grep -A1 group.name"
    else
        print_pass "Step 11: IVIA WRP + banking-UI share one ALB (${wrp_alb})"
    fi

    # (2) iviaop agent-uc2 redirect_uri reconcile — tier 3 applied the
    # iviaop_clients_patch (agent-uc2 redirect_uri = banking nip FQDN) +
    # null_resource.iviaop_rollout_restart. The restart only fires when its
    # sha256 trigger changes; probe the live in-memory clients.yml and force a
    # recycle if iviaop is still on a stale redirect_uri.
    if [[ -n "${NIP_FQDN_BANKING:-}" ]]; then
        local expected_redirect_uri live_redirect_uri
        expected_redirect_uri="https://${NIP_FQDN_BANKING}/callback"
        live_redirect_uri=$(kubectl --context workshop -n verify-access exec deploy/iviaop -- \
            grep -A1 "client_id: agent-uc2" /var/isvaop/config/clients.yml 2>/dev/null \
            | grep -oE 'https://[^"]+/callback' | head -1 || echo "")
        if [[ -n "${live_redirect_uri}" ]] && [[ "${live_redirect_uri}" != "${expected_redirect_uri}" ]]; then
            print_info "Step 11: iviaop in-memory clients.yml stale (${live_redirect_uri} != ${expected_redirect_uri}); recycling iviaop pod"
            kubectl --context workshop -n verify-access delete pod -l app=iviaop --wait=true >/dev/null 2>&1 || true
            kubectl --context workshop -n verify-access rollout status deploy/iviaop --timeout=180s >/dev/null 2>&1 || true
            print_pass "Step 11: iviaop recycled — agent-uc2 redirect_uri now ${expected_redirect_uri}"
        else
            print_pass "Step 11: iviaop agent-uc2 redirect_uri already on ${NIP_FQDN_BANKING:-<unset>}"
        fi
    fi
    return 0
}

step_11_post_tier3_reconcile() {
    echo ""
    echo -e "${YELLOW}> Step 11: Post-tier-3 shared-ALB assertion + iviaop reconcile${NC}"
    _run_post_tier3_step
}

#===============================================================================
# STEP 12: Verify OpenLDAP user 'oscar' seeded by IVIA autoconf
#===============================================================================
step_12_verify_ldap_user() {
    echo ""
    echo -e "${YELLOW}> Step 12: Verify OpenLDAP user 'oscar' seeded${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would query in-cluster OpenLDAP for cn=oscar"
        print_pass "Step 12: OpenLDAP user check (dry-run)"
    else
        LDAP_PW=$(kubectl --context workshop get secret openldap-creds -n verify-access -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
        LDAP_OSCAR=""
        if [ -n "${LDAP_PW}" ]; then
            LDAP_OSCAR=$(kubectl --context workshop exec -n verify-access deploy/openldap -- \
                ldapsearch -x -H ldapi:/// -D "cn=admin,dc=ibm,dc=com" -w "${LDAP_PW}" \
                -b "dc=ibm,dc=com" "(cn=oscar)" dn 2>/dev/null || true)
        fi
        if grep -q '^dn:' <<<"$LDAP_OSCAR"; then
            print_pass "Step 12: OpenLDAP user 'oscar' present (seeded by IVIA autoconf)"
        else
            print_warn "Step 12: OpenLDAP user 'oscar' NOT found — re-run the tier-2 apply or inspect ivia-autoconf job logs"
        fi
    fi
}

#===============================================================================
# STEP 13: Seed Banking DB (seed-banking-db.sh)
#===============================================================================
step_13_seed_banking_db() {
    echo ""
    echo -e "${YELLOW}> Step 13: Seed Banking DB${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: seed-banking-db.sh --region ${REGION}"
        print_pass "Step 13: Seed Banking DB (dry-run)"
    else
        if _run_subscript "Step 13: seed-banking-db" "${SCRIPT_DIR}/seed-banking-db.sh" --region "${REGION}"; then
            print_pass "Step 13: Seed Banking DB (script verified successfully)"
        else
            _die "Step 13: seed-banking-db" "Banking app has no data without this seed. Re-run: ${SCRIPT_DIR}/seed-banking-db.sh --region ${REGION}"
        fi
    fi
}

#===============================================================================
# STEP 14: Ingest Bedrock Knowledge Base corpus (sync-bedrock-kb.sh)
#
# Creating the KB data sources (tier-1 Terraform) does NOT embed the S3 corpus
# into the vector index — an explicit ingestion job is required, or the Use
# Case 1 agent's retrieve_from_knowledge_base tool returns zero passages.
# Idempotent: re-running starts a fresh ingestion job that converges.
#===============================================================================
step_14_sync_bedrock_kb() {
    echo ""
    echo -e "${YELLOW}> Step 14: Ingest Bedrock Knowledge Base corpus${NC}"

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: sync-bedrock-kb.sh"
        print_pass "Step 14: Ingest Bedrock Knowledge Base corpus (dry-run)"
    else
        if _run_subscript "Step 14: sync-bedrock-kb" "${SCRIPT_DIR}/sync-bedrock-kb.sh"; then
            print_pass "Step 14: Ingest Bedrock Knowledge Base corpus"
        else
            _die "Step 14: sync-bedrock-kb" "Use Case 1 agent returns zero passages without an ingested KB. Re-run: ${SCRIPT_DIR}/sync-bedrock-kb.sh"
        fi
    fi
}

#===============================================================================
# Main flow — call each step function via _run_if_tier so the same script
# drives both distributions:
#   - Workshop Studio (bare):  TIER="" runs every step (all 14)
#   - Instruqt tier-N:         TIER="N" runs only that tier's steps
# Idempotency contract (project CLAUDE.md): every step is safe to re-run, so
# running --tier 1 then --tier 2 then --tier 3 produces the same end state as
# a bare invocation, and re-running any tier converges.
#===============================================================================
_run_if_tier 1 step_01_apply_tier1
_run_if_tier 1 step_02_configure_kubectl
# At an event, Tier 1 is pre-provisioned, so the attendee's entry point is
# --tier 2 (and later --tier 3) — the tier-1 call above never runs for them,
# yet steps 5-14 shell out to `kubectl --context workshop`, so the first such
# call fails (e.g. "vault" namespace not found). update-kubeconfig is idempotent;
# re-run it at those entry points. (Bare mode already configured it above.)
[[ "$TIER" == "2" || "$TIER" == "3" ]] && step_02_configure_kubectl
_run_if_tier 1 step_03_build_push_images
_run_if_tier 1 step_04_lbc_readiness_gate
_run_if_tier 2 step_05_apply_tier2
_run_if_tier 2 step_06_initialize_vault
_run_if_tier 2 step_07_acme_cert_issuance
_run_if_tier 2 step_08_configure_vault
_run_if_tier 2 step_09_configure_ivia
_run_if_tier 3 step_10_apply_tier3
_run_if_tier 3 step_11_post_tier3_reconcile
_run_if_tier 3 step_12_verify_ldap_user
_run_if_tier 3 step_13_seed_banking_db
_run_if_tier 3 step_14_sync_bedrock_kb

#===============================================================================
# Summary is emitted by the EXIT trap (_cleanup)
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Deploy Complete${NC}"
echo -e "${BLUE}================================================================${NC}"
