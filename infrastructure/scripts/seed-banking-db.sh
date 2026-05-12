#!/usr/bin/env bash
#===============================================================================
# seed-banking-db.sh — Banking Database Seed
#
# Seeds the RDS PostgreSQL database with the banking schema, RLS policies,
# and test data for UC2/UC3. Runs AFTER Stacks deploy of uc2_app — the
# banking-app namespace and pods must exist.
#
# Mechanism:
#   - Retrieves RDS master credentials from Secrets Manager
#   - Creates a ConfigMap from seed.sql in the banking-app namespace
#   - Runs a disposable postgres:16-alpine pod (--rm) that mounts the
#     ConfigMap and executes psql against the RDS endpoint
#
# Idempotency:
#   - seed.sql uses IF NOT EXISTS + ON CONFLICT DO NOTHING
#   - ConfigMap is replaced on every run (kubectl apply)
#   - Temp pod auto-deletes (--rm + restartPolicy: Never)
#
# Prerequisites:
#   - kubectl configured and pointing to the workshop EKS cluster
#   - banking-app namespace exists (created by uc2_app Stacks component)
#   - AWS credentials with secretsmanager:GetSecretValue permission
#
# Usage:
#   ./seed-banking-db.sh [--dry-run] [--help] [--region <region>]
#
# Options:
#   --dry-run   Print planned actions without executing
#   --region    Override AWS region (default: auto-resolved)
#   --help      Show this help message and exit
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"
# shellcheck source=resolve-region.sh
source "${SCRIPT_DIR}/resolve-region.sh"

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
NAMESPACE="banking-app"
SEED_SQL="${PROJECT_ROOT}/applications/banking-app/db/seed.sql"
CONFIGMAP_NAME="seed-sql"
SEED_POD_NAME="db-seed-uc2"
SEED_POD_IMAGE="postgres:16-alpine"

DRY_RUN=false

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Banking Database Seed Script for the Agentic Runtime Security Workshop.

Seeds the RDS PostgreSQL database with:
  - Banking schema (accounts + transactions tables)
  - Row-Level Security (RLS) policies for per-user data isolation
  - Test data for Oscar and Adriana

Options:
  --dry-run       Print planned actions without executing
  --region VALUE  Override AWS region (default: auto-resolved)
  --help          Show this help message and exit

Environment:
  WORKSHOP_REGION  AWS region override

Examples:
  $(basename "$0")
  $(basename "$0") --dry-run
  $(basename "$0") --region us-west-2
EOF
  exit 0
}

#-------------------------------------------------------------------------------
# Parse arguments
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --region)
      CLI_REGION="${2:?--region requires a value}"
      export WORKSHOP_REGION="$CLI_REGION"
      shift 2
      ;;
    --help|-h)    usage ;;
    *)            fail "Unknown option: $1. Use --help for usage." ;;
  esac
done

#-------------------------------------------------------------------------------
# Resolve region
#-------------------------------------------------------------------------------
REGION="${WORKSHOP_REGION:-}"
if [[ -z "$REGION" ]]; then
  REGION=$(aws configure get region 2>/dev/null || echo "")
fi
if [[ -z "$REGION" ]]; then
  fail "Cannot determine AWS region. Set WORKSHOP_REGION or use --region."
fi
ok "Region: ${REGION}"

#-------------------------------------------------------------------------------
# Preflight checks
#-------------------------------------------------------------------------------
section "Preflight"

check_command kubectl "kubectl is required"
check_command aws "AWS CLI is required"
check_command jq "jq is required"

# Verify namespace exists
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  fail "Namespace '${NAMESPACE}' not found. Deploy uc2_app via Stacks first."
fi
ok "Namespace '${NAMESPACE}' exists"

# Verify seed.sql exists
if [[ ! -f "$SEED_SQL" ]]; then
  fail "Seed SQL not found at ${SEED_SQL}"
fi
ok "Seed SQL found: ${SEED_SQL}"

#-------------------------------------------------------------------------------
# Discover RDS connection info
#-------------------------------------------------------------------------------
section "Discovering RDS connection info"

RDS_INFO=$(aws rds describe-db-instances \
  --query 'DBInstances[0]' --output json --region "${REGION}" 2>/dev/null)

