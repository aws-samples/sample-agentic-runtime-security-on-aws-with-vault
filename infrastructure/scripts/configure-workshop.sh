#!/usr/bin/env bash
#===============================================================================
# configure-workshop.sh — Post-Deploy Workshop Configuration
#
# Run after `terraform apply` converges. Configures the full workshop
# environment in sequence:
#   Step 1: Configure kubectl (aws eks update-kubeconfig)
#   Step 2: Build & push application images (build-images.sh) + roll Deployments
#   Step 3: Initialize Vault (vault-init.sh)
#   Step 4: ACME cert issuance + ACM bootstrap sync (nip.io + Let's Encrypt)
#   Step 5: Configure Vault (vault-configure.sh)
#   Step 6: Configure IVIA (ivia-configure.sh)
#   Step 7: Verify OpenLDAP user 'oscar' seeded by IVIA autoconf
#   Step 8: Seed banking DB (seed-banking-db.sh)
#
# Idempotent — safe to re-run. Each step self-verifies its result.
# Missing sub-scripts are skipped with a warning (not a fatal error).
#
# Usage: ./configure-workshop.sh [OPTIONS]
#
# Options:
#   --region REGION          AWS region (default: parsed from terraform.tfvars)
#   --cluster-name NAME      EKS cluster name (default: parsed from terraform.tfvars)
#   --skip-vault-init        Skip Vault initialization (Vault already initialized)
#   --skip-build             Skip image build+push (images already in ECR)
#   --skip-acme              Skip ACME cert issuance + ACM first-sync (cert already valid)
#   --dry-run                Print planned actions without executing
#   --help                   Show this help message
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - kubectl installed
#   - Vault CLI installed
#   - Docker running (Step 2 builds the application images)
#   - terraform apply complete (EKS cluster + Vault pods running, ECR repos created)
#
# Examples:
#   # Full post-deploy configuration
#   ./configure-workshop.sh
#
#   # Specify region and cluster name explicitly
#   ./configure-workshop.sh --region us-west-2 --cluster-name agentic-runtime-security
#
#   # Skip vault-init if Vault is already initialized
#   ./configure-workshop.sh --skip-vault-init
#
#   # Skip image builds on a re-run when images are already pushed
#   ./configure-workshop.sh --skip-build
#
#   # Preview what would be done
#   ./configure-workshop.sh --dry-run
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Suppress the common-checks EXIT trap — we emit our own summary at end.
# (Phase 07.8 Plan 01 Task 2 incidental fix: this variable IS consumed by
# common-checks.sh which is sourced below, but shellcheck cannot follow the
# sourced file with SC1091 disabled; the directive documents the design.)
# shellcheck disable=SC2034
COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "${SCRIPT_DIR}/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
REGION=""
CLUSTER_NAME=""
SKIP_VAULT_INIT=false
SKIP_BUILD=false
# Phase 07.8 Plan 01 Task 2: --skip-acme flag plumbing. Variable is consumed
# by Plan 04 ACME step body (sentinel block: if [[ "$SKIP_ACME" = true ]] ...).
# shellcheck disable=SC2034
SKIP_ACME=false
DRY_RUN=false

# Vault port-forward PID (cleaned up on exit)
VAULT_PF_PID=""

# Application Deployments rolled after images are pushed (Step 2). Format:
# "<namespace>:<deployment>". These are created by `terraform apply` and sit in
# ImagePullBackOff until their images exist in ECR.
APP_DEPLOYMENTS=(
    "uc1:uc1-agent"
    "banking-app:banking-ui"
    "banking-app:banking-agent"
    "banking-app:banking-mcp-server"
    "banking-app:uc3-agent"
)

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    sed -n '2,51p' "$0"
    exit 0
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    # shellcheck disable=SC2034  # SKIP_ACME assignment is intentional — consumed by Plan 04 ACME step body
    case "$1" in
        --help|-h)          usage ;;
        --region)           REGION="$2"; shift ;;
        --cluster-name)     CLUSTER_NAME="$2"; shift ;;
        --skip-vault-init)  SKIP_VAULT_INIT=true ;;
        --skip-build)       SKIP_BUILD=true ;;
        --skip-acme)        SKIP_ACME=true ;;
        --dry-run)          DRY_RUN=true ;;
        -*) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

