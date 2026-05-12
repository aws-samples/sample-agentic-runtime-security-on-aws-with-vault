#!/usr/bin/env bash
#===============================================================================
# seed-banking-db.sh — Banking Database Seed
#
# Seeds the RDS PostgreSQL database with the banking schema, RLS policies,
# and test data for UC2/UC3. Runs AFTER Stacks deploy of uc2_app.
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
# Usage:
#   ./seed-banking-db.sh [--dry-run] [--help] [--region <region>]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"
# shellcheck source=resolve-region.sh
source "${SCRIPT_DIR}/resolve-region.sh"

NAMESPACE="banking-app"
SEED_SQL="${PROJECT_ROOT}/applications/banking-app/db/seed.sql"
CONFIGMAP_NAME="seed-sql"
SEED_POD_NAME="db-seed-uc2"
SEED_POD_IMAGE="postgres:16-alpine"
DRY_RUN=false

usage() {
    cat <<EOF
seed-banking-db.sh — Banking Database Seed

Seeds the RDS PostgreSQL database with:
  - Banking schema (accounts + transactions tables)
  - Row-Level Security (RLS) policies for per-user data isolation
  - Test data for Oscar and Adriana

Usage:
  $(basename "$0") [--dry-run] [--region <region>] [--help]

Options:
  --dry-run       Print planned actions without executing
  --region VALUE  Override AWS region (default: auto-resolved)
  --help          Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --region)
            export WORKSHOP_REGION="${2:?--region requires a value}"
            shift 2
            ;;
        --help|-h)    usage ;;
        *)            print_fail "Unknown option: $1. Use --help."; exit 1 ;;
    esac
done

REGION="${WORKSHOP_REGION:-}"
if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region 2>/dev/null || echo "")
fi
if [[ -z "$REGION" ]]; then
    print_fail "Cannot determine AWS region. Set WORKSHOP_REGION or use --region."; exit 1
fi
print_info "Region: ${REGION}"

print_info "Preflight checks..."
command -v kubectl &>/dev/null || { print_fail "kubectl is required"; exit 1; }
command -v aws &>/dev/null || { print_fail "aws CLI is required"; exit 1; }
command -v jq &>/dev/null || { print_fail "jq is required"; exit 1; }
print_pass "CLI tools available"

kubectl get namespace "$NAMESPACE" &>/dev/null || {
    print_fail "Namespace '${NAMESPACE}' not found. Deploy uc2_app via Stacks first."; exit 1
}
print_pass "Namespace '${NAMESPACE}' exists"

[[ -f "$SEED_SQL" ]] || { print_fail "Seed SQL not found at ${SEED_SQL}"; exit 1; }
print_pass "Seed SQL found"

print_info "Discovering RDS connection info..."
RDS_INFO=$(aws rds describe-db-instances \
    --query 'DBInstances[0]' --output json --region "${REGION}" 2>/dev/null)

RDS_ADDRESS=$(echo "$RDS_INFO" | jq -r '.Endpoint.Address')
RDS_PORT=$(echo "$RDS_INFO" | jq -r '.Endpoint.Port')
RDS_DB_NAME=$(echo "$RDS_INFO" | jq -r '.DBName')
RDS_SECRET_ARN=$(echo "$RDS_INFO" | jq -r '.MasterUserSecret.SecretArn')

if [[ -z "$RDS_ADDRESS" || "$RDS_ADDRESS" == "null" ]]; then
    print_fail "Could not discover RDS endpoint. Is the RDS instance running?"; exit 1
fi
print_pass "RDS: ${RDS_ADDRESS}:${RDS_PORT} db=${RDS_DB_NAME}"

if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY-RUN] Would retrieve master credentials from Secrets Manager"
    print_info "[DRY-RUN] Would create ConfigMap '${CONFIGMAP_NAME}' in namespace '${NAMESPACE}'"
    print_info "[DRY-RUN] Would run '${SEED_POD_NAME}' pod with psql to seed database"
    print_pass "Dry-run complete"
    exit 0
fi

print_info "Retrieving master credentials..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$RDS_SECRET_ARN" \
    --query SecretString --output text --region "${REGION}" 2>/dev/null)

MASTER_USER=$(echo "$SECRET_JSON" | jq -r '.username')
MASTER_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')

if [[ -z "$MASTER_USER" || "$MASTER_USER" == "null" ]]; then
    print_fail "Could not retrieve master username from Secrets Manager"; exit 1
fi
print_pass "Master user: ${MASTER_USER}"

print_info "Creating ConfigMap from seed.sql..."
kubectl create configmap "$CONFIGMAP_NAME" \
    --namespace="$NAMESPACE" \
    --from-file="seed.sql=${SEED_SQL}" \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
print_pass "ConfigMap '${CONFIGMAP_NAME}' applied"

if kubectl get pod "$SEED_POD_NAME" -n "$NAMESPACE" &>/dev/null; then
    print_info "Cleaning up leftover seed pod..."
    kubectl delete pod "$SEED_POD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
    sleep 3
fi

print_info "Seeding database via temporary pod..."
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
      print_fail "Database seed failed. Check pod logs: kubectl logs ${SEED_POD_NAME} -n ${NAMESPACE}"
      exit 1
    }

print_pass "Database seeded successfully"
print_pass "Banking schema + RLS policies + test data for Oscar and Adriana"
