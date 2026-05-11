#!/usr/bin/env bash
#===============================================================================
# Vault + IVIA Configuration Script
#
# Configures Vault (auth backends, secrets engines, policies, roles) and IVIA
# (OAuth clients, CIBA policy, RAR types) via local Terraform workspaces with
# kubectl port-forward. This runs AFTER the first Stacks deploy and vault-init.sh.
#
# Phases:
#   1. Gather inputs    — reads cluster/RDS/Bedrock info from AWS + kubectl
#   2. Vault config     — port-forward :8200, terraform apply vault-config/
#   3. IVIA config      — port-forward :8436, terraform apply isva-config/
#   4. Summary          — pass/fail table
#
# Prerequisites:
#   - kubectl configured for the workshop EKS cluster
#   - Vault initialized (vault-init.sh completed, ~/vault-init.json exists)
#   - IVIA pod Running in verify-access namespace
#   - AWS credentials configured (for Secrets Manager access)
#
# Usage:
#   ./vault-configure.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME   EKS cluster name (default: auto-detect from kubeconfig)
#   --region REGION        AWS region (default: auto-detect from kubeconfig)
#   --vault-token TOKEN    Vault root token (default: read from ~/vault-init.json)
#   --ivia-password PASS   IVIA admin password (default: prompt)
#   --dry-run              Show what would be done without executing
#   --skip-ivia            Skip IVIA configuration (Phase 3)
#   --help                 Show this help message
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VAULT_CONFIG_DIR="${REPO_ROOT}/infrastructure/vault-config"
ISVA_CONFIG_DIR="${REPO_ROOT}/infrastructure/isva-config"

#--- Defaults ------------------------------------------------------------------
CLUSTER_NAME=""
REGION=""
VAULT_TOKEN=""
IVIA_PASSWORD=""
DRY_RUN=false
SKIP_IVIA=false

#--- Result tracking -----------------------------------------------------------
declare -A RESULTS
PHASE_ORDER=("gather" "vault_config" "isva_config")

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --vault-token)  VAULT_TOKEN="$2"; shift 2 ;;
    --ivia-password) IVIA_PASSWORD="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --skip-ivia)    SKIP_IVIA=true; shift ;;
    --help)
      sed -n '2,/^#=====/{ /^#/s/^# \{0,1\}//p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

#--- Helpers -------------------------------------------------------------------
info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()      { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
fail()    { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }
phase()   { printf '\n\033[1;36m━━━ Phase %s: %s ━━━\033[0m\n\n' "$1" "$2"; }

record() {
  local name="$1" status="$2"
  RESULTS["$name"]="$status"
}

cleanup() {
  info "Cleaning up port-forwards..."
  [[ -n "${VAULT_PF_PID:-}" ]] && kill "$VAULT_PF_PID" 2>/dev/null || true
  [[ -n "${IVIA_PF_PID:-}" ]] && kill "$IVIA_PF_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

print_summary() {
  echo ""
  printf '\033[1;36m━━━ Summary ━━━\033[0m\n'
  echo ""
  printf '  %-20s %s\n' "Phase" "Status"
  printf '  %-20s %s\n' "-----" "------"
  for name in "${PHASE_ORDER[@]}"; do
    local status="${RESULTS[$name]:-SKIPPED}"
    local color="\033[0;33m"
    case "$status" in
      PASS) color="\033[0;32m" ;;
      FAIL) color="\033[0;31m" ;;
    esac
    printf "  %-20s ${color}%s\033[0m\n" "$name" "$status"
  done
  echo ""

  local any_fail=false
  for name in "${PHASE_ORDER[@]}"; do
    [[ "${RESULTS[$name]:-}" == "FAIL" ]] && any_fail=true
  done

  if [[ "$any_fail" == true ]]; then
    fail "One or more phases failed. Review output above."
    return 1
  else
    ok "All phases passed."
    return 0
  fi
}