#-------------------------------------------------------------------------------
# Resolve REGION and CLUSTER_NAME from terraform.tfvars if not supplied
#-------------------------------------------------------------------------------
TFVARS="${PROJECT_ROOT}/infrastructure/terraform.tfvars"
TFVARS_EXAMPLE="${PROJECT_ROOT}/infrastructure/terraform.tfvars.example"

_resolve_tfvar() {
    local key="$1"
    local file=""
    if [[ -f "$TFVARS" ]]; then
        file="$TFVARS"
    elif [[ -f "$TFVARS_EXAMPLE" ]]; then
        file="$TFVARS_EXAMPLE"
    fi
    if [[ -n "$file" ]]; then
        grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
            | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
    fi
}

if [[ -z "$REGION" ]]; then
    REGION=$(_resolve_tfvar "region")
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(_resolve_tfvar "cluster_name")
fi

if [[ -z "$REGION" ]]; then
    print_fail "REGION" "Pass --region <region> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi
if [[ -z "$CLUSTER_NAME" ]]; then
    print_fail "CLUSTER_NAME" "Pass --cluster-name <name> or ensure infrastructure/terraform.tfvars exists"
    print_summary
    exit 1
fi

#-------------------------------------------------------------------------------
# EXIT cleanup — kill port-forward on any exit
#-------------------------------------------------------------------------------
_cleanup() {
    if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
        kill "$VAULT_PF_PID" 2>/dev/null || true
    fi
    print_summary
}
trap '_cleanup' EXIT

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
_run_subscript() {
    local label="$1"
    local script_path="$2"
    shift 2
    local args=("$@")

    if [[ ! -f "$script_path" ]]; then
        print_warn "${label}: ${script_path} not found — skipping"
        return 0
    fi

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would run: ${script_path} ${args[*]}"
        return 0
    fi

    "${script_path}" "${args[@]}"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        print_fail "${label}" "Re-run: ${script_path} ${args[*]}"
        return 1
    fi
    return 0
}

_wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf "http://localhost:${port}/v1/sys/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

#-------------------------------------------------------------------------------
# Header
#-------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Workshop Post-Deploy Configuration${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""
print_info "Region:       ${REGION}"
print_info "Cluster:      ${CLUSTER_NAME}"
print_info "Skip Vault init: ${SKIP_VAULT_INIT}"
print_info "Skip image build: ${SKIP_BUILD}"
if [[ "$DRY_RUN" = true ]]; then
    print_warn "DRY-RUN mode — no changes will be made"
fi
echo ""

#===============================================================================
# STEP 1: Configure kubectl
#===============================================================================
echo -e "${YELLOW}> Step 1: Configure kubectl${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} --alias workshop"
    print_pass "Step 1: Configure kubectl (dry-run)"
