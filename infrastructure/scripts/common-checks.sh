#!/usr/bin/env bash
#===============================================================================
# Common helpers for the workshop pre-flight check-*.sh scripts
#
# Source from each check script:
#   source "$(dirname "$0")/common-checks.sh"
#
# Provides:
#   - Color constants (RED, GREEN, YELLOW, BLUE, NC)
#   - print_pass / print_fail / print_warn / print_info helpers (unicode markers
#     ✓ / ✗ / ⚠ / ℹ — CONTEXT mandate)
#   - FAILURES[] accumulator
#   - print_summary() consolidated summary block
#   - Opt-in EXIT trap that emits the summary block on script exit
#
# Per CONTEXT (.planning/phases/01-scaffold-and-pre-flight/01-CONTEXT.md):
#   - Continue running all checks regardless of failures (no `set -e`)
#   - Emit a single consolidated summary at the end with full inline
#     copy-paste remediation per failure
#
# Per RESEARCH (Anti-pattern §): scripts that source this file MUST NOT use
# `set -e` — that would abort on the first failed check and defeat the
# continue-on-failure design.
#
# install-prereqs.sh DOES use `set -e` (it is an installer, not a checker), so
# it sets COMMON_CHECKS_SUMMARY=0 before sourcing this file. That suppresses
# the EXIT trap so a failed `apt-get install` cascade is not masked by an
# "All checks passed" summary banner from this trap.
#===============================================================================

# Bash 4+ guard (Pitfall §3 — macOS ships bash 3.2; brew install bash for 5.x)
# `declare -a` and `${var,,}` lowercasing both require bash 4+.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4+ required (macOS ships bash 3.2)" >&2
    echo "       Fix: brew install bash, then re-run with /opt/homebrew/bin/bash or /usr/local/bin/bash" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# Color constants
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Failure accumulator
#
# Each entry is "<check-name><US><remediation>" where <US> is the ASCII unit
# separator (\x1f). We use \x1f instead of `::` because remediation strings
# often contain colons (URLs, IAM ARNs, file paths, AWS CLI commands).
#-------------------------------------------------------------------------------
declare -a FAILURES=()

#-------------------------------------------------------------------------------
# Print helpers
# print_fail takes TWO arguments: the failure name, and the remediation text.
# Both are stored in FAILURES[] for the summary block.
#-------------------------------------------------------------------------------
print_pass() {
    echo -e "  ${GREEN}✓ PASS${NC} $1"
}

print_fail() {
    local name="$1"
    local remediation="${2:-No remediation provided}"
    echo -e "  ${RED}✗ FAIL${NC} $name"
    FAILURES+=("${name}"$'\x1f'"${remediation}")
}

print_warn() {
    echo -e "  ${YELLOW}⚠ WARN${NC} $1"
}

print_info() {
    echo -e "  ${BLUE}ℹ INFO${NC} $1"
}

#-------------------------------------------------------------------------------
# Summary block
#
# Prints a consolidated summary listing every accumulated failure with its
# inline copy-paste remediation. Returns:
#   0 — no failures
#   1 — one or more failures (so callers / EXIT trap can propagate via `exit $?`)
#-------------------------------------------------------------------------------
print_summary() {
    echo
    echo -e "${BLUE}===============================================================================${NC}"
    if [ ${#FAILURES[@]} -eq 0 ]; then
        echo -e "${GREEN} ✓ All checks passed${NC}"
        echo -e "${BLUE}===============================================================================${NC}"
        return 0
    fi

    echo -e "${RED} ✗ ${#FAILURES[@]} check(s) failed:${NC}"
    echo -e "${BLUE}===============================================================================${NC}"
    local i=1
    for entry in "${FAILURES[@]}"; do
        local name="${entry%%$'\x1f'*}"
        local remediation="${entry#*$'\x1f'}"
        echo -e "  ${RED}${i}. ✗${NC} ${name}"
        echo -e "     ${YELLOW}Fix:${NC} ${remediation}"
        echo
        i=$((i + 1))
    done
    echo -e "${BLUE}===============================================================================${NC}"
    return 1
}

#-------------------------------------------------------------------------------
# Opt-in EXIT trap
#
# Default behavior: register an EXIT trap that emits print_summary on exit.
# Installer scripts (install-prereqs.sh) set COMMON_CHECKS_SUMMARY=0 before
# sourcing this file to opt out — otherwise a `set -e` install abort would be
# masked by an "All checks passed" banner from this trap.
#-------------------------------------------------------------------------------
: "${COMMON_CHECKS_SUMMARY:=1}"
if [ "$COMMON_CHECKS_SUMMARY" = "1" ]; then
    trap 'print_summary; exit $?' EXIT
fi