RDS_ADDRESS=$(echo "$RDS_INFO" | jq -r '.Endpoint.Address')
RDS_PORT=$(echo "$RDS_INFO" | jq -r '.Endpoint.Port')
RDS_DB_NAME=$(echo "$RDS_INFO" | jq -r '.DBName')
RDS_SECRET_ARN=$(echo "$RDS_INFO" | jq -r '.MasterUserSecret.SecretArn')

if [[ -z "$RDS_ADDRESS" || "$RDS_ADDRESS" == "null" ]]; then
  fail "Could not discover RDS endpoint. Is the RDS instance running?"
fi
ok "RDS address: ${RDS_ADDRESS}:${RDS_PORT}"
ok "RDS database: ${RDS_DB_NAME}"
ok "RDS secret ARN: ${RDS_SECRET_ARN}"

#-------------------------------------------------------------------------------
# Retrieve master credentials
#-------------------------------------------------------------------------------
section "Retrieving master credentials"

if [[ "$DRY_RUN" == true ]]; then
  info "[DRY-RUN] Would retrieve master credentials from Secrets Manager"
  info "[DRY-RUN] Would create ConfigMap '${CONFIGMAP_NAME}' in namespace '${NAMESPACE}'"
  info "[DRY-RUN] Would run '${SEED_POD_NAME}' pod with psql to seed database"
  info "[DRY-RUN] Done."
  exit 0
fi

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$RDS_SECRET_ARN" \
  --query SecretString --output text --region "${REGION}" 2>/dev/null)

MASTER_USER=$(echo "$SECRET_JSON" | jq -r '.username')
MASTER_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')

if [[ -z "$MASTER_USER" || "$MASTER_USER" == "null" ]]; then
  fail "Could not retrieve master username from Secrets Manager"
fi
ok "Master user: ${MASTER_USER}"

#-------------------------------------------------------------------------------
# Create/update ConfigMap from seed.sql
#-------------------------------------------------------------------------------
section "Creating ConfigMap"

kubectl create configmap "$CONFIGMAP_NAME" \
  --namespace="$NAMESPACE" \
  --from-file="seed.sql=${SEED_SQL}" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
ok "ConfigMap '${CONFIGMAP_NAME}' applied in namespace '${NAMESPACE}'"

#-------------------------------------------------------------------------------
# Clean up any leftover seed pod
#-------------------------------------------------------------------------------
if kubectl get pod "$SEED_POD_NAME" -n "$NAMESPACE" &>/dev/null; then
  info "Cleaning up leftover seed pod..."
  kubectl delete pod "$SEED_POD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
  sleep 3
fi

#-------------------------------------------------------------------------------
# Run seed pod
#-------------------------------------------------------------------------------
section "Seeding database"

info "Running psql seed via temporary pod..."
kubectl run "$SEED_POD_NAME" \
  --namespace="$NAMESPACE" \
  --image="$SEED_POD_IMAGE" \
  --restart=Never \
  --rm \
  -i \
  --timeout=120s \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"${SEED_POD_NAME}\",
        \"image\": \"${SEED_POD_IMAGE}\",
        \"command\": [
          \"psql\",
          \"-h\", \"${RDS_ADDRESS}\",
          \"-p\", \"${RDS_PORT}\",
          \"-U\", \"${MASTER_USER}\",
          \"-d\", \"${RDS_DB_NAME}\",
          \"-f\", \"/seed/seed.sql\"
        ],
        \"volumeMounts\": [{\"name\": \"seed\", \"mountPath\": \"/seed\"}],
        \"env\": [{\"name\": \"PGPASSWORD\", \"value\": \"${MASTER_PASSWORD}\"}]
      }],
      \"volumes\": [{\"name\": \"seed\", \"configMap\": {\"name\": \"${CONFIGMAP_NAME}\"}}],
      \"restartPolicy\": \"Never\"
    }
  }" 2>&1 || {
    fail "Database seed failed. Check pod logs: kubectl logs ${SEED_POD_NAME} -n ${NAMESPACE}"
  }

ok "Database seeded successfully"

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
section "Summary"
ok "Banking schema created (IF NOT EXISTS)"
ok "RLS policies applied for per-user isolation"
ok "Test data seeded for Oscar and Adriana (ON CONFLICT DO NOTHING)"
info "Verify: kubectl run psql-check --rm -i --namespace=${NAMESPACE} --image=${SEED_POD_IMAGE} -- psql -h ${RDS_ADDRESS} -U ${MASTER_USER} -d ${RDS_DB_NAME} -c 'SELECT count(*) FROM banking.accounts;'"
