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

# Disable AWS CLI pager so commands don't block on `less`
export AWS_PAGER=""

# Shared Terraform provider plugin cache.
#
# The workshop runs `terraform init` across three roots (tier-1/2/3), each of
# which would otherwise download its own copy of every provider. The
# hashicorp/aws provider alone unpacks to ~700 MB, so three copies (~2 GB)
# overflow small home volumes -- notably AWS CloudShell, whose home is a fixed
# ~1 GB volume, producing `terraform init: no space left on device`. A shared
# plugin cache on the larger TMPDIR volume ($TMPDIR, /tmp in CloudShell) is
# populated once and symlinked into each root, so all three roots share a
# single copy off the home volume. Only set when unset so a caller-supplied
# TF_PLUGIN_CACHE_DIR (CI, Instruqt, etc.) is never overridden.
if [ -z "${TF_PLUGIN_CACHE_DIR:-}" ]; then
    export TF_PLUGIN_CACHE_DIR="${TMPDIR:-/tmp}/tf-plugin-cache"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
fi

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

#-------------------------------------------------------------------------------
# Container runtime detection (Podman OR Docker)
#
# The workshop builds + pushes the Use Case agent images with whichever OCI
# runtime the attendee has. detect_container_runtime exports
# WORKSHOP_CONTAINER_CLI=podman|docker; container_build abstracts the one
# behavioral difference between the two (Docker needs `buildx build --load`,
# Podman uses plain `build`). check-prerequisites.sh + the three build scripts
# all consume these two helpers.
#
# Preference order: podman -> docker. Podman is rootless-by-default, daemonless,
# and OCI-native; Docker remains a first-class fallback. Override the detection
# with WORKSHOP_CONTAINER_CLI=docker (or =podman) in the environment.
#
# Minimum Podman major version: plain `podman build --platform` needs Podman
# 4.0+. Older 3.x is rejected with an actionable error (it requires buildah).
#-------------------------------------------------------------------------------
PODMAN_MIN_MAJOR=4

# Best-effort version string for a runtime CLI; empty on failure. Uses the
# stable `--version` output (NOT `--format`, whose template field name varies
# across releases and can return empty — which would let the version floor
# fail-open).
_container_runtime_version() {
    case "$1" in
        docker) docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' ;;
        podman) podman --version 2>/dev/null | awk '{print $3}' ;;
    esac
}

# Validate Podman is usable: machine running (macOS) + version >= floor.
# Records a failure + returns 1 on any problem.
_validate_podman() {
    if ! podman info >/dev/null 2>&1; then
        if [ "$(uname)" = "Darwin" ]; then
            print_info "Podman detected but its machine is not running — attempting 'podman machine start'"
            podman machine start >/dev/null 2>&1 || true
        fi
        if ! podman info >/dev/null 2>&1; then
            print_fail "podman is installed but not responsive" \
                "macOS: run \`podman machine init && podman machine start\`. Linux: ensure rootless podman is configured (\`podman info\` must succeed). Or set WORKSHOP_CONTAINER_CLI=docker to use Docker instead."
            return 1
        fi
    fi
    local major
    major="$(_container_runtime_version podman | cut -d. -f1)"
    if [ -n "$major" ] && [ "$major" -lt "$PODMAN_MIN_MAJOR" ] 2>/dev/null; then
        print_fail "podman ${major}.x is too old (need >= ${PODMAN_MIN_MAJOR}.0)" \
            "Upgrade Podman to 4.0+ (https://podman.io/docs/installation), or set WORKSHOP_CONTAINER_CLI=docker to build with Docker instead."
        return 1
    fi
    return 0
}

# Validate Docker is usable: daemon up + buildx plugin present (the --load
# build path needs buildx).
_validate_docker() {
    if ! docker info >/dev/null 2>&1; then
        print_fail "docker is installed but the daemon is not running" \
            "Start Docker Desktop (macOS/Windows) or the docker service (Linux: \`sudo systemctl start docker\`), then re-run. The image build needs a running daemon."
        return 1
    fi
    if ! docker buildx version >/dev/null 2>&1; then
        print_fail "docker found but 'docker buildx' is not installed" \
            "Install the Buildx plugin (bundled with Docker Desktop 4+; minimal Linux: \`apt-get install docker-buildx-plugin\`, or https://github.com/docker/buildx#installing). Or set WORKSHOP_CONTAINER_CLI=podman."
        return 1
    fi
    return 0
}

# Detect + validate the container runtime; export WORKSHOP_CONTAINER_CLI.
# Preference podman -> docker; honors a pinned WORKSHOP_CONTAINER_CLI override.
# Idempotent (short-circuits once validated). Prints its own pass/fail line, so
# callers must NOT also print_pass. Returns 0 on success, 1 on failure — the
# caller decides whether to continue (check-prerequisites accumulates and keeps
# going) or `|| exit 1` (build scripts can't proceed without a runtime).
detect_container_runtime() {
    if [ "${_WORKSHOP_RUNTIME_OK:-0}" = "1" ] && [ -n "${WORKSHOP_CONTAINER_CLI:-}" ]; then
        return 0
    fi

    local cli="${WORKSHOP_CONTAINER_CLI:-}" pinned=false
    [ -n "$cli" ] && pinned=true

    if [ -z "$cli" ]; then
        if   command -v podman >/dev/null 2>&1; then cli=podman
        elif command -v docker >/dev/null 2>&1; then cli=docker
        else
            print_fail "no container runtime found (neither podman nor docker)" \
                "Install ONE of: Podman — macOS \`brew install podman && podman machine init && podman machine start\`, Linux https://podman.io/docs/installation; OR Docker — Desktop https://www.docker.com/products/docker-desktop/, Linux Engine https://docs.docker.com/engine/install/. The deploy builds + pushes the Use Case agent images with whichever is present."
            return 1
        fi
    fi

    if ! command -v "$cli" >/dev/null 2>&1; then
        print_fail "WORKSHOP_CONTAINER_CLI=${cli} but '${cli}' is not on PATH" \
            "Install ${cli}, or unset WORKSHOP_CONTAINER_CLI to auto-detect."
        return 1
    fi

    case "$cli" in
        podman) _validate_podman || return 1 ;;
        docker) _validate_docker || return 1 ;;
        *) print_fail "unsupported WORKSHOP_CONTAINER_CLI=${cli}" \
               "Supported values: podman, docker. Unset to auto-detect." ; return 1 ;;
    esac

    export WORKSHOP_CONTAINER_CLI="$cli"
    _WORKSHOP_RUNTIME_OK=1
    local v; v="$(_container_runtime_version "$cli")"
    local suffix=""; [ "$pinned" = true ] && suffix=" [pinned via WORKSHOP_CONTAINER_CLI]"
    print_pass "Container runtime: ${cli}${v:+ (v${v})}${suffix}"
    return 0
}

# Run a build with the detected runtime, abstracting ONLY the
# `buildx build --load` (docker) vs `build` (podman) difference. ALL build
# flags pass through verbatim, so --platform/--no-cache/--tag/--file/--build-arg/
# context all work, and the call survives banking-app's `run` dry-run wrapper.
#   container_build --platform linux/amd64 --no-cache \
#       --tag "$URI" --file "$DIR/Dockerfile" "$DIR"
container_build() {
    if [ "${WORKSHOP_CONTAINER_CLI}" = "docker" ]; then
        docker buildx build --load "$@"
    else
        podman build "$@"
    fi
}
