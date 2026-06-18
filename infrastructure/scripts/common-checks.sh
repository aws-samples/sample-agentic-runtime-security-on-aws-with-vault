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

# Disable AWS CLI pager so commands don't block on `less`
export AWS_PAGER=""

# Terminal capability probe (Plan 01-09 hardening)
#
# If the controlling terminal does not support color (tput colors < 8) OR
# stdout is not a TTY (e.g., output piped to less / redirected to a file /
# captured by a CI pipeline), set every color variable to empty so output
# is monochrome and unambiguous. This eliminates two failure modes:
#   1. Custom terminal palettes that remap ANSI 32 (green) to a reddish hue
#      — UAT test 9 surfaced this as user-perceived "passes rendered red"
#   2. Pipe-captured output where ANSI escapes leak into log files / pagers
#      as literal "\033[0;31m" garbage
#
# Override: set WORKSHOP_FORCE_COLOR=1 in the environment to bypass this
# probe and always emit color (useful for CI logs that DO render ANSI).

_color_capable=true
if [ "${WORKSHOP_FORCE_COLOR:-0}" != "1" ]; then
    if ! command -v tput >/dev/null 2>&1; then
        _color_capable=false
    elif ! [ -t 1 ]; then
        _color_capable=false
    else
        _tcolors=$(tput colors 2>/dev/null || echo 0)
        if [ "${_tcolors:-0}" -lt 8 ]; then
            _color_capable=false
        fi
    fi
fi

#-------------------------------------------------------------------------------
# Color constants
#-------------------------------------------------------------------------------
if [ "$_color_capable" = "true" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi
unset _color_capable _tcolors

#-------------------------------------------------------------------------------
# Failure accumulator
#
# Each entry is "<check-name><US><remediation>" where <US> is the ASCII unit
# separator (\x1f). We use \x1f instead of `::` because remediation strings
# often contain colons (URLs, IAM ARNs, file paths, AWS CLI commands).
#-------------------------------------------------------------------------------
declare -a FAILURES=()
declare -a PASSES=()

#-------------------------------------------------------------------------------
# Print helpers
# print_fail takes TWO arguments: the failure name, and the remediation text.
# Both are stored in FAILURES[] for the summary block.
#-------------------------------------------------------------------------------
print_pass() {
    local name="$1"
    echo -e "  ${GREEN}✓ PASS${NC} $name"
    PASSES+=("$name")
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
# Interactive confirm helper
#
# Prompts y/N from the controlling TTY (works even when caller piped stdin).
# Honors WORKSHOP_AUTO_YES=1 (auto-yes via flag) and non-TTY environments
# (auto-yes when stdin is not a terminal — preserves CI / Workshop Studio
# attendee VM compatibility). Returns 0 on Y, 1 on N or empty.
#
# Usage:
#   if confirm "Install kubectl?"; then run "brew install kubernetes-cli"; fi
#-------------------------------------------------------------------------------
confirm() {
    local prompt="${1:-Continue?}"
    # Auto-yes when --interactive is NOT in effect (WORKSHOP_AUTO_YES=1) or
    # stdin is not a terminal (CI / piped input). The caller controls the
    # default by setting or unsetting WORKSHOP_AUTO_YES before calling.
    if [ "${WORKSHOP_AUTO_YES:-0}" = "1" ] || [ ! -t 0 ]; then
        echo -e "  ${YELLOW}? ${prompt} [y/N]${NC} (auto-yes)"
        return 0
    fi
    local reply
    # Read from /dev/tty so the prompt works even if caller piped stdin
    read -p "  $(echo -e "${YELLOW}?${NC}") ${prompt} [y/N] " -r reply < /dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
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
    local pass_count=${#PASSES[@]}
    local fail_count=${#FAILURES[@]}

    # Green pass-count line — always print if any passes exist
    if [ "$pass_count" -gt 0 ]; then
        echo -e "${GREEN} ✓ ${pass_count} check(s) passed${NC}"
    fi

    if [ "$fail_count" -eq 0 ]; then
        if [ "$pass_count" -eq 0 ]; then
            # Edge case: no passes AND no failures (script aborted before any check ran)
            echo -e "${YELLOW} ⚠ No checks ran${NC}"
        fi
        echo -e "${BLUE}===============================================================================${NC}"
        return 0
    fi

    # Red fail-count line + per-failure enumeration
    echo -e "${RED} ✗ ${fail_count} check(s) failed:${NC}"
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
