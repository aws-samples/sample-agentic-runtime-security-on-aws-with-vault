#!/usr/bin/env bash
#===============================================================================
# sync-bedrock-kb.sh — Bedrock Knowledge Base ingestion
#
# Triggers (and waits for) a Bedrock Knowledge Base ingestion job for every
# data source. Runs AFTER Terraform deploy of the bedrock_kb_* modules.
#
# Why this is a post-deploy script (not Terraform):
#   - The AWS Terraform provider has NO ingestion-job resource — creating an
#     aws_bedrockagent_data_source does NOT embed the S3 corpus into the
#     vector index. An explicit StartIngestionJob API call is required.
#   - The workshop deploys via Terraform Stacks, which does not support
#     local-exec, so the trigger cannot live in Terraform. This mirrors the
#     seed-banking-db.sh pattern (data-plane work runs post-apply).
#
# Without this step the KB is empty and the UC1 agent's
# retrieve_from_knowledge_base tool returns zero passages.
#
# Mechanism:
#   - Discovers the KB id (terraform output kb_id, else list-knowledge-bases)
#   - For each data source: StartIngestionJob, then poll GetIngestionJob until
#     COMPLETE / FAILED
#   - Prints per-source document statistics (scanned / indexed / failed)
#
# Idempotency:
#   - Bedrock ingestion is incremental — re-running only (re)embeds new or
#     changed documents, so repeated runs are safe.
#   - If an ingestion job is already IN_PROGRESS for a data source, this script
#     attaches to and waits on that job instead of starting a duplicate.
#
# KB region: Nova 2 Multimodal Embeddings is us-east-1 only, so the KB and all
# ingestion calls target us-east-1 by default (override with --region / env).
#
# Usage:
#   ./sync-bedrock-kb.sh [--dry-run] [--region <region>] [--kb-id <id>] [--help]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Disable the common-checks EXIT-trap summary — this is an action script, not a
# pure check script (matches seed-banking-db.sh).
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

# KB region default — embedding model is us-east-1 only (see CLAUDE.md).
KB_REGION="${KB_REGION:-us-east-1}"
KB_ID="${WORKSHOP_KB_ID:-}"
DRY_RUN=false
POLL_INTERVAL=10   # seconds between GetIngestionJob polls
POLL_TIMEOUT=600   # max seconds to wait per data source

usage() {
    cat <<EOF
sync-bedrock-kb.sh — Bedrock Knowledge Base ingestion

Triggers and waits for an ingestion job per data source so the S3 corpus is
embedded into the vector index. Required before the UC1 agent can retrieve.

Usage:
  $(basename "$0") [--dry-run] [--region <region>] [--kb-id <id>] [--help]

Options:
  --dry-run        Print planned actions without starting ingestion
  --region VALUE   KB region (default: ${KB_REGION})
  --kb-id VALUE    Knowledge Base id (default: terraform output kb_id, else discovered)
  --help           Show this help message

Environment overrides:
  KB_REGION        KB region (default: us-east-1)
  WORKSHOP_KB_ID   Knowledge Base id
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --region)   KB_REGION="${2:?--region requires a value}"; shift 2 ;;
        --kb-id)    KB_ID="${2:?--kb-id requires a value}"; shift 2 ;;
        --help|-h)  usage ;;
        *)          print_fail "Unknown option: $1" "Use --help for usage."; exit 1 ;;
    esac
done

print_info "KB region: ${KB_REGION}"

#-------------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------------
command -v aws &>/dev/null || { print_fail "aws CLI required" "Install the AWS CLI v2."; exit 1; }
command -v jq  &>/dev/null || { print_fail "jq required" "Install jq."; exit 1; }
print_pass "CLI tools available"

#-------------------------------------------------------------------------------
# Resolve KB id
#-------------------------------------------------------------------------------
if [[ -z "$KB_ID" ]]; then
    KB_ID=$(terraform -chdir="${PROJECT_ROOT}/infrastructure" output -raw kb_id 2>/dev/null || echo "")
fi
if [[ -z "$KB_ID" ]]; then
    KB_ID=$(aws bedrock-agent list-knowledge-bases --region "$KB_REGION" \
        --query 'knowledgeBaseSummaries[0].knowledgeBaseId' --output text 2>/dev/null || echo "")
    [[ "$KB_ID" == "None" ]] && KB_ID=""
fi
if [[ -z "$KB_ID" ]]; then
    print_fail "Knowledge Base id not found" \
        "Pass --kb-id, set WORKSHOP_KB_ID, or run after 'terraform apply'. Check: aws bedrock-agent list-knowledge-bases --region ${KB_REGION}"
    exit 1