#===============================================================================
# PHASE 1: Gather Inputs
#===============================================================================
phase_gather() {
  phase "1" "Gather Inputs"

  # Auto-detect region
  if [[ -z "$REGION" ]]; then
    REGION=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
      | sed -n 's/.*\.\([a-z]*-[a-z]*-[0-9]*\)\..*/\1/p' || true)
    if [[ -z "$REGION" ]]; then
      REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
    fi
  fi
  ok "Region: ${REGION}"

  # Auto-detect cluster name
  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(kubectl config current-context 2>/dev/null \
      | sed -n 's/.*:cluster\/\([^:]*\).*/\1/p' || true)
    [[ -z "$CLUSTER_NAME" ]] && CLUSTER_NAME="agentic-runtime-usw2"
  fi
  ok "Cluster: ${CLUSTER_NAME}"

  # Vault token
  if [[ -z "$VAULT_TOKEN" ]]; then
    if [[ -f "${HOME}/vault-init.json" ]]; then
      VAULT_TOKEN=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || true)
      ok "Vault token: read from ~/vault-init.json"
    fi
    if [[ -z "$VAULT_TOKEN" ]]; then
      fail "No vault token. Run vault-init.sh first or pass --vault-token."
      record "gather" "FAIL"
      return 1
    fi
  else
    ok "Vault token: provided via --vault-token"
  fi

  # EKS cluster details
  info "Reading EKS cluster details..."
  CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.endpoint' --output text --region "${REGION}" 2>/dev/null) || {
    fail "Could not describe EKS cluster '${CLUSTER_NAME}'"
    record "gather" "FAIL"
    return 1
  }
  ok "Cluster endpoint: ${CLUSTER_ENDPOINT}"

  CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.certificateAuthority.data' --output text --region "${REGION}" 2>/dev/null)
  ok "Cluster CA: (base64, ${#CLUSTER_CA} chars)"

  CLUSTER_OIDC_ISSUER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.identity.oidc.issuer' --output text --region "${REGION}" 2>/dev/null)
  ok "OIDC issuer: ${CLUSTER_OIDC_ISSUER}"

  # RDS details
  info "Reading RDS details..."
  RDS_ENDPOINT=$(aws rds describe-db-instances \
    --query 'DBInstances[0].Endpoint.[Address,Port]' --output text --region "${REGION}" 2>/dev/null \
    | awk '{printf "%s:%s", $1, $2}')
  ok "RDS endpoint: ${RDS_ENDPOINT}"

  RDS_SECRET_ARN=$(aws rds describe-db-instances \
    --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text --region "${REGION}" 2>/dev/null)
  ok "RDS secret ARN: ${RDS_SECRET_ARN}"

  # Bedrock KB role ARN
  info "Reading Bedrock KB role..."
  BEDROCK_ROLE_ARN=$(aws iam list-roles --query "Roles[?contains(RoleName, 'kb-role')].Arn | [0]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "$BEDROCK_ROLE_ARN" || "$BEDROCK_ROLE_ARN" == "None" ]]; then
    BEDROCK_ROLE_ARN=$(aws iam list-roles --query "Roles[?contains(RoleName, 'workshop-kb')].Arn | [0]" \
      --output text 2>/dev/null || echo "")
  fi
  if [[ -z "$BEDROCK_ROLE_ARN" || "$BEDROCK_ROLE_ARN" == "None" ]]; then
    warn "Could not auto-detect Bedrock KB role ARN. Set manually in tfvars."
    BEDROCK_ROLE_ARN="PLACEHOLDER"
  else
    ok "Bedrock role ARN: ${BEDROCK_ROLE_ARN}"
  fi

  # IVIA self-signed TLS cert (Vault needs it to trust OIDC discovery)
  info "Reading IVIA TLS certificate..."
  IVIA_CERT_PEM=$(kubectl get secret -n verify-access \
    $(kubectl get pods -n verify-access -l app.kubernetes.io/name=isvaop -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -z "$IVIA_CERT_PEM" ]]; then
    # Fallback: extract from the configmap config.yaml B64 cert
    IVIA_CERT_PEM=$(kubectl get configmap isvaop-cfg-data -n verify-access -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
      | sed -n 's/.*B64:\([A-Za-z0-9+/=]*\).*/\1/p' | head -1 | base64 -d 2>/dev/null || true)
  fi
  if [[ -z "$IVIA_CERT_PEM" ]]; then
    # Last fallback: openssl s_client
    IVIA_CERT_PEM=$(kubectl exec -n vault vault-0 -- sh -c \
      'echo | openssl s_client -connect isvaop.verify-access.svc.cluster.local:8436 -servername isvaop 2>/dev/null' 2>/dev/null \
      | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' || true)
  fi
  if [[ -n "$IVIA_CERT_PEM" ]]; then
    ok "IVIA TLS cert: captured ($(echo "$IVIA_CERT_PEM" | wc -l | tr -d ' ') lines)"
  else
    warn "Could not capture IVIA TLS cert — JWT auth backend may fail"
  fi

  # IVIA password
  if [[ "$SKIP_IVIA" == false && -z "$IVIA_PASSWORD" ]]; then
    read -rsp "[INPUT] IVIA admin password (or press Enter to skip IVIA): " IVIA_PASSWORD
    echo ""
    if [[ -z "$IVIA_PASSWORD" ]]; then
      SKIP_IVIA=true
      warn "No IVIA password provided — skipping IVIA configuration"
    fi
  fi

  # Check pods
  info "Checking Vault pods..."
  VAULT_READY=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server \
    --no-headers 2>/dev/null | grep -c '1/1' || true)
  if [[ "$VAULT_READY" -ge 1 ]]; then
    ok "Vault: ${VAULT_READY} pod(s) ready"
  else
    fail "No Vault pods ready. Check: kubectl get pods -n vault"
    record "gather" "FAIL"
    return 1
  fi

  if [[ "$SKIP_IVIA" == false ]]; then
    info "Checking IVIA pods..."
    IVIA_READY=$(kubectl get pods -n verify-access --no-headers 2>/dev/null | grep Running | grep -c '1/1' || true)
    if [[ "$IVIA_READY" -ge 1 ]]; then
      ok "IVIA: ${IVIA_READY} pod(s) ready"
    else
      warn "No IVIA pods ready — IVIA config may fail"
    fi
  fi

  record "gather" "PASS"
}

