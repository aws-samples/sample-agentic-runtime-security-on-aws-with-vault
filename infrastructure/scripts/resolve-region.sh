#!/usr/bin/env bash
#===============================================================================
# resolve-region.sh — shared region-resolution helper
#
# Sourced by test-*.sh and orchestrators. Exports RESOLVED_REGION.
#
# Resolution order (per project canonical-region contract):
#   1. CLI arg passed to caller (caller must pre-set CLI_REGION before sourcing)
#   2. $AWS_REGION env var
#   3. region value parsed from infrastructure/terraform.tfvars
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

    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local tfvars="${repo_root}/infrastructure/terraform.tfvars"
    local tfvars_example="${repo_root}/infrastructure/terraform.tfvars.example"

    for f in "$tfvars" "$tfvars_example"; do
        if [ -f "$f" ]; then
            parsed=$(grep -E '^\s*region\s*=\s*"' "$f" 2>/dev/null \
                | head -1 \
                | sed -E 's/.*"([^"]+)".*/\1/')
            if [ -n "$parsed" ]; then
                RESOLVED_REGION="$parsed"
                return 0
            fi
        fi
    done

    echo "ERROR: could not resolve region. Set --region <value>, AWS_REGION env var, or ensure terraform.tfvars contains 'region = \"<value>\"'." >&2
    return 1
}