fi
print_pass "Knowledge Base: ${KB_ID}"

#-------------------------------------------------------------------------------
# List data sources
#-------------------------------------------------------------------------------
DS_JSON=$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" --region "$KB_REGION" \
    --query 'dataSourceSummaries[].{id:dataSourceId,name:name}' --output json 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DS_JSON" | jq 'length')
if [[ "$DS_COUNT" -eq 0 ]]; then
    print_fail "No data sources on KB ${KB_ID}" \
        "The bedrock_kb_index module should create 3 data sources. Re-run 'terraform apply'."
    exit 1
fi
print_pass "Found ${DS_COUNT} data source(s)"

if [[ "$DRY_RUN" == true ]]; then
    echo "$DS_JSON" | jq -r '.[] | "  [DRY-RUN] Would ingest data source \(.name) (\(.id))"'
    print_pass "Dry-run complete"
    exit 0
fi

#-------------------------------------------------------------------------------
# Trigger + poll ingestion per data source
#-------------------------------------------------------------------------------
poll_job() {
    # $1 = data source id, $2 = job id, $3 = data source name
    local ds_id="$1" job_id="$2" ds_name="$3" elapsed=0 status=""
    while (( elapsed < POLL_TIMEOUT )); do
        status=$(aws bedrock-agent get-ingestion-job \
            --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
            --region "$KB_REGION" --query 'ingestionJob.status' --output text 2>/dev/null || echo "UNKNOWN")
        case "$status" in
            COMPLETE) return 0 ;;
            FAILED)   return 1 ;;
            *)        sleep "$POLL_INTERVAL"; elapsed=$(( elapsed + POLL_INTERVAL )) ;;
        esac
    done
    return 2  # timeout
}

for row in $(echo "$DS_JSON" | jq -rc '.[]'); do
    ds_id=$(echo "$row" | jq -r '.id')
    ds_name=$(echo "$row" | jq -r '.name')

    # Attach to an in-progress job if one exists; otherwise start a new one.
    existing=$(aws bedrock-agent list-ingestion-jobs \
        --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" --region "$KB_REGION" \
        --query "ingestionJobSummaries[?status=='IN_PROGRESS' || status=='STARTING'].ingestionJobId | [0]" \
        --output text 2>/dev/null || echo "None")

    if [[ -n "$existing" && "$existing" != "None" ]]; then
        job_id="$existing"
        print_info "[${ds_name}] attaching to in-progress ingestion job ${job_id}"
    else
        job_id=$(aws bedrock-agent start-ingestion-job \
            --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" --region "$KB_REGION" \
            --query 'ingestionJob.ingestionJobId' --output text 2>/dev/null || echo "")
        if [[ -z "$job_id" || "$job_id" == "None" ]]; then
            print_fail "[${ds_name}] StartIngestionJob failed" \
                "Check KB role S3 + bedrock permissions. Retry: aws bedrock-agent start-ingestion-job --knowledge-base-id ${KB_ID} --data-source-id ${ds_id} --region ${KB_REGION}"
            continue
        fi
        print_info "[${ds_name}] started ingestion job ${job_id}"
    fi

    if poll_job "$ds_id" "$job_id" "$ds_name"; then
        stats=$(aws bedrock-agent get-ingestion-job \
            --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
            --region "$KB_REGION" --query 'ingestionJob.statistics' --output json 2>/dev/null || echo "{}")
        scanned=$(echo "$stats" | jq -r '.numberOfDocumentsScanned // 0')
        indexed=$(echo "$stats" | jq -r '.numberOfNewDocumentsIndexed // 0')
        modified=$(echo "$stats" | jq -r '.numberOfModifiedDocumentsIndexed // 0')
        failed=$(echo "$stats" | jq -r '.numberOfDocumentsFailed // 0')
        print_pass "[${ds_name}] ingestion COMPLETE — scanned=${scanned} indexed=${indexed} modified=${modified} failed=${failed}"
    else
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            print_fail "[${ds_name}] ingestion timed out after ${POLL_TIMEOUT}s" \
                "Check: aws bedrock-agent get-ingestion-job --knowledge-base-id ${KB_ID} --data-source-id ${ds_id} --ingestion-job-id ${job_id} --region ${KB_REGION}"
        else
            failures=$(aws bedrock-agent get-ingestion-job \
                --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" --ingestion-job-id "$job_id" \
                --region "$KB_REGION" --query 'ingestionJob.failureReasons' --output text 2>/dev/null || echo "")
            print_fail "[${ds_name}] ingestion FAILED" \
                "Reasons: ${failures}. Check KB role S3 read + KMS decrypt on the corpus bucket."
        fi
    fi
done

print_summary
exit $?
