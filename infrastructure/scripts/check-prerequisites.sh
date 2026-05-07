#!/usr/bin/env bash
#===============================================================================
# check-prerequisites.sh — thin wrapper around preflight.sh
#
# Exists for naming-convention compatibility with the eks-terraform-stacks
# workshop pattern (where workshop-e2e.sh calls check-prerequisites.sh). This
# repo's broader prereq logic lives in preflight.sh; this wrapper just delegates.
#===============================================================================

# shellcheck disable=SC2093
exec "$(cd "$(dirname "$0")" && pwd)/preflight.sh" "$@"
