#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# show-audit-correlation.sh — run the UC3 "money shot" Athena query and print
# the single correlated audit row (the documented attendee CLI command, wrapped
# so you can just execute the file and read the output).
#
# Usage:
#   ./show-audit-correlation.sh [REQUEST_ID]
#
# Defaults (override via env or arg):
#   REQUEST_ID  arg $1, else $UC3_REQUEST_ID, else the reference refund.
#   AWS_REGION  env, else us-west-2.
#   LOG_BUCKET  env, else auto-resolved (workshop-logs), else agenticlife-workshop-logs.
#
# Examples:
#   ./show-audit-correlation.sh
#   ./show-audit-correlation.sh 1234abcd-....-....
#   AWS_REGION=us-west-2 LOG_BUCKET=my-bucket ./show-audit-correlation.sh
#-------------------------------------------------------------------------------
set -euo pipefail

REQUEST_ID="${1:-${UC3_REQUEST_ID:-dc79a13e-4175-49a6-acb8-26f20b2020c7}}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DATABASE="${GLUE_DATABASE:-workshop_logs}"

# Resolve an S3 results bucket if not provided.
if [ -z "${LOG_BUCKET:-}" ]; then
  LOG_BUCKET=$(aws s3api list-buckets \
    --query "Buckets[?contains(Name,'workshop-logs')].Name | [0]" \
    --output text 2>/dev/null || echo "")
  if [ -z "${LOG_BUCKET}" ] || [ "${LOG_BUCKET}" = "None" ]; then
    LOG_BUCKET="agenticlife-workshop-logs"
  fi
fi

echo "Region:     ${AWS_REGION}"
echo "Database:   ${DATABASE}"
echo "Results:    s3://${LOG_BUCKET}/athena-results/"
echo "request_id: ${REQUEST_ID}"
echo

# 1) Start the query.
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT * FROM audit_correlation WHERE request_id = '${REQUEST_ID}' LIMIT 1" \
  --query-execution-context "Database=${DATABASE}" \
  --result-configuration "OutputLocation=s3://${LOG_BUCKET}/athena-results/" \
  --region "${AWS_REGION}" \
  --query 'QueryExecutionId' --output text)
echo "QueryExecutionId: ${QUERY_ID}"

# 2) Poll to a terminal state.
STATE="RUNNING"
for _ in $(seq 1 30); do
  STATE=$(aws athena get-query-execution \
    --query-execution-id "${QUERY_ID}" \
    --region "${AWS_REGION}" \
    --query 'QueryExecution.Status.State' --output text)
  case "${STATE}" in SUCCEEDED | FAILED | CANCELLED) break ;; esac
  sleep 2
done
echo "State: ${STATE}"
echo

if [ "${STATE}" != "SUCCEEDED" ]; then
  REASON=$(aws athena get-query-execution \
    --query-execution-id "${QUERY_ID}" \
    --region "${AWS_REGION}" \
    --query 'QueryExecution.Status.StateChangeReason' --output text 2>/dev/null || echo "")
  echo "Query did not succeed: ${REASON}"
  exit 1
fi

# 3) Print the row as column = value pairs (header row + one data row).
RESULTS_FILE=$(mktemp)
trap 'rm -f "${RESULTS_FILE}"' EXIT
aws athena get-query-results \
  --query-execution-id "${QUERY_ID}" \
  --region "${AWS_REGION}" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output json >"${RESULTS_FILE}"

python3 - "${RESULTS_FILE}" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
if len(rows) < 2:
    print("No data row — the refund may not have propagated yet, or the request_id is wrong.")
    sys.exit(1)
hdr, val = rows[0], rows[1]
print("=== audit_correlation (money shot) ===")
for h, v in zip(hdr, val):
    print("  {:28s} = {}".format(h, v if v not in (None, "") else "(null)"))
blanks = sum(1 for v in val if v in (None, ""))
print("\n  columns: {}   blanks: {}".format(len(hdr), blanks))
PY
