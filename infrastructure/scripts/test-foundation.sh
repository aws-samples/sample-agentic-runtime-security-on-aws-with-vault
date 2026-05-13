#!/usr/bin/env bash
#===============================================================================
# test-foundation.sh — verify the entire workshop foundation in one command
#
# Calls test-eks.sh, test-rds.sh, test-bedrock-kb.sh, then checks audit log
# groups, Simple AD directory, and the region contract. Aggregates results.
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

Verifies foundation: EKS, RDS, Bedrock KB, audit log groups, Simple AD, region contract.

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
# Simple AD — verify workshop.internal directory is Active
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}  Simple AD${NC}"
echo -e "${BLUE}===============================================================================${NC}"

ad_stage=$(aws ds describe-directories \
    --query 'DirectoryDescriptions[?Name==`workshop.internal`].Stage | [0]' \
    --output text --region "${REGION}" 2>/dev/null || echo "NONE")

if [ "${ad_stage}" = "Active" ]; then
    ad_id=$(aws ds describe-directories \
        --query 'DirectoryDescriptions[?Name==`workshop.internal`].DirectoryId | [0]' \
        --output text --region "${REGION}" 2>/dev/null || echo "")
    print_pass "Simple AD directory workshop.internal: Active (${ad_id})"

    ad_dns_ip=$(aws ds describe-directories \
        --query 'DirectoryDescriptions[?Name==`workshop.internal`].DnsIpAddrs[0] | [0]' \
        --output text --region "${REGION}" 2>/dev/null || echo "")

    if [ -n "${ad_dns_ip}" ] && [ "${ad_dns_ip}" != "None" ]; then
        kubectl delete pod verify-ad-ldap --ignore-not-found --wait=false &>/dev/null
        ldap_result=$(kubectl run verify-ad-ldap -n verify-access --rm -i --restart=Never \
            --image=python:3.12-slim -- \
            bash -c "apt-get update -qq && apt-get install -y -qq ldap-utils >/dev/null 2>&1 && \
                echo 'LDAP_CONNECT:OK' && \
                for user in oscar adriana; do \
                    if ldapsearch -x -H ldap://${ad_dns_ip} -b 'CN=Users,DC=workshop,DC=internal' \
                        \"(sAMAccountName=\${user})\" dn 2>/dev/null | grep -q '^dn:'; then \
                        echo \"USER_FOUND:\${user}\"; \
                    else \
                        echo \"USER_MISSING:\${user}\"; \
                    fi; \
                done" \
            2>/dev/null | grep -v 'pod.*deleted' || echo "LDAP_CONNECT:FAIL")

        if echo "${ldap_result}" | grep -q 'LDAP_CONNECT:OK'; then
            print_pass "LDAP connectivity from cluster to Simple AD (${ad_dns_ip}:389)"
        else
            print_fail "LDAP connectivity to Simple AD" \
                "Cannot reach ${ad_dns_ip}:389 from cluster. Check security group rule eks_to_simple_ad_ldap."
            failures=$((failures + 1))
        fi

        for ad_user in oscar adriana; do
            if echo "${ldap_result}" | grep -q "USER_FOUND:${ad_user}"; then
                print_pass "Simple AD user '${ad_user}' exists"
            else
                print_fail "Simple AD user '${ad_user}' not found" \
                    "Run create-simple-ad-users.sh --ldap-host ${ad_dns_ip} --admin-password <password>"
                failures=$((failures + 1))
            fi
        done
    else
        print_warn "Simple AD DNS IP not found — skipping LDAP and user checks"
    fi
else
    print_fail "Simple AD directory workshop.internal" \
        "Expected Active, got '${ad_stage}'. Check: aws ds describe-directories --region ${REGION}"
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
