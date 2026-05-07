#!/usr/bin/env bash
#===============================================================================
# test-bedrock-kb.sh — verify the workshop Bedrock Knowledge Base + AOSS
#
# Checks:
#   - aws bedrock-agent get-knowledge-base status == ACTIVE
#   - aws bedrock-agent list-data-sources returns 3 (hr, customers, finance)
#     all in AVAILABLE status
#   - aws bedrock-agent-runtime retrieve smoke query against each data source
#     returns >=1 result OR a clean noResults response (any non-error response
#     proves the retrieval path is wired up)
#   - AOSS collection (linked to the KB) status == ACTIVE
#
# Usage:
#   ./test-bedrock-kb.sh --knowledge-base-id <kb_id> [--region <region>]
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AWS_PAGER=""

KB_ID=""
CLI_REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --knowledge-base-id) KB_ID="$2"; shift ;;
        --region)            CLI_REGION="$2"; shift ;;
        --help|-h)
            cat <<USAGE
Usage: $0 --knowledge-base-id <kb_id> [--region <region>]

Verifies KB status, 3 data sources (hr/customers/finance), retrieval smoke
queries, and the linked AOSS collection.
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

if [ -z "$KB_ID" ]; then
    echo "ERROR: --knowledge-base-id is required" >&2
    exit 1
fi

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"
# shellcheck source=resolve-region.sh
source "$SCRIPT_DIR/resolve-region.sh"
resolve_region "$CLI_REGION" || exit 1
REGION="$RESOLVED_REGION"

echo
echo -e "${BLUE}=== test-bedrock-kb.sh ===${NC}"
echo -e "  KB id:  ${KB_ID}"
echo -e "  Region: ${REGION}"
echo

# 1. Knowledge base status
kb_json=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" \
    --region "$REGION" --output json 2>&1)
if echo "$kb_json" | grep -q "ResourceNotFoundException"; then
    print_fail "Knowledge base ${KB_ID} not found in ${REGION}" \
        "Run: aws bedrock-agent get-knowledge-base --knowledge-base-id ${KB_ID} --region ${REGION}. Verify the foundation Stack created the KB (knowledge-base module)."
    exit 1
fi

kb_status=$(echo "$kb_json" | jq -r '.knowledgeBase.status // "unknown"')
if [ "$kb_status" = "ACTIVE" ]; then
    print_pass "KB status: ACTIVE"
else
    print_fail "KB status: ${kb_status}" \
        "Inspect Bedrock Agent console → Knowledge bases → ${KB_ID}. If 'FAILED', check the failureReasons field and re-create."
fi

# AOSS collection ARN from KB storageConfiguration
aoss_arn=$(echo "$kb_json" | jq -r '.knowledgeBase.storageConfiguration.opensearchServerlessConfiguration.collectionArn // empty')
if [ -n "$aoss_arn" ]; then
    coll_id="${aoss_arn##*/}"
    coll_status=$(aws opensearchserverless batch-get-collection --ids "$coll_id" \
        --region "$REGION" \
        --query 'collectionDetails[0].status' --output text 2>/dev/null)
    if [ "$coll_status" = "ACTIVE" ]; then
        print_pass "AOSS collection ACTIVE (id=${coll_id})"
    else
        print_fail "AOSS collection status: ${coll_status} (id=${coll_id})" \
            "Run: aws opensearchserverless batch-get-collection --ids ${coll_id} --region ${REGION}. If 'FAILED', re-apply the AOSS module."
    fi
else
    print_fail "KB has no AOSS collectionArn in storageConfiguration" \
        "The KB must use opensearchServerlessConfiguration. Re-apply the knowledge-base module."
fi

# 2. Data sources — expect 3 (hr, customers, finance)
ds_json=$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" \
    --region "$REGION" --output json 2>/dev/null)
ds_count=$(echo "$ds_json" | jq '.dataSourceSummaries | length' 2>/dev/null)

if [ "${ds_count:-0}" -ge 3 ]; then
    print_pass "Data source count: ${ds_count} (>= 3)"
else
    print_fail "Data source count: ${ds_count:-0} (require 3 — hr, customers, finance)" \
        "Run: aws bedrock-agent list-data-sources --knowledge-base-id ${KB_ID} --region ${REGION}. Re-apply the foundation Stack so the KB has all 3 S3 data sources attached."
fi

EXPECTED_DS=(hr customers finance)
for expected in "${EXPECTED_DS[@]}"; do
    # Match data source whose name CONTAINS the expected token (case-insensitive)
    ds_id=$(echo "$ds_json" | jq -r --arg e "$expected" \
        '.dataSourceSummaries[]
         | select((.name // "") | ascii_downcase | contains($e))
         | .dataSourceId' 2>/dev/null | head -1)

    if [ -z "$ds_id" ]; then
        print_fail "Data source for '${expected}' not found" \
            "Re-apply the foundation Stack with all 3 data sources (hr, customers, finance) configured in the knowledge-base module."
        continue
    fi

    ds_status=$(aws bedrock-agent get-data-source --knowledge-base-id "$KB_ID" \
        --data-source-id "$ds_id" --region "$REGION" \
        --query 'dataSource.status' --output text 2>/dev/null)
    if [ "$ds_status" = "AVAILABLE" ]; then
        print_pass "Data source ${expected} (id=${ds_id}): AVAILABLE"
    else
        print_fail "Data source ${expected} (id=${ds_id}): ${ds_status}" \
            "Inspect Bedrock console → Knowledge base ${KB_ID} → data source ${ds_id}. Trigger a sync if needed: aws bedrock-agent start-ingestion-job --knowledge-base-id ${KB_ID} --data-source-id ${ds_id} --region ${REGION}."
    fi

    # Smoke retrieval — any non-error response is success
    retrieve_err=$(mktemp)
    if aws bedrock-agent-runtime retrieve \
            --knowledge-base-id "$KB_ID" \
            --region "$REGION" \
            --retrieval-query "{\"text\":\"${expected}\"}" \
            --retrieval-configuration "{\"vectorSearchConfiguration\":{\"numberOfResults\":1}}" \
            --output json >/dev/null 2>"$retrieve_err"; then
        print_pass "Retrieve smoke query for '${expected}' succeeded"
    else
        err=$(cat "$retrieve_err" 2>/dev/null)
        print_fail "Retrieve smoke query for '${expected}' failed: ${err}" \
            "Run: aws bedrock-agent-runtime retrieve --knowledge-base-id ${KB_ID} --region ${REGION} --retrieval-query '{\"text\":\"${expected}\"}'. If 'AccessDeniedException', verify IAM. If 'ValidationException', check that the data source has been ingested at least once."
    fi
    rm -f "$retrieve_err"
done