else
    if aws eks update-kubeconfig \
            --region "${REGION}" \
            --name "${CLUSTER_NAME}" \
            --alias workshop \
            >/dev/null 2>&1; then
        # Verify connectivity
        if kubectl --context workshop get nodes --no-headers >/dev/null 2>&1; then
            local_node_count=$(kubectl --context workshop get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
            print_pass "Step 1: Configure kubectl (${local_node_count} node(s) reachable)"
        else
            print_fail "Step 1: Configure kubectl — nodes not reachable" \
                "Check EKS cluster status: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
        fi
    else
        print_fail "Step 1: Configure kubectl — update-kubeconfig failed" \
            "Ensure EKS cluster is Active: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
    fi
fi

#===============================================================================
# STEP 2: Build & push application images, then roll the Deployments
#
# `terraform apply` creates the ECR repositories and the application
# Deployments, but does NOT build the container images — so the pods come up
# in ImagePullBackOff. This step builds+pushes every image (build-images.sh)
# and then rolls each Deployment so kubelet pulls the freshly pushed image
# immediately instead of waiting out its CrashLoop/ImagePull backoff.
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 2: Build & push application images${NC}"

if [[ "$SKIP_BUILD" = true ]]; then
    print_info "Step 2: Image build skipped (--skip-build)"
    PASSES+=("Step 2: Build & push application images (skipped)")
elif [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: build-images.sh --region ${REGION}"
    print_info "[DRY-RUN] Would roll Deployments: ${APP_DEPLOYMENTS[*]}"
    print_pass "Step 2: Build & push application images (dry-run)"
else
    if _run_subscript "Step 2: build-images" \
            "${SCRIPT_DIR}/build-images.sh" \
            --region "${REGION}"; then
        # Roll each app Deployment so it pulls the just-pushed image now.
        rolled=0
        for entry in "${APP_DEPLOYMENTS[@]}"; do
            ns="${entry%%:*}"
            dep="${entry#*:}"
            if kubectl --context workshop get deploy "$dep" -n "$ns" >/dev/null 2>&1; then
                kubectl --context workshop rollout restart "deploy/${dep}" -n "$ns" >/dev/null 2>&1 \
                    && rolled=$((rolled + 1))
            fi
        done
        print_pass "Step 2: Build & push application images (${rolled} Deployment(s) rolled)"
    fi
fi

#===============================================================================
# STEP 3: Initialize Vault (skip if --skip-vault-init)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 3: Initialize Vault${NC}"

if [[ "$SKIP_VAULT_INIT" = true ]]; then
    print_info "Step 3: Vault init skipped (--skip-vault-init)"
    PASSES+=("Step 3: Initialize Vault (skipped)")
elif [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: vault-init.sh"
    print_pass "Step 3: Initialize Vault (dry-run)"
else
    if _run_subscript "Step 3: vault-init" "${SCRIPT_DIR}/vault-init.sh"; then
        # vault-init.sh verifies status internally and exits 0 on success
        # Verify via kubectl exec (no port-forward needed)
        vault_sealed=$(kubectl --context workshop exec -n vault vault-0 -- \
            vault status -format=json 2>/dev/null \
            | jq -r '.sealed' 2>/dev/null || echo "true")
        if [[ "$vault_sealed" = "false" ]]; then
            print_pass "Step 3: Initialize Vault (initialized, unsealed)"
        else
            print_fail "Step 3: Initialize Vault" \
                "Vault sealed or unreachable. Check: kubectl exec -n vault vault-0 -- vault status"
        fi
    fi
fi

#===============================================================================
# STEP 4: ACME cert issuance + ACM bootstrap sync (nip.io + Let's Encrypt)
#
# Phase 07.8 Plan 04 (D-03, D-07, D-10, D-11, D-12).
#
# Resolves the shared workshop-acme ALB hostname (Plan 02 IngressGroup), computes
# nip.io FQDNs `wrp.<deploy_id>.<alb_ip_dashed>.nip.io` and `banking.<deploy_id>.<alb_ip_dashed>.nip.io`,
# applies a cert-manager Certificate CR with those SANs against the Plan 03
# ClusterIssuer `letsencrypt-prod`, waits for `Certificate Ready=true`, and runs
# a one-shot bootstrap `aws acm import-certificate --certificate-arn $STABLE_ACM_ARN`
# so attendees don't wait 6h for the first ACM-sync CronJob cycle.
#
# Idempotency floor (D-12): a second run detects the existing Let's Encrypt-issued
# ACM cert via `aws acm describe-certificate --query 'Certificate.Issuer'` and exits
# early — no LE re-issuance, no new ACM import.
#
# D-10 (no cross-deploy cache): `.acme-state` is local-only + gitignored (Plan 01
# wired the gitignore). Fresh cluster destroy → re-deploy regenerates DEPLOY_ID.
#
# D-07 sequencing: AFTER `.acme-state` is written, the step runs `terraform
# -chdir=infrastructure apply -auto-approve -target=module.ivia` so the new
# NIP_FQDN_WRP flips `local.wrp_effective_host` → re-hashes `base_layer_hash` →
# triggers ConfigMap recreation + autoconf Job re-run → flips IVIA AAC DB MMFA
# endpoint URLs to nip.io. Per project rule `feedback_changes_through_existing_scripts.md`.
#===============================================================================
ACME_STATE_FILE="${PROJECT_ROOT}/infrastructure/.acme-state"

# Function wrapper allows `return 0/1` for the idempotency early-exit and the
# shared-ALB equality / ALB-IP failure cases without aborting the whole script.
_run_acme_step() {
    # Source existing .acme-state if present (Plan 01 wired the gitignore;
    # contains DEPLOY_ID, ALB_IP, ALB_IP_DASHED, NIP_FQDN_WRP, NIP_FQDN_BANKING,
    # STABLE_ACM_ARN from a previous successful run).
    # shellcheck disable=SC1090
    if [[ -f "$ACME_STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$ACME_STATE_FILE"
    fi

    # Idempotency early-return (D-12): if the stable ACM ARN is already
    # Let's Encrypt-issued, skip the entire step — even when --skip-acme is NOT
    # set. This is what makes a second `bash configure-workshop.sh` succeed
    # without ACM churn.
    if [[ "$SKIP_ACME" != true ]] && [[ -n "${STABLE_ACM_ARN:-}" ]]; then
        CURRENT_ISSUER=$(aws acm describe-certificate \
            --certificate-arn "$STABLE_ACM_ARN" \
            --region "$REGION" \
            --query 'Certificate.Issuer' --output text 2>/dev/null || echo "")
        if echo "$CURRENT_ISSUER" | grep -q "Let's Encrypt"; then
            print_pass "Step 4: ACME cert already trusted (Let's Encrypt issuer confirmed)"
            return 0
        fi
    fi

    if [[ "$SKIP_ACME" = true ]]; then
        print_info "Step 4: ACME skipped (--skip-acme)"
        PASSES+=("Step 4: ACME (skipped)")
        return 0
    fi

    if [[ "$DRY_RUN" = true ]]; then
        print_info "[DRY-RUN] Would resolve shared workshop-acme ALB hostname (kubectl get ingress)"
        print_info "[DRY-RUN] Would compute nip.io FQDNs and apply cert-manager Certificate CR (issuerRef.name=letsencrypt-prod)"
        print_info "[DRY-RUN] Would wait for Certificate Ready=true (timeout 300s)"
        print_info "[DRY-RUN] Would bootstrap: aws acm import-certificate --certificate-arn \$STABLE_ACM_ARN ..."
        print_info "[DRY-RUN] Would write ${ACME_STATE_FILE} with DEPLOY_ID/ALB_IP/NIP_FQDN_*/STABLE_ACM_ARN"
        print_info "[DRY-RUN] Would run: terraform -chdir=${PROJECT_ROOT}/infrastructure apply -auto-approve -target=module.ivia"
        print_pass "Step 4: ACME cert issuance + ACM bootstrap sync (dry-run)"
        return 0
    fi

    # (1) Resolve shared workshop-acme ALB hostname — Plan 02 IngressGroup
    # contract requires both IVIA WRP and banking-UI Ingresses to share ONE ALB.
    WRP_ALB=$(kubectl --context workshop get ingress -n verify-access ivia-wrp \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    BANKING_ALB=$(kubectl --context workshop get ingress -n banking-app banking-ui-ingress \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [[ -z "$WRP_ALB" ]] || [[ -z "$BANKING_ALB" ]]; then
        print_fail "Step 4: shared workshop-acme ALB hostname" \
            "Could not resolve ALB hostname from IVIA WRP (got '${WRP_ALB}') or banking-UI (got '${BANKING_ALB}') Ingress status. Wait for LBC reconciliation: kubectl get ingress -A | grep alb"
        return 1
    fi

    if [[ "$WRP_ALB" != "$BANKING_ALB" ]]; then
        print_fail "Step 4: shared workshop-acme ALB" \
            "IVIA WRP and banking-UI Ingresses resolved to DIFFERENT ALB hostnames (WRP=${WRP_ALB}, banking=${BANKING_ALB}). Plan 02's alb.ingress.kubernetes.io/group.name=workshop-acme annotation is not effective — verify it is present on BOTH Ingresses: kubectl get ingress -A -o yaml | grep -A1 group.name"
        return 1
    fi

    # (2) Resolve ALB IP via dig (nip.io encodes the IP into the hostname so
    # browsers resolve directly without external DNS).
    ALB_IP=$(dig +short "$WRP_ALB" | head -1)
    if [[ -z "$ALB_IP" ]]; then
        print_fail "Step 4: ALB IP resolution" \
            "dig +short ${WRP_ALB} returned empty. Confirm the ALB has converged with an A record: aws elbv2 describe-load-balancers --region ${REGION}"
        return 1
    fi
    ALB_IP_DASHED=$(echo "$ALB_IP" | tr '.' '-')

    # (3) DEPLOY_ID — generate fresh if missing, preserve on rerun (idempotency).
    if [[ -z "${DEPLOY_ID:-}" ]]; then
        DEPLOY_ID=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c6)
    fi
    if [[ -z "$DEPLOY_ID" ]] || [[ ${#DEPLOY_ID} -lt 6 ]]; then
        print_fail "Step 4: DEPLOY_ID generation" \
            "tr -dc 'a-z0-9' produced empty/short DEPLOY_ID='${DEPLOY_ID}' (expected 6 chars). Re-run with LC_ALL=C bash ${BASH_SOURCE[0]}"
        return 1
    fi
    NIP_FQDN_WRP="wrp.${DEPLOY_ID}.${ALB_IP_DASHED}.nip.io"
    NIP_FQDN_BANKING="banking.${DEPLOY_ID}.${ALB_IP_DASHED}.nip.io"

    # (4) STABLE_ACM_ARN — sourced from terraform output (Plan 04 added the
    # output; D-03 ARN-stability contract per Plan 02 lifecycle.ignore_changes).
    STABLE_ACM_ARN=$(terraform -chdir="${PROJECT_ROOT}/infrastructure" \
        output -raw tls_certificate_arn 2>/dev/null || echo "")
    if [[ -z "$STABLE_ACM_ARN" ]]; then
        print_fail "Step 4: STABLE_ACM_ARN resolution" \
            "terraform output -raw tls_certificate_arn returned empty. Confirm the workshop has been deployed AND the output exists. Check: cd ${PROJECT_ROOT}/infrastructure && terraform output tls_certificate_arn"
        return 1
    fi

    # (5) Render and apply Certificate CR with both nip.io SANs. issuerRef
    # matches Plan 03 ClusterIssuer (letsencrypt-prod). secretName matches the
    # Plan 03 ACM-sync CronJob's mounted secret (workshop-le-tls-secret).
    # renewBefore=720h = 30 days before LE's 90-day expiry (D-09 contract).
    cat <<EOF | kubectl --context workshop apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: workshop-le-tls
  namespace: cert-manager
spec:
  secretName: workshop-le-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${NIP_FQDN_WRP}
    - ${NIP_FQDN_BANKING}
  renewBefore: 720h
EOF

    # (6) Wait for cert-manager to drive the HTTP-01 challenge through Plan 03's
    # solver Ingress (group.order=1 wins before the catch-all). 5 min budget.
    if ! kubectl --context workshop wait \
            --for=condition=Ready certificate/workshop-le-tls \
            -n cert-manager --timeout=300s 2>&1; then
        print_fail "Step 4: Certificate Ready=true" \
            "cert-manager did not mark workshop-le-tls Ready within 300s. Investigate: kubectl describe certificate/workshop-le-tls -n cert-manager; kubectl get challenges,orders -n cert-manager"
        return 1
    fi

    # (7) Bootstrap ACM import — extract the K8s Secret contents and upsert
    # into the SAME ARN the ACM-sync CronJob uses. The CronJob's first 6h cycle
    # would do the same thing — this short-circuits so the ALB serves trusted
    # cert immediately after configure-workshop.sh exits.
    #
    # CR-04 fix (Phase 07.8 code review): `base64 -d` is GNU-specific; BSD
    # base64 (default on macOS attendee shells) uses `-D` and rejects `-d`
    # with `usage: base64 [-Ddi] ...` — writes an empty file, then
    # aws acm import-certificate fails with MalformedCertificateException
    # (a misleading failure that reads as "ACM rejected my cert" rather
    # than "my base64 binary is BSD"). `--decode` is the portable spelling.
    # cert-manager concatenates leaf + intermediate(s) [+ root] into tls.crt
    # (kubernetes.io/tls secret format). ACM import-certificate requires the
    # leaf in --certificate and the rest in --certificate-chain, so split.
    # ca.crt is NOT populated by cert-manager — relying on it yields an empty
    # chain file and a misleading "Member must have length >= 1" ACM error.
    kubectl --context workshop get secret workshop-le-tls-secret -n cert-manager \
        -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/tls-bundle.pem
    kubectl --context workshop get secret workshop-le-tls-secret -n cert-manager \
        -o jsonpath='{.data.tls\.key}' | base64 --decode > /tmp/tls.key
    awk '/-----BEGIN CERTIFICATE-----/{n++} n==1{print > "/tmp/tls.crt"} n>1{print > "/tmp/chain.pem"}' /tmp/tls-bundle.pem
    rm -f /tmp/tls-bundle.pem
    if [[ ! -s /tmp/tls.crt ]] || [[ ! -s /tmp/chain.pem ]]; then
        rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem
        print_fail "Step 4: split leaf/chain" \
            "Failed to split tls.crt bundle (leaf=$(stat -f%z /tmp/tls.crt 2>/dev/null || echo 0)B, chain=$(stat -f%z /tmp/chain.pem 2>/dev/null || echo 0)B). Inspect: kubectl get secret workshop-le-tls-secret -n cert-manager -o jsonpath='{.data.tls\\.crt}' | base64 --decode"
        return 1
    fi

    if ! aws acm import-certificate \
            --certificate-arn "$STABLE_ACM_ARN" \
            --certificate "fileb:///tmp/tls.crt" \
            --private-key "fileb:///tmp/tls.key" \
            --certificate-chain "fileb:///tmp/chain.pem" \
            --region "$REGION" >/dev/null; then
        rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem
        print_fail "Step 4: aws acm import-certificate" \
            "Bootstrap ACM upsert failed. The ACM-sync CronJob will retry every 6h; if you want trusted cert before then, debug with: aws acm describe-certificate --certificate-arn ${STABLE_ACM_ARN} --region ${REGION}"
        return 1
    fi
    # Clean cert content tempfiles immediately (STRIDE T-tls-key-on-disk).
    rm -f /tmp/tls.crt /tmp/tls.key /tmp/chain.pem

    # (8) Persist .acme-state — consumed by Plan 05's wrp_effective_host re-wire,
    # by verify-tls.sh, and by this step on the next rerun (DEPLOY_ID preserved).
    cat > "$ACME_STATE_FILE" <<EOF
DEPLOY_ID=${DEPLOY_ID}
ALB_IP=${ALB_IP}
ALB_IP_DASHED=${ALB_IP_DASHED}
NIP_FQDN_WRP=${NIP_FQDN_WRP}
NIP_FQDN_BANKING=${NIP_FQDN_BANKING}
STABLE_ACM_ARN=${STABLE_ACM_ARN}
EOF

    # (9) Propagate NIP_FQDN_WRP from .acme-state into module.ivia → flips
    # wrp_effective_host → re-hashes base_layer_hash → triggers ConfigMap
    # recreation + autoconf Job re-run → flips IVIA AAC DB MMFA endpoint URLs
    # to nip.io (D-07). Idempotent: a re-run with unchanged .acme-state
    # produces no diff and exits 0. Per project rule
    # `feedback_changes_through_existing_scripts.md` — all changes go through
    # the script, not a manual operator step.
    if ! terraform -chdir="${PROJECT_ROOT}/infrastructure" apply -auto-approve -target=module.ivia; then
        print_fail "Step 4: post-ACME terraform apply -target=module.ivia" \
            "Re-run with TF_LOG=DEBUG; check .acme-state has NIP_FQDN_WRP populated. Last value: NIP_FQDN_WRP=${NIP_FQDN_WRP}"
        return 1
    fi

    # (10) MANDATORY IVIA post-apply restart — autoconf omits k8s_deployments,
    # so iviawrprp1 + iviaruntime keep stale base_layer/policy in memory
    # (manifests as 0x31 login error + FBTAUT003E policy reload). Documented in
    # docs/IVIA_Deployment.md §7a and project rule project_ivia_post_apply_restart.
    #
    # WR-05 fix (Phase 07.8 code review): `|| true` previously swallowed
    # rollout-restart / rollout-status errors entirely, so a missing
    # deployment, unreachable cluster, or RBAC failure would let Step 4
    # report SUCCESS while WRP + runtime never actually picked up the new
    # TLS material — attendees then saw stale cert behavior with no error
    # trail. Replaced with `print_warn` that captures rc and surfaces in
    # the Step-4 summary. NOT a return 1: the ACM import at step (7) has
    # already succeeded, so a failed rollout-restart is a recoverable
    # warning (manual `kubectl rollout restart` resolves), not a fatal.
    local ROLLOUT_FAILURE=false
    local _rc=0
    kubectl --context workshop -n verify-access rollout restart deploy/iviawrprp1 deploy/iviaruntime >/dev/null 2>&1
    _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        print_warn "Step 4: rollout restart deploy/iviawrprp1 + deploy/iviaruntime failed (rc=${_rc}). Cert is imported but WRP+runtime may still hold stale TLS material; run manually: kubectl --context workshop -n verify-access rollout restart deploy/iviawrprp1 deploy/iviaruntime"
        ROLLOUT_FAILURE=true
    else
        kubectl --context workshop -n verify-access rollout status deploy/iviawrprp1 --timeout=180s >/dev/null 2>&1
        _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            print_warn "Step 4: rollout status deploy/iviawrprp1 did not reach Ready within 180s (rc=${_rc}). Inspect: kubectl --context workshop -n verify-access describe deploy/iviawrprp1"
            ROLLOUT_FAILURE=true
        fi
        kubectl --context workshop -n verify-access rollout status deploy/iviaruntime --timeout=180s >/dev/null 2>&1
        _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            print_warn "Step 4: rollout status deploy/iviaruntime did not reach Ready within 180s (rc=${_rc}). Inspect: kubectl --context workshop -n verify-access describe deploy/iviaruntime"
            ROLLOUT_FAILURE=true
        fi
    fi

    if [[ "${ROLLOUT_FAILURE}" = "true" ]]; then
        print_pass "Step 4: ACME cert issued + imported (${NIP_FQDN_WRP}, ${NIP_FQDN_BANKING}); module.ivia converged on nip.io — BUT one or more IVIA rollout-restart/status checks failed (see warnings above). Manual restart may be required before browser/mobile trust works."
    else
        print_pass "Step 4: ACME cert issued and imported to ACM (${NIP_FQDN_WRP}, ${NIP_FQDN_BANKING}); module.ivia converged on nip.io; iviawrprp1+iviaruntime rolled"
    fi
    return 0
}

echo ""
echo -e "${YELLOW}> Step 4: ACME cert issuance + ACM bootstrap sync${NC}"
_run_acme_step

#===============================================================================
# STEP 5: Configure Vault (vault-configure.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 5: Configure Vault${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: vault-configure.sh"
    print_pass "Step 5: Configure Vault (dry-run)"
else
    if _run_subscript "Step 5: vault-configure" "${SCRIPT_DIR}/vault-configure.sh"; then
        # Verify: vault auth list should show kubernetes/ and jwt/
        kubectl --context workshop port-forward svc/vault -n vault 8200:8200 \
            >/dev/null 2>&1 &
        VAULT_PF_PID=$!
        if _wait_for_port 8200 30; then
            ROOT_TOKEN=""
            if [[ -f "${HOME}/vault-init.json" ]]; then
                ROOT_TOKEN=$(jq -r '.root_token // empty' "${HOME}/vault-init.json" 2>/dev/null || echo "")
            fi
            if [[ -n "$ROOT_TOKEN" ]]; then
                AUTH_LIST=$(VAULT_ADDR="http://localhost:8200" VAULT_TOKEN="$ROOT_TOKEN" \
                    vault auth list -format=json 2>/dev/null || echo '{}')
                K8S_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "kubernetes/")' 2>/dev/null || echo "")
                JWT_ENABLED=$(echo "$AUTH_LIST" | jq -r 'keys[] | select(. == "jwt/")' 2>/dev/null || echo "")
                if [[ -n "$K8S_ENABLED" ]] && [[ -n "$JWT_ENABLED" ]]; then
                    print_pass "Step 5: Configure Vault (kubernetes/ and jwt/ auth methods enabled)"
                else
                    print_fail "Step 5: Configure Vault — auth methods missing" \
                        "kubernetes=${K8S_ENABLED:-MISSING} jwt=${JWT_ENABLED:-MISSING}. Re-run: ${SCRIPT_DIR}/vault-configure.sh"
                fi
            else
                print_warn "Step 5: Could not verify Vault auth — root token not found in ~/vault-init.json"
            fi
        else
            print_warn "Step 5: Could not verify Vault auth via port-forward"
        fi
        if [[ -n "$VAULT_PF_PID" ]] && kill -0 "$VAULT_PF_PID" 2>/dev/null; then
            kill "$VAULT_PF_PID" 2>/dev/null || true
            VAULT_PF_PID=""
        fi
    fi
fi

#===============================================================================
# STEP 6: Configure IVIA (ivia-configure.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 6: Configure IVIA${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: ivia-configure.sh"
    print_pass "Step 6: Configure IVIA (dry-run)"
else
    if _run_subscript "Step 6: ivia-configure" "${SCRIPT_DIR}/ivia-configure.sh"; then
        # Verify: IVIA health endpoint responds
        IVIA_HEALTH=""
        if kubectl --context workshop get pods -n verify-access --no-headers 2>/dev/null | grep -q Running; then
            kubectl --context workshop port-forward \
                svc/iviaop -n verify-access 8436:8436 \
                >/dev/null 2>&1 &
            _IVIA_PF_PID=$!
            sleep 3
            IVIA_HEALTH=$(curl -sk \
                "https://localhost:8436/oauth2/.well-known/openid-configuration" \
                2>/dev/null | jq -r '.issuer // empty' 2>/dev/null || echo "")
            kill "$_IVIA_PF_PID" 2>/dev/null || true
        fi
        if [[ -n "$IVIA_HEALTH" ]]; then
            print_pass "Step 6: Configure IVIA (OIDC issuer: ${IVIA_HEALTH})"
        else
            print_warn "Step 6: Could not verify IVIA OIDC health endpoint (IVIA may still be starting)"
        fi
    fi
fi

#===============================================================================
# STEP 7: Verify OpenLDAP user 'oscar' seeded by IVIA autoconf
#===============================================================================
# User 'oscar' is seeded into the in-cluster OpenLDAP automatically by IVIA
# autoconf (webseal.pdadmin.users in modules/verify_access/base_layer/base_layer.yaml).
# This step verifies the seed succeeded.
echo ""
echo -e "${YELLOW}> Step 7: Verify OpenLDAP user 'oscar' seeded${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would query in-cluster OpenLDAP for cn=oscar"
    print_pass "Step 7: OpenLDAP user check (dry-run)"
else
    # CR-02 fix (Phase 07.8 code review): Step 7 was the only place in
    # configure-workshop.sh that dropped --context workshop. Without it, the
    # calls silently target the attendee's current default context (extremely
    # common to be wrong during the workshop); kubectl returns nothing,
    # LDAP_PW="", and the ldapsearch reports a spurious red flag.
    # (Also fixes base64 -d -> base64 --decode for BSD/macOS portability;
    # see CR-04 in REVIEW.md for the same regression in Step 4.)
    LDAP_PW=$(kubectl --context workshop get secret openldap-creds -n verify-access -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    if [ -n "${LDAP_PW}" ] && kubectl --context workshop exec -n verify-access deploy/openldap -- \
            ldapsearch -x -H ldapi:/// -D "cn=admin,dc=ibm,dc=com" -w "${LDAP_PW}" \
            -b "dc=ibm,dc=com" "(cn=oscar)" dn 2>/dev/null | grep -q '^dn:'; then
        print_pass "Step 7: OpenLDAP user 'oscar' present (seeded by IVIA autoconf)"
    else
        print_warn "Step 7: OpenLDAP user 'oscar' NOT found — re-run terraform apply or inspect ivia-autoconf job logs"
    fi
fi

#===============================================================================
# STEP 8: Seed Banking DB (seed-banking-db.sh)
#===============================================================================
echo ""
echo -e "${YELLOW}> Step 8: Seed Banking DB${NC}"

if [[ "$DRY_RUN" = true ]]; then
    print_info "[DRY-RUN] Would run: seed-banking-db.sh --region ${REGION}"
    print_pass "Step 8: Seed Banking DB (dry-run)"
else
    if _run_subscript "Step 8: seed-banking-db" \
            "${SCRIPT_DIR}/seed-banking-db.sh" \
            --region "${REGION}"; then
        print_pass "Step 8: Seed Banking DB (script verified successfully)"
    fi
fi

#===============================================================================
# Summary is emitted by the EXIT trap (_cleanup)
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Configuration Complete${NC}"
echo -e "${BLUE}================================================================${NC}"
