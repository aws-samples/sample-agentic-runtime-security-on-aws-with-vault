#!/usr/bin/env bash
################################################################################
# E2E Validation Runner
# Lints workshop scripts: shebang, bash -n syntax, optional shellcheck,
# Bash 4+ guard on cleanup-orphaned-resources.sh, and "no base64 -d" usage.
# Does NOT deploy or connect to any services.
#
# Usage: ./e2e-validate.sh
################################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CHECKS_PASSED=0
CHECKS_FAILED=0

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[PASS]${NC} $name"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $name"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  E2E Validation Runner${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo ""

################################################################################
# Phase 1: Shebang Consistency
################################################################################
echo -e "${YELLOW}Phase 1: Shebang Consistency${NC}"
for script in "$SCRIPT_DIR"/*.sh; do
    script_name="$(basename "$script")"
    first_line="$(head -1 "$script")"
    check "Shebang: $script_name" test "$first_line" = "#!/usr/bin/env bash"
done
echo ""

################################################################################
# Phase 2: Script Syntax Validation
################################################################################
echo -e "${YELLOW}Phase 2: Script Syntax Validation${NC}"
for script in "$SCRIPT_DIR"/*.sh; do
    script_name="$(basename "$script")"
    check "Syntax: $script_name" bash -n "$script"
done
echo ""

################################################################################
# Phase 3: ShellCheck (optional)
################################################################################
echo -e "${YELLOW}Phase 3: ShellCheck (optional)${NC}"
if command -v shellcheck >/dev/null 2>&1; then
    for script in "$SCRIPT_DIR"/*.sh; do
        script_name="$(basename "$script")"
        check "ShellCheck: $script_name" shellcheck -S warning "$script"
    done
else
    echo -e "  ${YELLOW}[SKIP]${NC} shellcheck not installed -- install with: brew install shellcheck"
fi
echo ""

################################################################################
# Phase 4: Cross-Platform Compatibility
################################################################################
echo -e "${YELLOW}Phase 4: Cross-Platform Compatibility${NC}"

# No "base64 -d" usage (macOS uses -D); [b] trick prevents self-match
# shellcheck disable=SC2016
check "No base64 -d usage" bash -c '! grep -n "| [b]ase64 -d" "$1"/*.sh' _ "$SCRIPT_DIR"

# cleanup-orphaned-resources.sh has Bash 4+ guard (uses declare -A)
check "Bash 4+ guard in cleanup-orphaned-resources.sh" \
    grep -q "BASH_VERSINFO" "$SCRIPT_DIR/cleanup-orphaned-resources.sh"

# No unguarded associative arrays
# shellcheck disable=SC2016
check "No unguarded associative arrays" bash -c '
    for script in "$1"/*.sh; do
        if grep -q "declare -A" "$script"; then
            if ! grep -q "BASH_VERSINFO" "$script"; then
                exit 1
            fi
        fi
    done
    exit 0
' _ "$SCRIPT_DIR"
echo ""

################################################################################
# Summary
################################################################################
echo -e "${BLUE}===============================================================================${NC}"
TOTAL=$((CHECKS_PASSED + CHECKS_FAILED))
if [ "$CHECKS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}=== Results: $CHECKS_PASSED passed, $CHECKS_FAILED failed (of $TOTAL checks) ===${NC}"
else
    echo -e "${RED}=== Results: $CHECKS_PASSED passed, $CHECKS_FAILED failed (of $TOTAL checks) ===${NC}"
fi
echo -e "${BLUE}===============================================================================${NC}"

exit "$CHECKS_FAILED"
