#!/usr/bin/env bash
#===============================================================================
# test-foundation.sh — verify the entire workshop foundation in one command
#
# Calls test-eks.sh, test-rds.sh, test-bedrock-kb.sh, then checks audit log
# groups, in-cluster OpenLDAP user registry, and the region contract. Aggregates results.
#
# Usage:
#   ./test-foundation.sh \
#       --cluster-name <name> \
#       --knowledge-base-id <kb_id> \
#       [--db-instance-id <id>] \
#       [--region <region>]
#
# Auto-derived when not provided:
#   --db-instance-id  defaults to ${cluster_name}-pg (naming convention)
#   --region          resolved from terraform.tfvars
#   KB region         parsed from kb_region in terraform.tfvars
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
Usage: $0 --cluster-name <name> --knowledge-base-id <kb> [--db-instance-id <id>] [--region <region>]

Verifies foundation: EKS, RDS, Bedrock KB, audit log groups, in-cluster OpenLDAP, region contract.

Auto-derived:
  --db-instance-id  defaults to \${cluster_name}-pg
  --region          from terraform.tfvars
  KB region         from kb_region in terraform.tfvars

Env-var fallback:
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

# Auto-derive DB instance ID from cluster name convention
if [ -z "$DB_ID" ] && [ -n "$CLUSTER_NAME" ]; then
    DB_ID="${CLUSTER_NAME}-pg"
fi

# Resolve KB region from terraform.tfvars (or .example fallback)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KB_REGION=""
for _f in "${REPO_ROOT}/infrastructure/terraform.tfvars" "${REPO_ROOT}/infrastructure/terraform.tfvars.example"; do
    if [ -f "$_f" ]; then
        KB_REGION=$(grep -E '^\s*kb_region\s*=\s*"' "$_f" 2>/dev/null \
            | head -1 \
            | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$KB_REGION" ] && break
    fi
done
if [ -z "$KB_REGION" ]; then
    KB_REGION="$REGION"
fi

missing=()
[ -z "$CLUSTER_NAME" ] && missing+=("--cluster-name / WORKSHOP_CLUSTER_NAME")
[ -z "$DB_ID" ]        && missing+=("--db-instance-id / WORKSHOP_DB_INSTANCE_ID")
[ -z "$KB_ID" ]        && missing+=("--knowledge-base-id / WORKSHOP_KB_ID")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required inputs:" >&2
    for m in "${missing[@]}"; do echo "  - $m" >&2; done
    exit 1
fi

echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  Foundation Verification${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo -e "  Cluster:     ${CLUSTER_NAME}"
echo -e "  DB instance: ${DB_ID}"
echo -e "  KB id:       ${KB_ID}"
echo -e "  Region:      ${REGION}"
echo -e "  KB region:   ${KB_REGION}"

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
    --knowledge-base-id "$KB_ID" --region "$KB_REGION" \
    || failures=$((failures + 1))

#-------------------------------------------------------------------------------
# Audit log groups — verify the 3 pre-created log groups exist with KMS
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  Audit Log Groups${NC}"
echo -e "${BLUE}===============================================================================${NC}"

EXPECTED_LOG_GROUPS=("/workshop/vault-audit" "/workshop/ivia-decision" "/workshop/agent-trace")
audit_ok=true
for lg in "${EXPECTED_LOG_GROUPS[@]}"; do
    lg_json=$(aws logs describe-log-groups --log-group-name-prefix "$lg" \
        --region "$REGION" --query "logGroups[?logGroupName=='${lg}']" \
        --output json 2>/dev/null)
    lg_count=$(echo "$lg_json" | jq 'length' 2>/dev/null)
    if [ "${lg_count:-0}" -ge 1 ]; then
        kms_key=$(echo "$lg_json" | jq -r '.[0].kmsKeyId // "none"')
        if [ "$kms_key" != "none" ]; then
            print_pass "Log group ${lg}: exists (KMS-encrypted)"
        else
            print_fail "Log group ${lg}: exists but NOT KMS-encrypted" \
                "Re-apply the audit module to attach the workshop CMK to ${lg}."
            audit_ok=false
        fi
    else
        print_fail "Log group ${lg}: NOT FOUND" \
            "Re-apply the foundation Stack — the audit component should create ${lg}."
        audit_ok=false
    fi
done
[ "$audit_ok" = false ] && failures=$((failures + 1))

#-------------------------------------------------------------------------------
# In-cluster OpenLDAP (IVIA user registry) — verify reachable + oscar exists
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  OpenLDAP (IVIA user registry)${NC}"
echo -e "${BLUE}===============================================================================${NC}"

if kubectl get deploy openldap -n verify-access &>/dev/null; then
    if kubectl wait --for=condition=Available deploy/openldap -n verify-access --timeout=60s &>/dev/null; then
        print_pass "OpenLDAP deployment Available in verify-access namespace"
    else
        print_fail "OpenLDAP deployment not Available" \
            "Run: kubectl describe deploy/openldap -n verify-access"
        failures=$((failures + 1))
    fi

    ldap_pw=$(kubectl get secret openldap-creds -n verify-access -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "${ldap_pw}" ]; then
        oscar_dn=$(kubectl exec -n verify-access deploy/openldap -- \
            ldapsearch -x -H ldapi:/// -D "cn=admin,dc=ibm,dc=com" -w "${ldap_pw}" \
            -b "dc=ibm,dc=com" "(cn=oscar)" dn 2>/dev/null | grep '^dn:' | head -1 || echo "")
        if [ -n "${oscar_dn}" ]; then
            print_pass "OpenLDAP user 'oscar' exists (${oscar_dn#dn: })"
        else
            print_fail "OpenLDAP user 'oscar' not found" \
                "Re-run IVIA autoconf job (oscar is seeded via webseal.pdadmin.users in base_layer.yaml)."
            failures=$((failures + 1))
        fi
    else
        print_warn "openldap-creds admin_password not readable — skipping user check"
    fi
else
    print_fail "OpenLDAP deployment not found in verify-access namespace" \
        "Foundation deploy must include the verify_access module."
    failures=$((failures + 1))
fi

#-------------------------------------------------------------------------------
# Region contract — no canonical region literal outside terraform.tfvars
# Excludes .terraform/ directories (vendored third-party module test files).
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  Region Contract${NC}"
echo -e "${BLUE}===============================================================================${NC}"

CANONICAL_FILE="infrastructure/terraform.tfvars"
leaks=$(grep -rn "$REGION" \
    --include='*.tf' \
    --include='*.hcl' \
    "$REPO_ROOT/infrastructure/" 2>/dev/null \
    | grep -v "terraform.tfvars" \
    | grep -v "/.terraform/" \
    | grep -v "/hcp-setup/" \
    | grep -v ':\s*#\|:\s*//' || true)

if [ -z "$leaks" ]; then
    print_pass "No region literal '${REGION}' outside ${CANONICAL_FILE}"
else
    leak_count=$(echo "$leaks" | wc -l | tr -d ' ')
    print_fail "${leak_count} region literal leak(s) found outside ${CANONICAL_FILE}" \
        "Replace hard-coded '${REGION}' with var.region in these files: $(echo "$leaks" | awk -F: '{print $1}' | sort -u | tr '\n' ' ')"
    failures=$((failures + 1))
fi

echo
echo -e "${BLUE}===============================================================================${NC}"
if [ "$failures" -eq 0 ]; then
    echo -e "${GREEN}  Foundation verification: ALL components passed${NC}"
else
    echo -e "${RED}  Foundation verification: ${failures} component(s) FAILED${NC}"
fi
echo -e "${BLUE}===============================================================================${NC}"

exit "$failures"
