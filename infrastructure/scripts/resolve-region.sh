#!/usr/bin/env bash
#===============================================================================
# resolve-region.sh — shared region-resolution helper
#
# Sourced by test-*.sh and orchestrators. Exports RESOLVED_REGION.
#
# Resolution order (per project canonical-region contract):
#   1. CLI arg passed to caller (caller must pre-set CLI_REGION before sourcing)
#   2. $AWS_REGION env var
#   3. region value parsed from infrastructure/deployments.tfdeploy.hcl
#
# Fail-fast (exit 1) if none resolve. NO string literal "us-west-2" anywhere
# in this file (project CLAUDE.md scope constraint).
#===============================================================================

# shellcheck disable=SC2034 # RESOLVED_REGION is consumed by sourcing scripts
resolve_region() {
    local cli_arg="${1:-}"
    local repo_root tfdeploy parsed

    if [ -n "$cli_arg" ]; then
        RESOLVED_REGION="$cli_arg"
        return 0
    fi

    if [ -n "${AWS_REGION:-}" ]; then
        RESOLVED_REGION="$AWS_REGION"
        return 0
    fi

    # Walk up from this script's dir to find infrastructure/deployments.tfdeploy.hcl
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    tfdeploy="${repo_root}/infrastructure/deployments.tfdeploy.hcl"

    if [ -f "$tfdeploy" ]; then
        # Match `region = "<value>"` inside the deployment block
        parsed=$(grep -E '^\s*region\s*=\s*"' "$tfdeploy" 2>/dev/null \
            | head -1 \
            | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$parsed" ]; then
            RESOLVED_REGION="$parsed"
            return 0
        fi
    fi

    echo "ERROR: could not resolve region. Set --region <value>, AWS_REGION env var, or ensure ${tfdeploy} contains 'region = \"<value>\"'." >&2
    return 1
}