#===============================================================================
# PHASE 2: Vault Configuration
#===============================================================================
phase_vault_config() {
  phase "2" "Vault Configuration"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would port-forward vault:8200 and terraform apply in vault-config/"
    record "vault_config" "PASS"
    return 0
  fi

  # Write tfvars
  info "Writing terraform.tfvars..."
  cat > "${VAULT_CONFIG_DIR}/terraform.tfvars" <<TFVARS
region                             = "${REGION}"
vault_token                        = "${VAULT_TOKEN}"
cluster_endpoint                   = "${CLUSTER_ENDPOINT}"
cluster_certificate_authority_data = "${CLUSTER_CA}"
cluster_oidc_issuer                = "${CLUSTER_OIDC_ISSUER}"
rds_endpoint                       = "${RDS_ENDPOINT}"
rds_master_user_secret_arn         = "${RDS_SECRET_ARN}"
bedrock_role_arn                   = "${BEDROCK_ROLE_ARN}"
ivia_oidc_ca_pem                   = <<-CERTEOF
${IVIA_CERT_PEM}
CERTEOF
TFVARS
  chmod 600 "${VAULT_CONFIG_DIR}/terraform.tfvars"
  ok "terraform.tfvars written (mode 600)"

  # Port-forward
  info "Starting port-forward to Vault (8200)..."
  kubectl port-forward svc/vault 8200:8200 -n vault &>/dev/null &
  VAULT_PF_PID=$!
  sleep 2

  if ! kill -0 "$VAULT_PF_PID" 2>/dev/null; then
    fail "Port-forward to Vault failed to start"
    record "vault_config" "FAIL"
    return 1
  fi
  ok "Port-forward active (PID ${VAULT_PF_PID})"

  # Verify connectivity
  info "Testing Vault connectivity..."
  if curl -sf http://127.0.0.1:8200/v1/sys/health &>/dev/null; then
    ok "Vault reachable at 127.0.0.1:8200"
  else
    fail "Cannot reach Vault at 127.0.0.1:8200"
    record "vault_config" "FAIL"
    return 1
  fi

  # Terraform init + apply
  info "Running terraform init..."
  if ! terraform -chdir="${VAULT_CONFIG_DIR}" init -input=false 2>&1 | tail -3; then
    fail "terraform init failed"
    record "vault_config" "FAIL"
    return 1
  fi

  info "Running terraform apply..."
  if terraform -chdir="${VAULT_CONFIG_DIR}" apply -auto-approve -input=false 2>&1; then
    ok "Vault configuration applied successfully"
  else
    fail "terraform apply failed"
    record "vault_config" "FAIL"
    return 1
  fi

  # Verify
  info "Verifying Vault configuration..."
  local verify_pass=true

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/auth | jq -r 'keys[]' | grep -q 'kubernetes/'; then
    ok "Kubernetes auth backend: enabled"
  else
    fail "Kubernetes auth backend: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/auth | jq -r 'keys[]' | grep -q 'jwt/'; then
    ok "JWT auth backend: enabled"
  else
    fail "JWT auth backend: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts | jq -r 'keys[]' | grep -q 'database/'; then
    ok "Database secrets engine: enabled"
  else
    fail "Database secrets engine: not found"
    verify_pass=false
  fi

  if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" http://127.0.0.1:8200/v1/sys/policy | jq -r '.policies[]' | grep -q 'uc1-readonly'; then
    ok "Policy uc1-readonly: exists"
  else
    fail "Policy uc1-readonly: not found"
    verify_pass=false
  fi

  # Stop port-forward
  kill "$VAULT_PF_PID" 2>/dev/null || true
  unset VAULT_PF_PID

  if [[ "$verify_pass" == true ]]; then
    record "vault_config" "PASS"
  else
    record "vault_config" "FAIL"
  fi
}

