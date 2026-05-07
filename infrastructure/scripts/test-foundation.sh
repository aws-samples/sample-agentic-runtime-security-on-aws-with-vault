#!/usr/bin/env bash
#===============================================================================
# test-foundation.sh — wrapper that runs all 3 component tests in sequence
#
# Calls test-eks.sh, test-rds.sh, test-bedrock-kb.sh with the IDs derived from
# CLI args (or env vars). Prints a banner per component and exits non-zero if
# any sub-script failed.
#
# Usage:
#   ./test-foundation.sh \
#       --cluster-name <name> \
#       --db-instance-id <id> \
#       --knowledge-base-id <kb_id> \
#       [--region <region>]
#
# Env-var fallback:
#   WORKSHOP_CLUSTER_NAME, WORKSHOP_DB_INSTANCE_ID, WORKSHOP_KB_ID
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AWS_PAGER=""

CLUSTER_NAME="${WORKSHOP_CLUSTER_NAME:-}"
DB_ID="${WORKSHOP_DB_INSTANCE_ID:-}"
KB_ID="${WORKSHOP_KB_ID:-}"
CLI_REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name)      CLUSTER_NAME="$2"; shift ;;
        --db-instance-id)    DB_ID="$2"; shift ;;
        --knowledge-base-id) KB_ID="$2"; shift ;;
        --region)            CLI_REGION="$2"; shift ;;
        --help|-h)
            cat <<USAGE
Usage: $0 --cluster-name <name> --db-instance-id <id> --knowledge-base-id <kb> [--region <region>]

Wraps test-eks.sh + test-rds.sh + test-bedrock-kb.sh. Aggregates results.

Env-var fallback (any unset --flag falls back to env):
  WORKSHOP_CLUSTER_NAME, WORKSHOP_DB_INSTANCE_ID, WORKSHOP_KB_ID
USAGE
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Suppress per-script EXIT-trap summary so we emit a single aggregated summary.
# (test-*.sh source common-checks.sh which installs the trap by default.)
export COMMON_CHECKS_SUMMARY=0

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"
# shellcheck source=resolve-region.sh
source "$SCRIPT_DIR/resolve-region.sh"
resolve_region "$CLI_REGION" || exit 1
REGION="$RESOLVED_REGION"

missing=()
[ -z "$CLUSTER_NAME" ] && missing+=("--cluster-name / WORKSHOP_CLUSTER_NAME")
[ -z "$DB_ID" ]        && missing+=("--db-instance-id / WORKSHOP_DB_INSTANCE_ID")
[ -z "$KB_ID" ]        && missing+=("--knowledge-base-id / WORKSHOP_KB_ID")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required inputs:" >&2
    for m in "${missing[@]}"; do echo "  - $m" >&2; done
    exit 1
fi

run_component() {
    local label="$1"; shift
    echo
    echo -e "${BLUE}===============================================================================${NC}"
    echo -e "${BLUE}  ${label}${NC}"
    echo -e "${BLUE}===============================================================================${NC}"
    if bash "$@"; then
        return 0
    else
        return 1
    fi
}

failures=0

run_component "EKS"        "$SCRIPT_DIR/test-eks.sh" \
    --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    || failures=$((failures + 1))

run_component "RDS"        "$SCRIPT_DIR/test-rds.sh" \
    --db-instance-id "$DB_ID" --region "$REGION" \
    || failures=$((failures + 1))

run_component "Bedrock KB" "$SCRIPT_DIR/test-bedrock-kb.sh" \
    --knowledge-base-id "$KB_ID" --region "$REGION" \
    || failures=$((failures + 1))

echo
echo -e "${BLUE}===============================================================================${NC}"
if [ "$failures" -eq 0 ]; then
    echo -e "${GREEN}  Foundation verification: ALL 3 components passed${NC}"
else
    echo -e "${RED}  Foundation verification: ${failures} component(s) FAILED${NC}"
fi
echo -e "${BLUE}===============================================================================${NC}"

exit "$failures"
