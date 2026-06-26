#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# demo-helpers.sh — the page-74 Athena helper functions, sourced OFF-CAMERA in the
# Three-Plane Audit Correlation beat's Hide block.
#
# Use Case 3 page 74 tells the attendee to define these helpers before running the
# correlation query. The on-camera commands in the beat call athena_scalar (Step 1
# — capture the most recent request_id) and athena_record (Step 2 — print the one
# stitched audit row), exactly as page 74 does. Every other beat runs the verbatim
# page command on camera with no helper indirection.
#-------------------------------------------------------------------------------

export AWS_REGION="${AWS_REGION:-us-west-2}"

#--- Athena helpers — verbatim from workshop page 74 --------------------------
# athena_run waits for the query and echoes its execution id; athena_record prints
# a single wide row vertically (field -> value). The page-74 athena_run uses a
# `for` loop; this is the same logic written `while/case` so it is robust under
# zsh as well as bash (the demo shell is zsh).
athena_run() {
  local qid state
  qid=$(aws athena start-query-execution --region us-west-2 --work-group workshop \
    --query-string "$1" --query 'QueryExecutionId' --output text) || return 1
  while true; do
    state=$(aws athena get-query-execution --region us-west-2 --query-execution-id "$qid" \
      --query 'QueryExecution.Status.State' --output text)
    case "$state" in
      SUCCEEDED)         printf '%s\n' "$qid"; return 0 ;;
      FAILED|CANCELLED)  return 1 ;;
    esac
    sleep 2
  done
}
athena_record() {
  aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
    --output json | jq -r '.ResultSet.Rows as $r | range(0; ($r[0].Data|length)) as $i
      | "\($r[0].Data[$i].VarCharValue)\t\($r[1].Data[$i].VarCharValue // "-")"' | column -t -s $'\t'
}
# Multi-row aligned table (page-74 athena_query) and first-value scalar (page-74
# athena_scalar — Step 1 captures REQUEST_ID with it).
athena_query() {
  aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
    --output json | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "-")] | @tsv' | column -t -s $'\t'
}
athena_scalar() {
  aws athena get-query-results --region us-west-2 --query-execution-id "$(athena_run "$1")" \
    --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text
}