#===============================================================================
# PHASE 3: IVIA Configuration
#===============================================================================
phase_isva_config() {
  phase "3" "IVIA Configuration"

  if [[ "$SKIP_IVIA" == true ]]; then
    info "Skipped (--skip-ivia or no password provided)"
    record "isva_config" "SKIPPED"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would port-forward isvaop:8436 and terraform apply in isva-config/"
    record "isva_config" "PASS"
    return 0
  fi

  # Write tfvars
  info "Writing terraform.tfvars..."
  cat > "${ISVA_CONFIG_DIR}/terraform.tfvars" <<TFVARS
ivia_admin_password = "${IVIA_PASSWORD}"
TFVARS
  chmod 600 "${ISVA_CONFIG_DIR}/terraform.tfvars"
  ok "terraform.tfvars written (mode 600)"

  # Port-forward
  info "Starting port-forward to IVIA (8436)..."
  kubectl port-forward svc/isvaop 8436:8436 -n verify-access &>/dev/null &
  IVIA_PF_PID=$!
  sleep 2

  if ! kill -0 "$IVIA_PF_PID" 2>/dev/null; then
    fail "Port-forward to IVIA failed to start"
    record "isva_config" "FAIL"
    return 1
  fi
  ok "Port-forward active (PID ${IVIA_PF_PID})"

  # Verify connectivity
  info "Testing IVIA connectivity..."
  if curl -skf https://127.0.0.1:8436/healthcheck/ready &>/dev/null; then
    ok "IVIA reachable at 127.0.0.1:8436"
  else
    fail "Cannot reach IVIA at 127.0.0.1:8436"
    record "isva_config" "FAIL"
    return 1
  fi

  # Terraform init + apply
  info "Running terraform init..."
  if ! terraform -chdir="${ISVA_CONFIG_DIR}" init -input=false 2>&1 | tail -3; then
    fail "terraform init failed"
    record "isva_config" "FAIL"
    return 1
  fi

  info "Running terraform apply..."
  if terraform -chdir="${ISVA_CONFIG_DIR}" apply -auto-approve -input=false 2>&1; then
    ok "IVIA configuration applied successfully"
  else
    fail "terraform apply failed"
    record "isva_config" "FAIL"
    return 1
  fi

  # Stop port-forward
  kill "$IVIA_PF_PID" 2>/dev/null || true
  unset IVIA_PF_PID

  record "isva_config" "PASS"
}

#===============================================================================
# Main
#===============================================================================
main() {
  echo ""
  printf '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  printf '\033[1;36m  Vault + IVIA Configuration\033[0m\n'
  printf '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  echo ""

  phase_gather || { print_summary; exit 1; }
  phase_vault_config || true
  phase_isva_config || true
  print_summary
}

main "$@"
