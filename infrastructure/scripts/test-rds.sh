#!/usr/bin/env bash
#===============================================================================
# test-rds.sh — verify the workshop RDS PostgreSQL instance is healthy
#
# Checks:
#   - DBInstanceStatus == available
#   - Engine == postgres, EngineVersion startswith "17"
#   - MasterUserSecret.SecretArn exists (managed master password)
#   - Parameter group: shared_preload_libraries contains pgaudit, pgaudit.log set
#   - StorageEncrypted == true
#
# Usage:
#   ./test-rds.sh --db-instance-id <id> [--region <region>]
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AWS_PAGER=""

DB_ID=""
CLI_REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --db-instance-id) DB_ID="$2"; shift ;;
        --region)         CLI_REGION="$2"; shift ;;
        --help|-h)
            cat <<USAGE
Usage: $0 --db-instance-id <id> [--region <region>]

Verifies the workshop RDS PostgreSQL instance: status, engine, secret, pgaudit,
encryption.
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

if [ -z "$DB_ID" ]; then
    echo "ERROR: --db-instance-id is required" >&2
    exit 1
fi

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"
# shellcheck source=resolve-region.sh
source "$SCRIPT_DIR/resolve-region.sh"
resolve_region "$CLI_REGION" || exit 1
REGION="$RESOLVED_REGION"

echo
echo -e "${BLUE}=== test-rds.sh ===${NC}"
echo -e "  DB instance: ${DB_ID}"
echo -e "  Region:      ${REGION}"
echo

# Single describe-db-instances call → JSON → field extraction
db_json=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --region "$REGION" --query 'DBInstances[0]' --output json 2>&1)

if [ -z "$db_json" ] || echo "$db_json" | grep -q "DBInstanceNotFound"; then
    print_fail "DB instance ${DB_ID} not found in ${REGION}" \
        "Run: aws rds describe-db-instances --db-instance-identifier ${DB_ID} --region ${REGION}. Verify the foundation Stack converged and the RDS module created the instance."
    # No further checks possible without the JSON
    exit 1
fi

# Status
status=$(echo "$db_json" | jq -r '.DBInstanceStatus // "unknown"')
if [ "$status" = "available" ]; then
    print_pass "Status: available"
else
    print_fail "Status: ${status} (require 'available')" \
        "Run: aws rds describe-db-instances --db-instance-identifier ${DB_ID} --region ${REGION} --query 'DBInstances[0].DBInstanceStatus'. If 'creating'/'modifying', wait. If 'failed', check Events tab in RDS console."
fi

# Engine + version
engine=$(echo "$db_json" | jq -r '.Engine // "unknown"')
engine_version=$(echo "$db_json" | jq -r '.EngineVersion // "unknown"')
if [ "$engine" = "postgres" ]; then
    print_pass "Engine: postgres"
else
    print_fail "Engine: ${engine} (require 'postgres')" \
        "The workshop pins PostgreSQL. Re-deploy the RDS module with engine = postgres."
fi
case "$engine_version" in
    17.*|17)
        print_pass "Engine version: ${engine_version} (>= 17)"
        ;;
    *)
        print_fail "Engine version: ${engine_version} (require 17.x)" \
            "Update the RDS module's engine_version to a 17.x release and re-apply."
        ;;
esac

# Master user secret
secret_arn=$(echo "$db_json" | jq -r '.MasterUserSecret.SecretArn // empty')
if [ -n "$secret_arn" ]; then
    print_pass "MasterUserSecret.SecretArn present"
else
    print_fail "MasterUserSecret.SecretArn missing" \
        "Re-apply the RDS module with manage_master_user_password = true so RDS rotates the password via Secrets Manager."
fi

# Storage encryption
encrypted=$(echo "$db_json" | jq -r '.StorageEncrypted // false')
if [ "$encrypted" = "true" ]; then
    print_pass "StorageEncrypted: true"
else
    print_fail "StorageEncrypted: ${encrypted} (require true)" \
        "Storage encryption cannot be enabled in-place. Re-create the RDS instance with storage_encrypted = true and a kms_key_id."
fi

# Parameter group: pgaudit
pg_name=$(echo "$db_json" | jq -r '.DBParameterGroups[0].DBParameterGroupName // empty')
if [ -z "$pg_name" ]; then
    print_fail "No DB parameter group attached" \
        "Attach a custom parameter group with shared_preload_libraries=pgaudit and pgaudit.log set."
else
    spl=$(aws rds describe-db-parameters --db-parameter-group-name "$pg_name" \
        --region "$REGION" \
        --query "Parameters[?ParameterName=='shared_preload_libraries'].ParameterValue | [0]" \
        --output text 2>/dev/null)
    if echo "$spl" | grep -q "pgaudit"; then
        print_pass "shared_preload_libraries contains pgaudit (pg=${pg_name})"
    else
        print_fail "shared_preload_libraries does NOT contain pgaudit (current: '${spl}')" \
            "Update the parameter group ${pg_name}: aws rds modify-db-parameter-group --db-parameter-group-name ${pg_name} --region ${REGION} --parameters 'ParameterName=shared_preload_libraries,ParameterValue=pgaudit,ApplyMethod=pending-reboot'. Reboot the instance to take effect."
    fi

    # NOTE: describe-db-parameters auto-paginates and the CLI applies --query to
    # EACH page, so `| [0]` emits one line per page — a multi-line blob that is
    # never equal to "None" and made this check impossible to fail. Aggregate
    # every page instead, drop the `None` placeholders the CLI prints for pages
    # that don't contain the parameter, and take what's left. --no-paginate is
    # not the fix: it returns page 1 only, so the check would always fail.
    pgaudit_log=$(aws rds describe-db-parameters --db-parameter-group-name "$pg_name" \
        --region "$REGION" \
        --query "Parameters[?ParameterName=='pgaudit.log'].ParameterValue" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | head -1)
    if [ -n "$pgaudit_log" ]; then
        print_pass "pgaudit.log = ${pgaudit_log}"
    else
        print_fail "pgaudit.log is unset" \
            "Set pgaudit.log on parameter group ${pg_name} (e.g., 'all' or 'write,ddl,role') via aws rds modify-db-parameter-group."
    fi
fi
