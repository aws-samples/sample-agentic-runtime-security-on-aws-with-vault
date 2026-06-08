#!/usr/bin/env bash
#===============================================================================
# Workshop kubectl/helm context isolation — BLOCKING safety helper
#
# WHY: Bear's machine (and many attendee machines) carry multiple kubectl
# contexts — GKE / AKS / other AWS clusters / etc. A bare `kubectl` call (no
# `--context`) uses the user's CURRENT default context, which has no guarantee
# of being the workshop EKS cluster. On 2026-06-07 this routed `vault-init.sh`
# to a GKE Vault that was unrelated to the workshop, silently reporting
# "Vault is already initialized" while the real workshop Vault was untouched.
#
# WHAT: This file writes a PROCESS-ISOLATED kubeconfig at
#     ${WORKSHOP_KUBECONFIG:-/tmp/workshop-kubeconfig-<cluster_name>.yaml}
# containing ONLY the workshop EKS cluster (alias `workshop`), then exports
# KUBECONFIG to point there. After this runs:
#   - Bare `kubectl ...`        → workshop cluster (cannot escape)
#   - `kubectl --context workshop ...` → workshop cluster (alias matches)
#   - `helm ...`                → workshop cluster (helm respects $KUBECONFIG)
#
# HOW TO USE: source this file from the top of any script that touches kubectl
# or helm. Sourced indirectly by `common-checks.sh` so the ~17 scripts that
# already source `common-checks.sh` get it automatically.
#
# Opt-out: set WORKSHOP_CONTEXT_SKIP=true BEFORE sourcing. Used by scripts that
# run before the cluster exists (check-prerequisites.sh) or that wipe the
# cluster itself (teardown.sh full-nuke mode).
#
# Force refresh: set WORKSHOP_CONTEXT_REFRESH=true to regenerate the isolated
# kubeconfig (e.g. after `aws eks update-cluster-config` rotates the endpoint).
#===============================================================================

# Re-source guard — sourcing twice is harmless but skip the noisy aws call.
if [ "${_WORKSHOP_CONTEXT_LOADED:-false}" = true ] \
   && [ "${WORKSHOP_CONTEXT_REFRESH:-false}" != true ]; then
    return 0 2>/dev/null || exit 0
fi

_workshop_context_resolve_tfvars() {
    # Find infrastructure/terraform.tfvars walking up from the caller's location.
    local self_dir candidate
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "${TFVARS_FILE:-}" \
        "${self_dir}/../terraform.tfvars" \
        "$(pwd)/infrastructure/terraform.tfvars" \
        "$(pwd)/terraform.tfvars" \
        ; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

_workshop_context_read_var() {
    # Read `var = "value"` from terraform.tfvars (HCL).
    local file="$1" key="$2"
    grep -E "^\s*${key}\s*=" "$file" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

_workshop_context_setup() {
    if [ "${WORKSHOP_CONTEXT_SKIP:-false}" = true ]; then
        return 0
    fi

    local tfvars
    if ! tfvars=$(_workshop_context_resolve_tfvars); then
        cat >&2 <<EOF
FATAL [lib-workshop-context]: could not locate infrastructure/terraform.tfvars.
       Cannot enforce workshop-cluster isolation without it. If this script
       legitimately runs before the cluster exists, set
       WORKSHOP_CONTEXT_SKIP=true before sourcing.
EOF
        exit 1
    fi

    local _cluster _region
    _cluster=$(_workshop_context_read_var "$tfvars" "cluster_name")
    _region=$(_workshop_context_read_var "$tfvars" "region")
    # Allow env-var overrides (workshop-e2e.sh sets these explicitly).
    _cluster="${CLUSTER_NAME:-$_cluster}"
    _region="${AWS_REGION:-${WORKSHOP_REGION:-$_region}}"

    if [ -z "$_cluster" ] || [ -z "$_region" ]; then
        cat >&2 <<EOF
FATAL [lib-workshop-context]: cluster_name / region not set in $tfvars
       (cluster_name='$_cluster' region='$_region'). Cannot build isolated
       kubeconfig. Fix the tfvars file or set WORKSHOP_CONTEXT_SKIP=true.
EOF
        exit 1
    fi

    local kc="${WORKSHOP_KUBECONFIG:-/tmp/workshop-kubeconfig-${_cluster}.yaml}"
    if [ ! -f "$kc" ] || [ "${WORKSHOP_CONTEXT_REFRESH:-false}" = true ]; then
        # Single canonical alias `workshop` so all `--context workshop` calls
        # already in the codebase hit the right cluster after sourcing.
        if ! aws eks update-kubeconfig \
                --name "$_cluster" \
                --region "$_region" \
                --kubeconfig "$kc" \
                --alias "workshop" >/dev/null 2>&1; then
            cat >&2 <<EOF
FATAL [lib-workshop-context]: aws eks update-kubeconfig failed for
       cluster='$_cluster' region='$_region'.
       The isolated kubeconfig at $kc could not be written.
       Refusing to fall back to ~/.kube/config — that would let bare kubectl
       hit a non-workshop cluster (GKE / other AWS / etc).
       Verify: aws sts get-caller-identity
              aws eks describe-cluster --name $_cluster --region $_region
EOF
            exit 1
        fi
        chmod 600 "$kc" 2>/dev/null || true
    fi

    # Sanity: kubeconfig must have current-context = workshop.
    kubectl --kubeconfig="$kc" config use-context workshop >/dev/null 2>&1 || true

    export KUBECONFIG="$kc"
    export WORKSHOP_KUBECONFIG="$kc"
    export WORKSHOP_CLUSTER_NAME="$_cluster"
    export WORKSHOP_REGION_RESOLVED="$_region"
    export _WORKSHOP_CONTEXT_LOADED=true
}

_workshop_context_setup
