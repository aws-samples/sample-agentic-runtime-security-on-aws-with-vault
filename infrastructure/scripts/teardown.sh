#!/usr/bin/env bash
#===============================================================================
# Workshop Teardown — Agentic Runtime Security on AWS
#
# Single-file teardown. Wipes EVERYTHING the workshop provisioned.
#
# Usage:
#   teardown.sh                    Full nuke: terraform destroy + AWS sweep
#   teardown.sh --keep-eks         Wipe EVERYTHING except EKS cluster + VPC + addons
#                                  (preserves the slow-to-rebuild infra; nukes
#                                  RDS, Vault, IVIA, Bedrock KB, S3, ECR, KMS,
#                                  IAM, in-cluster workloads + their PVCs)
#   teardown.sh --post-destroy-only  Skip terraform destroy, run full orphan sweep
#   teardown.sh --aws-only         Only AWS resources (K8s drain + tag-scoped sweep)
#   teardown.sh --dry-run          Preview without executing
#   teardown.sh --yes              Non-interactive: auto-confirm every prompt the
#                                  script issues (today's script issues zero
#                                  prompts, but --yes is the documented contract
#                                  for the Instruqt distribution's cleanup-cloud-client,
#                                  which has no tty — any prompt added later is
#                                  silently 'y' under this flag). Required by
#                                  instruqt/track/track_scripts/cleanup-cloud-client.
#   teardown.sh --help             Show this help
#
# Discovery: Workshop tag `Workshop=agentic-runtime-security` + the well-known
# names this workshop uses (cluster `agentic-runtime-usw2`, S3 buckets prefixed
# `workshop-kb-corpus`, Glue DB `workshop_logs`, Athena workgroup `workshop`,
# CW log groups `/workshop/*`, RDS instance `<cluster>-pg`).
#===============================================================================

set -e
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Three Terraform roots (provisioning-order refactor). Destroyed in REVERSE
# dependency order: workloads (tier 3) → services (tier 2) → infrastructure
# (tier 1), so terraform can cleanly uninstall in-cluster Helm/K8s resources
# (Vault server, IVIA, banking app) via the live cluster API BEFORE the EKS
# control plane is torn down and BEFORE phase_k8s_cleanup force-drains namespaces.
TIER1_DIR="${REPO_ROOT}/infrastructure"
TIER2_DIR="${REPO_ROOT}/infrastructure/services"
TIER3_DIR="${REPO_ROOT}/infrastructure/workloads"

#-------------------------------------------------------------------------------
# Workshop constants
#-------------------------------------------------------------------------------
WORKSHOP_TAG_KEY="Workshop"
WORKSHOP_TAG_VAL="agentic-runtime-security"

# Default cluster — resolved from infrastructure/terraform.tfvars.
# Workshop is single-region single-cluster. Override with $CLUSTER_NAME env var.
DEFAULT_CLUSTER=""

# Known name-prefixes the workshop uses (for resources without tag visibility).
# Note: workshop-athena-* (NOT workshop-athena-results) — actual bucket name has
# no `-results` suffix; that mismatch made the sweep miss the bucket on a prior
# teardown (audit on 2026-05-08).
S3_BUCKET_PREFIXES=("workshop-kb-corpus" "workshop-kb-multimodal" "workshop-athena")
GLUE_DB_NAMES=("workshop_logs")
ATHENA_WG_NAMES=("workshop")
# CW_LOG_PREFIXES set after DEFAULT_CLUSTER is resolved (below).

#-------------------------------------------------------------------------------
# Colors + print helpers
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

phase_header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}
step_header() { echo -e "\n${YELLOW}--- $1 ---${NC}"; }
print_success() { echo -e "${GREEN}  $1${NC}"; }
print_error()   { echo -e "${RED}  $1${NC}"; }
print_info()    { echo -e "${BLUE}  $1${NC}"; }
print_warn()    { echo -e "${YELLOW}  $1${NC}"; }

#-------------------------------------------------------------------------------
# CLI defaults + parsing
#-------------------------------------------------------------------------------
DRY_RUN=false
AWS_ONLY=false
POST_DESTROY_ONLY=false
KEEP_EKS=false
# --yes: non-interactive contract for the Instruqt cleanup-cloud-client. Today's script
# has no interactive prompts (verified via `grep -nE 'read -[pr]|confirm' teardown.sh`
# returning only false positives inside `while IFS= read` loops), so ASSUME_YES is
# currently a documented no-op. Any future prompt MUST gate on `[ "$ASSUME_YES" = true ]`
# and treat it as 'y' so the Instruqt sandbox (no tty) never hangs.
ASSUME_YES=false

usage() {
    sed -n '2,28p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --aws-only)           AWS_ONLY=true ;;
        --post-destroy-only)  POST_DESTROY_ONLY=true ;;
        --keep-eks)           KEEP_EKS=true ;;
        --dry-run)            DRY_RUN=true ;;
        --yes|-y)             ASSUME_YES=true ;;
        --help|-h)  usage ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            ;;
    esac
    shift
done

local_exclusive=0
[ "$AWS_ONLY" = true ] && local_exclusive=$((local_exclusive + 1))
[ "$POST_DESTROY_ONLY" = true ] && local_exclusive=$((local_exclusive + 1))
[ "$KEEP_EKS" = true ] && local_exclusive=$((local_exclusive + 1))
if [ "$local_exclusive" -gt 1 ]; then
    echo -e "${RED}Error: --aws-only, --post-destroy-only, and --keep-eks are mutually exclusive${NC}" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# Region resolution (canonical contract: terraform.tfvars carries the literal
# "us-west-2" — everything else reads it from there or $AWS_REGION).
# Falls back to terraform.tfvars.example if terraform.tfvars doesn't exist.
#-------------------------------------------------------------------------------
TF_VARS="${REPO_ROOT}/infrastructure/terraform.tfvars"
TF_VARS_EXAMPLE="${REPO_ROOT}/infrastructure/terraform.tfvars.example"

REGION="${AWS_REGION:-}"
if [ -z "$REGION" ]; then
    for f in "$TF_VARS" "$TF_VARS_EXAMPLE"; do
        if [ -f "$f" ]; then
            REGION=$(grep -E '^\s*region\s*=\s*"' "$f" 2>/dev/null \
                | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
            [ -n "$REGION" ] && break
        fi
    done
fi
if [ -z "$REGION" ]; then
    echo -e "${RED}Error: could not resolve region from terraform.tfvars or AWS_REGION.${NC}" >&2
    exit 1
fi

DEFAULT_CLUSTER="${CLUSTER_NAME:-}"
if [ -z "$DEFAULT_CLUSTER" ]; then
    for f in "$TF_VARS" "$TF_VARS_EXAMPLE"; do
        if [ -f "$f" ]; then
            DEFAULT_CLUSTER=$(grep -E '^\s*cluster_name\s*=\s*"' "$f" 2>/dev/null \
                | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
            [ -n "$DEFAULT_CLUSTER" ] && break
        fi
    done
fi
if [ -z "$DEFAULT_CLUSTER" ]; then
    echo -e "${RED}Error: could not resolve cluster_name from terraform.tfvars or CLUSTER_NAME.${NC}" >&2
    exit 1
fi

CW_LOG_PREFIXES=("/workshop/" "/aws/eks/${DEFAULT_CLUSTER}/" "/aws/rds/instance/${DEFAULT_CLUSTER}-pg")
S3_BUCKET_PREFIXES+=("${DEFAULT_CLUSTER}-workshop-logs")

# KB region — Nova 2 Multimodal Embeddings is us-east-1 only; KB components
# (AOSS, Bedrock KB, S3 corpus/multimodal, CFN index stack) live there.
KB_REGION="${KB_REGION:-us-east-1}"


#===============================================================================
# Per-root terraform destroy (provisioning-order refactor)
# Destroys ONE root, best-effort. Runs a bare `terraform init` first (NEVER
# `init -upgrade` — that silently bumps loosely-pinned modules and fabricates
# drift). Skips cleanly when the root was never initialized / has empty state.
#===============================================================================
_destroy_root() {
    local label="$1" dir="$2"
    if [ ! -d "$dir" ]; then
        print_info "${label}: ${dir} not present — skipping"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run: terraform -chdir=${dir} init && terraform -chdir=${dir} destroy -auto-approve"
        return 0
    fi
    if [ ! -d "${dir}/.terraform" ]; then
        # Not yet initialized — try a bare init so destroy can read providers/state.
        terraform -chdir="$dir" init -input=false >/dev/null 2>&1 || {
            print_info "${label}: no .terraform and init failed — skipping (nothing to destroy)"
            return 0
        }
    fi
    local n
    n=$(terraform -chdir="$dir" state list 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -eq 0 ]; then
        print_info "${label}: state empty — nothing to destroy"
        return 0
    fi
    print_info "${label}: destroying ${n} resource(s) in ${dir}"
    terraform -chdir="$dir" destroy -auto-approve \
        || print_warn "${label}: terraform destroy had errors — AWS sweep will catch residuals"
}

#===============================================================================
# K8S CLEANUP
# Drain LB-controller-managed services (NLB/ALB) so VPC delete doesn't fail with
# DependencyViolation. Best-effort — silently skipped if cluster unreachable.
#===============================================================================
phase_k8s_cleanup() {
    phase_header "K8s Cleanup (drain LB controller resources)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would update kubeconfig and delete workloads + LBs"
        return 0
    fi

    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_info "Cluster $DEFAULT_CLUSTER not found — skipping K8s cleanup"
        return 0
    fi

    aws eks update-kubeconfig --name "$DEFAULT_CLUSTER" --region "$REGION" \
        --alias "$DEFAULT_CLUSTER" >/dev/null 2>&1 || {
        print_warn "Could not update kubeconfig — skipping K8s cleanup"
        return 0
    }
    kubectl config use-context "$DEFAULT_CLUSTER" >/dev/null 2>&1 || true
    print_success "Kubeconfig set to $DEFAULT_CLUSTER"

    # === Phase 7 cleanup: drop ivia_hvdb PostgreSQL role + schema from shared RDS ===
    # CONTEXT R3: the legacy verify_access module bootstrap Job created an ivia_hvdb
    # role+schema on the shared RDS instance. Phase 7 moves HVDB into the postgresql
    # pod, so this RDS state is orphaned on destroy. Drop it idempotently before
    # tearing down module.ivia.
    local INFRA_DIR="${REPO_ROOT}/infrastructure"
    print_info "Dropping ivia_hvdb role+schema from shared RDS (idempotent)..."
    RDS_ENDPOINT=$(cd "${INFRA_DIR}" && terraform output -raw rds_endpoint 2>/dev/null || echo "")
    RDS_ADMIN=$(cd "${INFRA_DIR}" && terraform output -raw rds_master_username 2>/dev/null || echo "")
    RDS_SECRET_ARN=$(cd "${INFRA_DIR}" && terraform output -raw rds_master_user_secret_arn 2>/dev/null || echo "")
    if [ -n "${RDS_ENDPOINT}" ] && [ -n "${RDS_ADMIN}" ] && [ -n "${RDS_SECRET_ARN}" ]; then
        RDS_PWD=$(aws secretsmanager get-secret-value --secret-id "${RDS_SECRET_ARN}" \
            --query SecretString --output text 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("password",""))')
        if [ -n "${RDS_PWD}" ]; then
            PGPASSWORD="${RDS_PWD}" psql -h "${RDS_ENDPOINT%:*}" -U "${RDS_ADMIN}" -d postgres \
                -c 'DROP SCHEMA IF EXISTS ivia_hvdb CASCADE; DROP ROLE IF EXISTS ivia_hvdb;' \
                >/dev/null 2>&1 \
              && print_success "ivia_hvdb role+schema dropped" \
              || print_warn "ivia_hvdb drop returned non-zero (likely already absent — safe)"
        else
            print_warn "RDS master password could not be retrieved; skipping ivia_hvdb drop"
        fi
    else
        print_info "Shared RDS not present in terraform output — skipping ivia_hvdb drop (already torn down?)"
    fi

    # === Phase 7 cleanup: explicit verify-access object sweep ===
    # Issue the LBC-managed Service/Ingress deletes NON-BLOCKING (--wait=false).
    # Do NOT let kubectl block on the ingress.k8s.aws/resources finalizer here:
    # in FULL mode `terraform destroy` runs first and may already have torn out
    # the LB controller's NAT egress + pod-identity, leaving the controller a
    # live pod with no route or creds to the AWS APIs. A plain `kubectl delete
    # ingress` (default --wait) would then hang FOREVER waiting for a finalizer
    # the severed controller can never strip. We instead delete the ALBs/NLBs
    # directly via the AWS CLI below (which works from the operator's machine),
    # then force-clear the finalizers so the objects — and their namespaces —
    # drain cleanly. Order: release LBs -> clear finalizers -> drain namespaces.
    print_info "Sweeping verify-access namespace objects (LB-managed first)..."
    kubectl delete -n verify-access --ignore-not-found --wait=false service iviaconfig-nlb 2>/dev/null || true
    kubectl delete -n verify-access --ignore-not-found --wait=false ingress ivia-wrp 2>/dev/null || true

    # Force-delete every ALB/NLB in the cluster's VPC. This is what actually
    # releases the ENIs that block VPC/subnet/IGW deletion, and it does not
    # depend on the in-cluster controller being reachable.
    local vpc_id
    vpc_id=$(aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)
    if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
        local lbs
        lbs=$(aws elbv2 describe-load-balancers --region "$REGION" \
            --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null)
        for arn in $lbs; do
            [[ -z "$arn" || "$arn" == "None" ]] && continue
            print_info "Force-deleting LB $arn"
            aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" &>/dev/null || true
        done
    fi

    # Force-remove the AWS-LBC finalizer from any Ingress still stuck Terminating.
    # The controller normally strips ingress.k8s.aws/resources after it deletes
    # the ALB; if it is network-severed it never will. Now that the ALB is gone,
    # clear the finalizer ourselves (mirror of the stuck-PVC handling below) so
    # the namespace delete loop completes instead of blocking on a zombie object.
    for ns in vault verify-access uc1 banking-app; do
        for ing in $(kubectl get ingress -n "$ns" -o name 2>/dev/null); do
            print_info "Clearing stuck finalizer on $ns/$ing"
            kubectl patch "$ing" -n "$ns" --type=merge \
                -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
        done
    done

    # Now drain the workshop namespaces — the LB objects are released and their
    # finalizers cleared, so these complete instead of hanging.
    for ns in vault verify-access uc1 banking-app; do
        if kubectl get namespace "$ns" &>/dev/null; then
            print_info "Deleting namespace $ns..."
            kubectl delete namespace "$ns" --ignore-not-found --timeout=120s 2>/dev/null || true
        fi
    done
}

#===============================================================================
# AWS SWEEP — tag-scoped + name-prefix-scoped
# Order matters: dependencies first (data sources before parents, ENIs/endpoints
# before VPC, etc.).
#===============================================================================

#----- EKS pod-identity associations (must run before cluster delete) ----------
sweep_eks_pod_identity() {
    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_info "EKS pod-identity: cluster gone, skipping"; return 0
    fi
    local assocs
    assocs=$(aws eks list-pod-identity-associations --cluster-name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'associations[].associationId' --output text 2>/dev/null)
    if [[ -z "$assocs" || "$assocs" == "None" ]]; then
        print_info "EKS pod-identity: none found"; return 0
    fi
    for a in $assocs; do
        echo -n "    Deleting pod-identity association $a... "
        if aws eks delete-pod-identity-association --cluster-name "$DEFAULT_CLUSTER" \
                --association-id "$a" --region "$REGION" &>/dev/null; then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    done
}

#----- EKS managed addons (delete before node groups to let finalizers run) ----
sweep_eks_addons() {
    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_info "EKS addons: cluster gone, skipping"; return 0
    fi
    local addons
    addons=$(aws eks list-addons --cluster-name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'addons[]' --output text 2>/dev/null)
    if [[ -z "$addons" || "$addons" == "None" ]]; then
        print_info "EKS addons: none"; return 0
    fi
    for addon in $addons; do
        echo -n "    Deleting addon $addon... "
        if aws eks delete-addon --cluster-name "$DEFAULT_CLUSTER" --addon-name "$addon" \
                --region "$REGION" &>/dev/null; then
            echo -e "${GREEN}initiated${NC}"
        else
            echo -e "${YELLOW}skipped${NC}"
        fi
    done
    echo -n "    Waiting for addons to delete"
    local waited=0
    while [[ $waited -lt 120 ]]; do
        local rem
        rem=$(aws eks list-addons --cluster-name "$DEFAULT_CLUSTER" --region "$REGION" \
            --query 'addons[]' --output text 2>/dev/null)
        [[ -z "$rem" || "$rem" == "None" ]] && { echo -e " ${GREEN}done${NC}"; return 0; }
        sleep 10; waited=$((waited + 10)); echo -n "."
    done
    echo -e " ${YELLOW}timeout (continuing)${NC}"
}

#----- EKS node groups + cluster -----------------------------------------------
sweep_eks_nodegroups() {
    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_info "EKS node groups: cluster gone, skipping"; return 0
    fi
    local ngs
    ngs=$(aws eks list-nodegroups --cluster-name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'nodegroups[]' --output text 2>/dev/null)
    if [[ -z "$ngs" ]]; then
        print_info "EKS node groups: none"; return 0
    fi
    for ng in $ngs; do
        echo -n "    Deleting node group $ng... "
        aws eks delete-nodegroup --cluster-name "$DEFAULT_CLUSTER" --nodegroup-name "$ng" \
            --region "$REGION" &>/dev/null && echo -e "${GREEN}initiated${NC}" || echo -e "${RED}failed${NC}"
    done
    echo -n "    Waiting for node groups to delete"
    local waited=0
    while [[ $waited -lt 600 ]]; do
        local rem
        rem=$(aws eks list-nodegroups --cluster-name "$DEFAULT_CLUSTER" --region "$REGION" \
            --query 'nodegroups[]' --output text 2>/dev/null)
        [[ -z "$rem" ]] && { echo -e " ${GREEN}done${NC}"; return 0; }
        sleep 15; waited=$((waited + 15)); echo -n "."
    done
    echo -e " ${YELLOW}timeout (continuing)${NC}"
}

sweep_eks_cluster() {
    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_info "EKS cluster: gone"; return 0
    fi
    echo -n "    Deleting EKS cluster $DEFAULT_CLUSTER... "
    aws eks delete-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null \
        && echo -e "${GREEN}initiated${NC}" || { echo -e "${RED}failed${NC}"; return 1; }
    echo -n "    Waiting for cluster delete"
    local waited=0
    while [[ $waited -lt 900 ]]; do
        if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
            echo -e " ${GREEN}done${NC}"; return 0
        fi
        sleep 30; waited=$((waited + 30)); echo -n "."
    done
    echo -e " ${YELLOW}timeout${NC}"
}

sweep_eks_oidc_provider() {
    local issuer="" in_use=""
    aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null \
        && issuer=$(aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)
    for c in $(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null); do
        in_use="$in_use $(aws eks describe-cluster --name "$c" --region "$REGION" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)"
    done
    local count=0
    for arn in $(aws iam list-open-id-connect-providers \
            --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null); do
        [[ "$arn" == *"oidc.eks.${REGION}.amazonaws.com/id/"* ]] || continue
        local arn_url="https://${arn#*oidc-provider/}"
        local should_delete=false
        if [[ -n "$issuer" && "$arn_url" == "$issuer" ]]; then
            should_delete=true
        elif [[ -z "$issuer" ]]; then
            local seen=false
            for u in $in_use; do [[ "$arn_url" == "$u" ]] && seen=true; done
            [[ "$seen" == false ]] && should_delete=true
        fi
        [[ "$should_delete" == true ]] && \
            aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" &>/dev/null \
            && count=$((count + 1))
    done
    if [[ $count -eq 0 ]]; then print_info "EKS OIDC providers: none to delete"
    else print_success "EKS OIDC providers: deleted $count"; fi
}

#----- EBS volumes (orphaned from PVCs after cluster delete) -------------------
sweep_ebs_volumes() {
    local vols
    vols=$(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null)
    if [[ -z "$vols" || "$vols" == "None" ]]; then
        vols=$(aws ec2 describe-volumes --region "$REGION" \
            --filters "Name=tag:kubernetes.io/cluster/${DEFAULT_CLUSTER},Values=owned" \
            --query 'Volumes[].VolumeId' --output text 2>/dev/null)
    fi
    if [[ -z "$vols" || "$vols" == "None" ]]; then
        print_info "EBS volumes: none"; return 0
    fi
    for vol in $vols; do
        local state
        state=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol" \
            --query 'Volumes[0].State' --output text 2>/dev/null)
        if [[ "$state" == "in-use" ]]; then
            echo -n "    Force-detaching volume $vol... "
            aws ec2 detach-volume --volume-id "$vol" --region "$REGION" --force &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
            sleep 5
        fi
        echo -n "    Deleting EBS volume $vol... "
        aws ec2 delete-volume --volume-id "$vol" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- Launch templates (orphaned after EKS node group API-delete) -------------
sweep_launch_templates() {
    local lts
    lts=$(aws ec2 describe-launch-templates --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null)
    if [[ -z "$lts" || "$lts" == "None" ]]; then
        print_info "Launch templates: none"; return 0
    fi
    for lt in $lts; do
        echo -n "    Deleting launch template $lt... "
        aws ec2 delete-launch-template --launch-template-id "$lt" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- ECR repositories (workshop container images) ----------------------------
ECR_REPO_NAMES=("workshop/uc1-agent" "workshop/uc3-agent" "workshop-banking-app")
sweep_ecr_repos() {
    local count=0
    for repo in "${ECR_REPO_NAMES[@]}"; do
        if aws ecr describe-repositories --repository-names "$repo" --region "$REGION" &>/dev/null; then
            echo -n "    Deleting ECR repo $repo... "
            if aws ecr delete-repository --repository-name "$repo" --region "$REGION" --force &>/dev/null; then
                echo -e "${GREEN}done${NC}"; count=$((count + 1))
            else
                echo -e "${RED}failed${NC}"
            fi
        fi
    done
    if [[ $count -eq 0 ]]; then print_info "ECR repos: none found"
    else print_success "ECR repos: deleted $count"; fi
}

#----- CloudWatch subscription filters (must delete BEFORE log groups) ---------
sweep_cw_subscription_filters() {
    local count=0
    for prefix in "${CW_LOG_PREFIXES[@]}"; do
        local groups
        groups=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$prefix" \
            --query 'logGroups[].logGroupName' --output text 2>/dev/null)
        for g in $groups; do
            [[ -z "$g" || "$g" == "None" ]] && continue
            local filters
            filters=$(aws logs describe-subscription-filters --region "$REGION" --log-group-name "$g" \
                --query 'subscriptionFilters[].filterName' --output text 2>/dev/null)
            for f in $filters; do
                [[ -z "$f" || "$f" == "None" ]] && continue
                echo -n "    Deleting subscription filter $f on $g... "
                aws logs delete-subscription-filter --region "$REGION" \
                    --log-group-name "$g" --filter-name "$f" &>/dev/null \
                    && { echo -e "${GREEN}done${NC}"; count=$((count + 1)); } \
                    || echo -e "${RED}failed${NC}"
            done
        done
    done
    if [[ $count -eq 0 ]]; then print_info "CW subscription filters: none"
    else print_success "CW subscription filters: deleted $count"; fi
}

#----- Kinesis Firehose delivery streams (cluster-named) -----------------------
sweep_firehose_streams() {
    local streams
    streams=$(aws firehose list-delivery-streams --region "$REGION" \
        --delivery-stream-type DirectPut \
        --query 'DeliveryStreamNames[]' --output text 2>/dev/null)
    if [[ -z "$streams" || "$streams" == "None" ]]; then
        print_info "Firehose streams: none"; return 0
    fi
    local count=0
    for s in $streams; do
        [[ "$s" == "${DEFAULT_CLUSTER}-"* ]] || continue
        echo -n "    Deleting Firehose stream $s... "
        if aws firehose delete-delivery-stream --delivery-stream-name "$s" \
                --region "$REGION" --allow-force-delete &>/dev/null; then
            echo -e "${GREEN}done${NC}"; count=$((count + 1))
        else
            echo -e "${RED}failed${NC}"
        fi
    done
    if [[ $count -eq 0 ]]; then print_info "Firehose streams: none matching ${DEFAULT_CLUSTER}-*"
    else print_success "Firehose streams: deleted $count"; fi
}

#----- RDS ---------------------------------------------------------------------
sweep_rds() {
    local instances
    instances=$(aws rds describe-db-instances --region "$REGION" \
        --query "DBInstances[?TagList[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}']].DBInstanceIdentifier" \
        --output text 2>/dev/null)
    if [[ -z "$instances" || "$instances" == "None" ]]; then
        # Fallback: name prefix
        instances=$(aws rds describe-db-instances --region "$REGION" \
            --query "DBInstances[?starts_with(DBInstanceIdentifier,'${DEFAULT_CLUSTER}')].DBInstanceIdentifier" \
            --output text 2>/dev/null)
    fi

    for db in $instances; do
        [[ -z "$db" || "$db" == "None" ]] && continue
        # Disable deletion protection (idempotent)
        aws rds modify-db-instance --db-instance-identifier "$db" --region "$REGION" \
            --no-deletion-protection --apply-immediately &>/dev/null || true
        echo -n "    Deleting RDS instance $db... "
        if aws rds delete-db-instance --db-instance-identifier "$db" --region "$REGION" \
                --skip-final-snapshot --delete-automated-backups &>/dev/null; then
            echo -e "${GREEN}initiated${NC}"
        else
            echo -e "${YELLOW}skipped (may already be deleting)${NC}"
        fi
    done
    # Wait for instances to be gone
    if [[ -n "$instances" ]]; then
        echo -n "    Waiting for RDS instances to delete"
        local waited=0
        while [[ $waited -lt 900 ]]; do
            local rem
            rem=$(aws rds describe-db-instances --region "$REGION" \
                --query "DBInstances[?starts_with(DBInstanceIdentifier,'${DEFAULT_CLUSTER}')].DBInstanceIdentifier" \
                --output text 2>/dev/null)
            [[ -z "$rem" || "$rem" == "None" ]] && { echo -e " ${GREEN}done${NC}"; break; }
            sleep 20; waited=$((waited + 20)); echo -n "."
        done
        [[ $waited -ge 900 ]] && echo -e " ${YELLOW}timeout${NC}"
    fi

    # Subnet groups + parameter groups (workshop-named)
    local sgs
    sgs=$(aws rds describe-db-subnet-groups --region "$REGION" \
        --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'${DEFAULT_CLUSTER}')].DBSubnetGroupName" \
        --output text 2>/dev/null)
    for s in $sgs; do
        [[ -z "$s" || "$s" == "None" ]] && continue
        echo -n "    Deleting RDS subnet group $s... "
        aws rds delete-db-subnet-group --db-subnet-group-name "$s" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done

    local pgs
    pgs=$(aws rds describe-db-parameter-groups --region "$REGION" \
        --query "DBParameterGroups[?starts_with(DBParameterGroupName,'${DEFAULT_CLUSTER}')].DBParameterGroupName" \
        --output text 2>/dev/null)
    for p in $pgs; do
        [[ -z "$p" || "$p" == "None" ]] && continue
        echo -n "    Deleting RDS param group $p... "
        aws rds delete-db-parameter-group --db-parameter-group-name "$p" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done

    # Enhanced monitoring role (rds-monitoring-role-* by convention)
    local mon_roles
    mon_roles=$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName,'${DEFAULT_CLUSTER}-rds-monitoring')].RoleName" \
        --output text 2>/dev/null)
    for r in $mon_roles; do
        [[ -z "$r" || "$r" == "None" ]] && continue
        echo -n "    Deleting RDS monitoring role $r... "
        for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
            aws iam detach-role-policy --role-name "$r" --policy-arn "$p" &>/dev/null
        done
        aws iam delete-role --role-name "$r" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- Secrets Manager (RDS managed master password) ---------------------------
sweep_secrets_manager() {
    local secrets
    secrets=$(aws secretsmanager list-secrets --region "$REGION" \
        --filters Key=tag-key,Values="${WORKSHOP_TAG_KEY}" Key=tag-value,Values="${WORKSHOP_TAG_VAL}" \
        --query 'SecretList[].ARN' --output text 2>/dev/null)
    if [[ -z "$secrets" || "$secrets" == "None" ]]; then
        secrets=$(aws secretsmanager list-secrets --region "$REGION" \
            --filters Key=name,Values="rds!" \
            --query "SecretList[?contains(Name,'${DEFAULT_CLUSTER}')].ARN" --output text 2>/dev/null)
    fi
    if [[ -z "$secrets" || "$secrets" == "None" ]]; then
        print_info "Secrets Manager: none"; return 0
    fi
    for arn in $secrets; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local name="${arn##*:secret:}"
        echo -n "    Deleting secret $name... "
        aws secretsmanager delete-secret --secret-id "$arn" --region "$REGION" \
            --force-delete-without-recovery &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- AOSS (collection + 3 policies) ------------------------------------------
sweep_aoss() {
    local cols
    cols=$(aws opensearchserverless list-collections --region "$REGION" \
        --query 'collectionSummaries[].id' --output text 2>/dev/null)
    if [[ -n "$cols" && "$cols" != "None" ]]; then
        for cid in $cols; do
            echo -n "    Deleting AOSS collection $cid... "
            aws opensearchserverless delete-collection --id "$cid" --region "$REGION" &>/dev/null \
                && echo -e "${GREEN}initiated${NC}" || echo -e "${YELLOW}skipped${NC}"
        done
        # Wait briefly for collection delete to free policies
        sleep 30
    fi

    for kind in encryption network; do
        for n in $(aws opensearchserverless list-security-policies --region "$REGION" --type "$kind" \
                --query 'securityPolicySummaries[].name' --output text 2>/dev/null); do
            [[ -z "$n" || "$n" == "None" ]] && continue
            echo -n "    Deleting AOSS $kind policy $n... "
            aws opensearchserverless delete-security-policy --name "$n" --type "$kind" --region "$REGION" &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
        done
    done
    for n in $(aws opensearchserverless list-access-policies --region "$REGION" --type data \
            --query 'accessPolicySummaries[].name' --output text 2>/dev/null); do
        [[ -z "$n" || "$n" == "None" ]] && continue
        echo -n "    Deleting AOSS data policy $n... "
        aws opensearchserverless delete-access-policy --name "$n" --type data --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
    done
}

#----- S3 buckets (workshop-named) ---------------------------------------------
sweep_s3_buckets() {
    for prefix in "${S3_BUCKET_PREFIXES[@]}"; do
        local buckets
        buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'${prefix}')].Name" --output text 2>/dev/null)
        for b in $buckets; do
            [[ -z "$b" || "$b" == "None" ]] && continue
            echo -n "    Emptying S3 bucket $b... "
            aws s3 rm "s3://${b}" --recursive --quiet 2>/dev/null || true
            # Delete versions + delete-markers (if versioned)
            aws s3api delete-objects --bucket "$b" --region "$REGION" --delete \
                "$(aws s3api list-object-versions --bucket "$b" --region "$REGION" \
                    --query '{Objects:Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)" &>/dev/null || true
            aws s3api delete-objects --bucket "$b" --region "$REGION" --delete \
                "$(aws s3api list-object-versions --bucket "$b" --region "$REGION" \
                    --query '{Objects:DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)" &>/dev/null || true
            echo -e "${GREEN}emptied${NC}"
            echo -n "    Deleting S3 bucket $b... "
            aws s3api delete-bucket --bucket "$b" --region "$REGION" &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        done
    done
}

#----- Bedrock KB (data sources first, then KB) --------------------------------
sweep_bedrock_kb() {
    local kbs
    kbs=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
        --query 'knowledgeBaseSummaries[].knowledgeBaseId' --output text 2>/dev/null)
    if [[ -z "$kbs" || "$kbs" == "None" ]]; then
        print_info "Bedrock KB: none"; return 0
    fi
    for kb in $kbs; do
        [[ -z "$kb" || "$kb" == "None" ]] && continue
        local dss
        dss=$(aws bedrock-agent list-data-sources --knowledge-base-id "$kb" --region "$REGION" \
            --query 'dataSourceSummaries[].dataSourceId' --output text 2>/dev/null)
        for ds in $dss; do
            [[ -z "$ds" || "$ds" == "None" ]] && continue
            echo -n "    Deleting KB data source $ds... "
            aws bedrock-agent delete-data-source --knowledge-base-id "$kb" --data-source-id "$ds" \
                --region "$REGION" &>/dev/null && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        done
        echo -n "    Deleting Bedrock KB $kb... "
        aws bedrock-agent delete-knowledge-base --knowledge-base-id "$kb" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- Glue + Athena -----------------------------------------------------------
sweep_glue_athena() {
    for db in "${GLUE_DB_NAMES[@]}"; do
        if aws glue get-database --name "$db" --region "$REGION" &>/dev/null; then
            echo -n "    Deleting Glue DB $db... "
            aws glue delete-database --name "$db" --region "$REGION" &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        fi
    done
    for wg in "${ATHENA_WG_NAMES[@]}"; do
        if aws athena get-work-group --work-group "$wg" --region "$REGION" &>/dev/null; then
            echo -n "    Deleting Athena workgroup $wg... "
            aws athena delete-work-group --work-group "$wg" --region "$REGION" --recursive-delete-option &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        fi
    done
}

#----- CloudWatch log groups (/workshop/*, /aws/eks/*, /aws/rds/*) -------------
sweep_cw_log_groups() {
    for prefix in "${CW_LOG_PREFIXES[@]}"; do
        local groups
        groups=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$prefix" \
            --query 'logGroups[].logGroupName' --output text 2>/dev/null)
        for g in $groups; do
            [[ -z "$g" || "$g" == "None" ]] && continue
            echo -n "    Deleting log group $g... "
            aws logs delete-log-group --log-group-name "$g" --region "$REGION" &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        done
    done
}

#----- Vault PVC cleanup (orphaned after vault namespace deletion) ---------------
# Vault Raft pods each claim a PVC backed by an EBS volume. The namespace
# deletion in phase_k8s_cleanup should cascade-delete the PVCs, but if
# termination hangs (finalizer stuck) the PVC objects remain. This sweep
# force-deletes them so EBS volumes are released for sweep_ebs_volumes.
sweep_vault_pvcs() {
    # Namespace may already be gone — best-effort only
    if ! kubectl get namespace vault &>/dev/null 2>&1; then
        print_info "Vault namespace gone — PVCs already removed"; return 0
    fi
    local pvcs
    pvcs=$(kubectl get pvc -n vault --no-headers 2>/dev/null | awk '{print $1}')
    if [[ -z "$pvcs" ]]; then
        print_info "Vault PVCs: none"; return 0
    fi
    for pvc in $pvcs; do
        echo -n "    Deleting Vault PVC $pvc... "
        kubectl delete pvc "$pvc" -n vault --ignore-not-found=true --timeout=30s &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
    done
    # Force-remove finalizers on any stuck PVCs
    for pvc in $(kubectl get pvc -n vault --no-headers 2>/dev/null | awk '{print $1}'); do
        kubectl patch pvc "$pvc" -n vault -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
    done
}

#----- KMS (workshop-tagged keys + their aliases) ------------------------------
# NOTE (Pitfall 7): AWS requires a minimum 7-day pending-deletion window for
# customer-managed KMS keys. You CANNOT immediately delete a CMK. Schedule it
# and wait. The alias/vault-unseal key is a dedicated key (not the workshop CMK)
# created by the vault module — it must be captured here explicitly.
sweep_kms() {
    # Aliases first: eks/<cluster> + workshop-data + vault-unseal + any with workshop/agentic in name
    local aliases
    aliases=$(aws kms list-aliases --region "$REGION" \
        --query "Aliases[?contains(AliasName,'workshop') || contains(AliasName,'agentic') || AliasName=='alias/eks/${DEFAULT_CLUSTER}' || AliasName=='alias/vault-unseal'].AliasName" \
        --output text 2>/dev/null)
    for a in $aliases; do
        [[ -z "$a" || "$a" == "None" ]] && continue
        echo -n "    Deleting KMS alias $a... "
        aws kms delete-alias --alias-name "$a" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
    done
    # Keys by tag — schedule deletion (7-day window minimum)
    for k in $(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null); do
        local state
        state=$(aws kms describe-key --region "$REGION" --key-id "$k" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
        [[ "$state" == "PendingDeletion" ]] && continue
        local tag
        tag=$(aws kms list-resource-tags --region "$REGION" --key-id "$k" \
            --query "Tags[?TagKey=='${WORKSHOP_TAG_KEY}' && TagValue=='${WORKSHOP_TAG_VAL}'].TagValue" \
            --output text 2>/dev/null)
        if [[ -n "$tag" && "$tag" != "None" ]]; then
            echo -n "    Scheduling KMS key $k for deletion (7-day)... "
            aws kms schedule-key-deletion --region "$REGION" --key-id "$k" --pending-window-in-days 7 &>/dev/null \
                && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
        fi
    done
}

#----- CloudFormation stacks (bedrock_kb_index uses CFN for AOSS index) --------
# bedrock_kb_index/index.tf creates an aws_cloudformation_stack named
# `workshop-kb-aoss-index` to provision the AOSS::Index resource. Other modules
# may also leave behind CFN stacks tagged with the workshop tag.
# Retry on DELETE_FAILED with --retain-resources for the stuck KnowledgeBaseIndex
# (failure mode: AOSS collection already deleted, CFN's DeleteIndex returns 403).
sweep_cfn_stacks() {
    local stacks
    stacks=$(aws cloudformation list-stacks --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE CREATE_IN_PROGRESS \
            UPDATE_IN_PROGRESS DELETE_FAILED ROLLBACK_COMPLETE \
        --query "StackSummaries[?contains(StackName,'workshop')||contains(StackName,'agentic-runtime')||starts_with(StackName,'${DEFAULT_CLUSTER}')].StackName" \
        --output text 2>/dev/null)
    if [[ -z "$stacks" || "$stacks" == "None" ]]; then
        print_info "CFN stacks: none"; return 0
    fi
    for s in $stacks; do
        echo -n "    Deleting CFN stack $s... "
        aws cloudformation delete-stack --region "$REGION" --stack-name "$s" &>/dev/null
        echo -e "${GREEN}initiated${NC}"
    done
    # Wait for deletion, retry stuck stacks with --retain-resources
    for s in $stacks; do
        echo -n "    Waiting for $s to delete"
        local waited=0 status
        while [[ $waited -lt 300 ]]; do
            status=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$s" \
                --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
            if [[ -z "$status" || "$status" == "None" ]]; then
                echo -e " ${GREEN}done${NC}"; break
            fi
            if [[ "$status" == "DELETE_FAILED" ]]; then
                # Retry with --retain-resources for any failed resources
                local retain
                retain=$(aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$s" \
                    --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null)
                if [[ -n "$retain" ]]; then
                    echo -e " ${YELLOW}DELETE_FAILED — retrying with --retain-resources $retain${NC}"
                    # shellcheck disable=SC2086
                    aws cloudformation delete-stack --region "$REGION" --stack-name "$s" \
                        --retain-resources $retain &>/dev/null
                    sleep 5
                    continue
                fi
                echo -e " ${RED}DELETE_FAILED (no retain candidates)${NC}"
                break
            fi
            sleep 10; waited=$((waited + 10)); echo -n "."
        done
        [[ $waited -ge 300 ]] && echo -e " ${YELLOW}timeout${NC}"
    done
}

#----- IAM customer-managed policies (workshop-tagged) -------------------------
# Modules + the eks-pod-identity submodule create policies like
# AmazonEKS_VPC_CNI-*, AmazonEKS_EBS_CSI-*, alb-controller-*, cert-manager-*,
# agentic-runtime-usw2-cluster-*. They survive role deletion. Sweep by Workshop
# tag so we don't touch sister-workshop policies. Detach from any remaining
# roles before delete.
sweep_iam_workshop_policies() {
    local matched=""
    for arn in $(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text 2>/dev/null); do
        local tag
        tag=$(aws iam list-policy-tags --policy-arn "$arn" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && matched="$matched $arn"
    done
    if [[ -z "$matched" ]]; then
        print_info "IAM customer policies (Workshop tag): none"; return 0
    fi
    for arn in $matched; do
        local name="${arn##*/}"
        echo -n "    Deleting IAM policy $name... "
        # Detach from any roles still using it
        for role in $(aws iam list-entities-for-policy --policy-arn "$arn" \
                --query 'PolicyRoles[].RoleName' --output text 2>/dev/null); do
            [[ -z "$role" || "$role" == "None" ]] && continue
            aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" &>/dev/null
        done
        # Detach from groups + users (defensive)
        for grp in $(aws iam list-entities-for-policy --policy-arn "$arn" \
                --query 'PolicyGroups[].GroupName' --output text 2>/dev/null); do
            [[ -z "$grp" || "$grp" == "None" ]] && continue
            aws iam detach-group-policy --group-name "$grp" --policy-arn "$arn" &>/dev/null
        done
        for u in $(aws iam list-entities-for-policy --policy-arn "$arn" \
                --query 'PolicyUsers[].UserName' --output text 2>/dev/null); do
            [[ -z "$u" || "$u" == "None" ]] && continue
            aws iam detach-user-policy --user-name "$u" --policy-arn "$arn" &>/dev/null
        done
        # Delete non-default versions before delete-policy
        for v in $(aws iam list-policy-versions --policy-arn "$arn" \
                --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
            [[ -z "$v" || "$v" == "None" ]] && continue
            aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" &>/dev/null
        done
        if aws iam delete-policy --policy-arn "$arn" &>/dev/null; then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    done
}

#----- IAM roles (workshop-tagged) ---------------------------------------------
sweep_iam_roles() {
    local matched=""
    for r in $(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null); do
        local tag
        tag=$(aws iam list-role-tags --role-name "$r" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && matched="$matched $r"
    done
    if [[ -z "$matched" ]]; then
        print_info "IAM roles (Workshop tag): none"; return 0
    fi
    for r in $matched; do
        echo -n "    Deleting IAM role $r... "
        for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
            aws iam detach-role-policy --role-name "$r" --policy-arn "$p" &>/dev/null
        done
        for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
            aws iam delete-role-policy --role-name "$r" --policy-name "$p" &>/dev/null
        done
        for ip in $(aws iam list-instance-profiles-for-role --role-name "$r" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
            aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$r" &>/dev/null
        done
        aws iam delete-role --role-name "$r" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- Instance profiles (empty after role removal) ----------------------------
sweep_instance_profiles() {
    local matched=""
    for ip in $(aws iam list-instance-profiles \
            --query "InstanceProfiles[?length(Roles)==\`0\` && starts_with(InstanceProfileName,'${DEFAULT_CLUSTER}')].InstanceProfileName" \
            --output text 2>/dev/null); do
        [[ -z "$ip" || "$ip" == "None" ]] && continue
        matched="$matched $ip"
    done
    if [[ -z "$matched" ]]; then
        print_info "Instance profiles: none"; return 0
    fi
    for ip in $matched; do
        echo -n "    Deleting instance profile $ip... "
        aws iam delete-instance-profile --instance-profile-name "$ip" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

#----- VPC sweep (endpoints, ELBs, ENIs, SGs, NAT, IGW, subnets, RTs, VPC) -----
sweep_vpc_endpoints() {
    local vpc=$1
    local vpces
    vpces=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=${vpc}" \
        --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text 2>/dev/null)
    [[ -z "$vpces" || "$vpces" == "None" ]] && { print_info "VPC endpoints in $vpc: none"; return 0; }
    echo -n "    Deleting VPC endpoints in $vpc... "
    # shellcheck disable=SC2086
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $vpces &>/dev/null
    echo -e "${GREEN}initiated${NC}"
    echo -n "    Waiting for endpoint ENIs to release"
    local waited=0 rem
    while [[ $waited -lt 180 ]]; do
        rem=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=${vpc}" \
            --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" --output text 2>/dev/null)
        [[ -z "$rem" || "$rem" == "None" ]] && { echo -e " ${GREEN}done${NC}"; return 0; }
        sleep 10; waited=$((waited + 10)); echo -n "."
    done
    echo -e " ${YELLOW}timeout${NC}"
}

sweep_vpc_elbs() {
    local vpc=$1
    local arns
    arns=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerArn" --output text 2>/dev/null)
    for arn in $arns; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        echo -n "    Deleting ELBv2 $arn... "
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
    local classics
    classics=$(aws elb describe-load-balancers --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='${vpc}'].LoadBalancerName" --output text 2>/dev/null)
    for n in $classics; do
        [[ -z "$n" || "$n" == "None" ]] && continue
        echo -n "    Deleting classic ELB $n... "
        aws elb delete-load-balancer --load-balancer-name "$n" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

sweep_vpc_target_groups() {
    local vpc=$1
    local tgs
    tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?VpcId=='${vpc}' && length(LoadBalancerArns)==\`0\`].TargetGroupArn" \
        --output text 2>/dev/null)
    [[ -z "$tgs" || "$tgs" == "None" ]] && { print_info "Target groups in $vpc: none"; return 0; }
    for arn in $tgs; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local name="${arn##*/}"
        echo -n "    Deleting target group $name... "
        aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

# Sweep ALB-Controller-orphaned target groups regardless of VPC association.
# `sweep_vpc_target_groups` only catches TGs still pointing at a live VPC; once
# the VPC is deleted, TGs that lost their VPC reference are skipped by the
# per-VPC loop. This catches workshop-named TGs anywhere in the account.
sweep_orphan_target_groups() {
    local tgs
    tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?length(LoadBalancerArns)==\`0\` && (starts_with(TargetGroupName,'k8s-bankinga-') || starts_with(TargetGroupName,'k8s-verifyac-') || starts_with(TargetGroupName,'k8s-banking') || starts_with(TargetGroupName,'k8s-verify'))].TargetGroupArn" \
        --output text 2>/dev/null)
    if [[ -z "$tgs" || "$tgs" == "None" ]]; then
        print_info "Orphan target groups (workshop-named): none"
        return 0
    fi
    for arn in $tgs; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local name="${arn##*/}"
        echo -n "    Deleting orphan target group $name... "
        aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done
}

# Sweep the self-signed ALB-wildcard cert imported into ACM. tls_self_signed_cert
# .workshop_tls (root main.tf) is imported as the *.<region>.elb.amazonaws.com
# cert backing the banking-ui / ivia-wrp ALB HTTPS:443 listeners. ACM is NOT
# VPC-scoped, so the VPC teardown never touches it and it lingers after destroy
# (confirmed gap). Delete any workshop-TAGGED cert matching that domain; a cert
# still InUseBy a live LB cannot be deleted and is skipped (ALBs are gone by the
# time this runs). We require the Workshop tag so we never nuke an unrelated
# wildcard cert that happens to share the regional ELB domain.
sweep_acm_certs() {
    local certs
    certs=$(aws acm list-certificates --region "$REGION" \
        --query "CertificateSummaryList[?DomainName=='*.${REGION}.elb.amazonaws.com'].CertificateArn" \
        --output text 2>/dev/null)
    if [[ -z "$certs" || "$certs" == "None" ]]; then
        print_info "ACM certs (workshop ALB wildcard): none"
        return 0
    fi
    for arn in $certs; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local tagged
        tagged=$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        if [[ -z "$tagged" || "$tagged" == "None" ]]; then
            print_info "ACM cert ${arn##*/} not workshop-tagged — skipping"
            continue
        fi
        echo -n "    Deleting ACM cert ${arn##*/}... "
        aws acm delete-certificate --certificate-arn "$arn" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed (still in use?)${NC}"
    done
}

sweep_vpc_enis() {
    local vpc=$1
    local in_use waited=0
    in_use=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=in-use" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
    if [[ "$in_use" -gt 0 ]]; then
        echo -n "    Waiting for $in_use in-use ENIs in $vpc"
        while [[ $waited -lt 300 ]]; do
            in_use=$(aws ec2 describe-network-interfaces --region "$REGION" \
                --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=in-use" \
                --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
            [[ "$in_use" -eq 0 ]] && { echo -e " ${GREEN}released${NC}"; break; }
            sleep 10; waited=$((waited + 10)); echo -n "."
        done
        [[ "$in_use" -gt 0 ]] && echo -e " ${YELLOW}timeout ($in_use still in-use)${NC}"
    fi
    local available
    available=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)
    for eni in $available; do
        [[ -z "$eni" || "$eni" == "None" ]] && continue
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" &>/dev/null
    done
}

sweep_vpc_security_groups() {
    local vpc=$1
    local sgs
    sgs=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=${vpc}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)
    [[ -z "$sgs" || "$sgs" == "None" ]] && { print_info "SGs in $vpc: only default"; return 0; }
    # Strip rules first to break circular deps
    for sg in $sgs; do
        for rid in $(aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$sg" \
                --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null); do
            [[ -z "$rid" || "$rid" == "None" ]] && continue
            aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$REGION" --security-group-rule-ids "$rid" &>/dev/null
        done
        for rid in $(aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$sg" \
                --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null); do
            [[ -z "$rid" || "$rid" == "None" ]] && continue
            aws ec2 revoke-security-group-egress --group-id "$sg" --region "$REGION" --security-group-rule-ids "$rid" &>/dev/null
        done
    done
    for sg in $sgs; do
        echo -n "    Deleting SG $sg... "
        aws ec2 delete-security-group --group-id "$sg" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}deferred (deps)${NC}"
    done
}

sweep_vpc_resources() {
    local vpc=$1

    # NAT GWs
    # shellcheck disable=SC2016
    for nat in $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=${vpc}" \
            --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null); do
        [[ -z "$nat" || "$nat" == "None" ]] && continue
        echo -n "    Deleting NAT GW $nat... "
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}initiated${NC}"
    done
    echo -n "    Waiting for NAT GWs to delete"
    local waited=0
    while [[ $waited -lt 120 ]]; do
        # shellcheck disable=SC2016
        local rem
        rem=$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=${vpc}" \
            --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null)
        [[ -z "$rem" || "$rem" == "None" ]] && { echo -e " ${GREEN}done${NC}"; break; }
        sleep 10; waited=$((waited + 10)); echo -n "."
    done

    # EIPs (unassociated)
    for alloc in $(aws ec2 describe-addresses --region "$REGION" --filters "Name=domain,Values=vpc" \
            --query "Addresses[?NetworkInterfaceId==null || NetworkInterfaceId==''].AllocationId" --output text 2>/dev/null); do
        [[ -z "$alloc" || "$alloc" == "None" ]] && continue
        aws ec2 release-address --allocation-id "$alloc" --region "$REGION" &>/dev/null \
            && print_success "Released EIP $alloc"
    done

    # IGW
    for igw in $(aws ec2 describe-internet-gateways --region "$REGION" \
            --filters "Name=attachment.vpc-id,Values=${vpc}" \
            --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
        [[ -z "$igw" || "$igw" == "None" ]] && continue
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" &>/dev/null
        echo -n "    Deleting IGW $igw... "
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done

    # Subnets
    for s in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${vpc}" \
            --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
        [[ -z "$s" || "$s" == "None" ]] && continue
        echo -n "    Deleting subnet $s... "
        aws ec2 delete-subnet --subnet-id "$s" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done

    # Route tables (non-main)
    for rt in $(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=${vpc}" \
            --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
        [[ -z "$rt" || "$rt" == "None" ]] && continue
        echo -n "    Deleting RT $rt... "
        aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" &>/dev/null \
            && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
    done

    # VPC itself
    echo -n "    Deleting VPC $vpc... "
    aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" &>/dev/null \
        && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed (residual deps?)${NC}"
}

#----- AWS sweep orchestrator --------------------------------------------------
phase_aws_sweep() {
    phase_header "AWS Resource Sweep (tag: ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VAL})"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would sweep: EKS (addons, pod-identity, node groups, cluster),"
        print_info "  Vault PVCs (Raft StatefulSet), EBS volumes, launch templates,"
        print_info "  ECR repos (workshop/uc1-agent, workshop/uc3-agent, workshop-banking-app),"
        print_info "  RDS, Secrets Manager, Bedrock KB, AOSS,"
        print_info "  CW subscription filters, Firehose delivery streams,"
        print_info "  S3 (incl. ${DEFAULT_CLUSTER}-workshop-logs), Glue/Athena,"
        print_info "  CW logs, KMS (alias/vault-unseal + workshop keys),"
        print_info "  CFN, IAM (policies, roles, instance profiles),"
        print_info "  VPC (ELBs, target groups, endpoints, ENIs, SGs, NAT, IGW, subnets, RTs)"
        return 0
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured"; exit 1
    fi
    print_info "AWS account: $(aws sts get-caller-identity --query Account --output text)"
    print_info "Region:      $REGION"

    step_header "EKS pod-identity associations"
    sweep_eks_pod_identity || true

    step_header "EKS managed addons"
    sweep_eks_addons || true

    step_header "EKS node groups"
    sweep_eks_nodegroups || true

    step_header "EKS cluster"
    sweep_eks_cluster || true

    step_header "Vault PVCs (orphaned from Raft StatefulSet)"
    sweep_vault_pvcs || true

    step_header "EBS volumes (orphaned from PVCs)"
    sweep_ebs_volumes || true

    step_header "Launch templates (orphaned from node groups)"
    sweep_launch_templates || true

    step_header "ECR repositories (workshop container images)"
    sweep_ecr_repos || true

    step_header "RDS (instance + subnet + param + monitoring role)"
    sweep_rds || true

    step_header "Secrets Manager (RDS managed password)"
    sweep_secrets_manager || true

    # KB resources live in KB_REGION (us-east-1). Temporarily swap REGION
    # so the sweep functions hit the right region.
    local SAVED_REGION="$REGION"
    if [[ "$KB_REGION" != "$REGION" ]]; then
        print_info "KB region: $KB_REGION (different from primary $REGION)"
        REGION="$KB_REGION"
    fi

    step_header "Bedrock Knowledge Base + data sources (${REGION})"
    sweep_bedrock_kb || true

    step_header "AOSS (collection + 3 policies) (${REGION})"
    sweep_aoss || true

    # Subscription filters + Firehose must be deleted before S3 and log groups.
    # Run in primary region (observability is not in KB_REGION).
    local _cur_region="$REGION"
    REGION="$SAVED_REGION"

    step_header "CloudWatch subscription filters (before log group deletion)"
    sweep_cw_subscription_filters || true

    step_header "Kinesis Firehose delivery streams (${DEFAULT_CLUSTER}-*)"
    sweep_firehose_streams || true

    REGION="$_cur_region"

    step_header "S3 buckets (workshop-named, both regions)"
    sweep_s3_buckets || true
    if [[ "$KB_REGION" != "$SAVED_REGION" ]]; then
        REGION="$SAVED_REGION"
        sweep_s3_buckets || true
    fi

    step_header "CloudFormation stacks — KB region (${KB_REGION})"
    REGION="$KB_REGION"
    sweep_cfn_stacks || true

    step_header "KMS — KB region (${KB_REGION})"
    sweep_kms || true

    REGION="$SAVED_REGION"

    step_header "Glue catalog DB + Athena workgroup"
    sweep_glue_athena || true

    step_header "EKS cluster IAM OIDC provider"
    sweep_eks_oidc_provider || true

    step_header "CloudWatch log groups"
    sweep_cw_log_groups || true

    step_header "KMS aliases + workshop-tagged keys (7-day deletion window)"
    sweep_kms || true

    step_header "CloudFormation stacks (workshop-named)"
    sweep_cfn_stacks || true

    step_header "IAM customer-managed policies tagged Workshop"
    sweep_iam_workshop_policies || true

    step_header "IAM roles tagged Workshop"
    sweep_iam_roles || true

    step_header "Instance profiles (empty after role removal)"
    sweep_instance_profiles || true

    # Per-VPC sweeps — find all VPCs tagged or named for the workshop
    local vpcs
    vpcs=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null)
    if [[ -z "$vpcs" || "$vpcs" == "None" ]]; then
        vpcs=$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=tag:Name,Values=${DEFAULT_CLUSTER}*" \
            --query 'Vpcs[].VpcId' --output text 2>/dev/null)
    fi
    if [[ -z "$vpcs" || "$vpcs" == "None" ]]; then
        print_info "No workshop VPCs found"
    else
        for vpc in $vpcs; do
            step_header "VPC $vpc"
            sweep_vpc_elbs            "$vpc" || true
            sweep_vpc_target_groups   "$vpc" || true
            sweep_vpc_endpoints       "$vpc" || true
            sweep_vpc_enis            "$vpc" || true
            sweep_vpc_security_groups "$vpc" || true
            sweep_vpc_resources       "$vpc" || true
        done
    fi

    # Orphan target groups (TGs that lost their VPC reference and so are
    # skipped by the per-VPC loop above).
    step_header "Orphan target groups (workshop-named, no VPC)"
    sweep_orphan_target_groups || true

    # ACM cert is not VPC-scoped — sweep it independently of the VPC loop.
    step_header "ACM cert (self-signed ALB wildcard)"
    sweep_acm_certs || true

    print_success "AWS sweep complete"
}


#===============================================================================
# VERIFICATION — read-only audit to confirm zero residuals
#===============================================================================
phase_verify_zero_residuals() {
    phase_header "Post-Teardown Verification (zero-residual audit)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run post-teardown verification audit"
        return 0
    fi

    local failures=0

    _check() {
        local label=$1 result=$2
        if [[ -z "$result" || "$result" == "None" || "$result" == "0" ]]; then
            echo -e "    ${GREEN}PASS${NC}  $label"
        else
            echo -e "    ${RED}FAIL${NC}  $label: $result"
            failures=$((failures + 1))
        fi
    }

    # EKS cluster
    local eks_cluster
    eks_cluster=$(aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'cluster.name' --output text 2>/dev/null || true)
    [[ "$eks_cluster" == "None" ]] && eks_cluster=""
    _check "EKS cluster" "$eks_cluster"

    # ACM cert (self-signed ALB wildcard, workshop-tagged)
    local acm=""
    for arn in $(aws acm list-certificates --region "$REGION" \
            --query "CertificateSummaryList[?DomainName=='*.${REGION}.elb.amazonaws.com'].CertificateArn" \
            --output text 2>/dev/null); do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local t
        t=$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$t" && "$t" != "None" ]] && acm="$acm ${arn##*/}"
    done
    _check "ACM certs (workshop ALB wildcard)" "$(echo "$acm" | xargs)"

    # RDS instances
    local rds
    rds=$(aws rds describe-db-instances --region "$REGION" \
        --query "DBInstances[?TagList[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}']].DBInstanceIdentifier" \
        --output text 2>/dev/null)
    [[ "$rds" == "None" ]] && rds=""
    _check "RDS instances (tagged)" "$rds"

    # RDS subnet groups
    local rds_sgs
    rds_sgs=$(aws rds describe-db-subnet-groups --region "$REGION" \
        --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'${DEFAULT_CLUSTER}')].DBSubnetGroupName" \
        --output text 2>/dev/null)
    [[ "$rds_sgs" == "None" ]] && rds_sgs=""
    _check "RDS subnet groups" "$rds_sgs"

    # AOSS collections (KB_REGION)
    local aoss
    aoss=$(aws opensearchserverless list-collections --region "$KB_REGION" \
        --query 'collectionSummaries[].name' --output text 2>/dev/null)
    [[ "$aoss" == "None" ]] && aoss=""
    _check "AOSS collections ($KB_REGION)" "$aoss"

    # Bedrock KBs (KB_REGION)
    local kbs
    kbs=$(aws bedrock-agent list-knowledge-bases --region "$KB_REGION" \
        --query 'knowledgeBaseSummaries[].name' --output text 2>/dev/null)
    [[ "$kbs" == "None" ]] && kbs=""
    _check "Bedrock knowledge bases ($KB_REGION)" "$kbs"

    # S3 buckets
    local s3=""
    for prefix in "${S3_BUCKET_PREFIXES[@]}"; do
        local b
        b=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'${prefix}')].Name" --output text 2>/dev/null)
        [[ -n "$b" && "$b" != "None" ]] && s3="$s3 $b"
    done
    _check "S3 buckets (workshop-named)" "$(echo "$s3" | xargs)"

    # CloudWatch log groups
    local cw=""
    for prefix in "${CW_LOG_PREFIXES[@]}"; do
        local g
        g=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$prefix" \
            --query 'logGroups[].logGroupName' --output text 2>/dev/null)
        [[ -n "$g" && "$g" != "None" ]] && cw="$cw $g"
    done
    _check "CloudWatch log groups" "$(echo "$cw" | xargs)"

    # KMS keys (Workshop-tagged, not PendingDeletion)
    local kms_active=""
    for k in $(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null); do
        local state
        state=$(aws kms describe-key --region "$REGION" --key-id "$k" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
        [[ "$state" == "PendingDeletion" ]] && continue
        local tag
        tag=$(aws kms list-resource-tags --region "$REGION" --key-id "$k" \
            --query "Tags[?TagKey=='${WORKSHOP_TAG_KEY}' && TagValue=='${WORKSHOP_TAG_VAL}'].TagValue" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && kms_active="$kms_active $k"
    done
    _check "KMS keys (active, tagged)" "$(echo "$kms_active" | xargs)"

    # IAM roles (tagged)
    local iam_roles=""
    for r in $(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null); do
        local tag
        tag=$(aws iam list-role-tags --role-name "$r" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && iam_roles="$iam_roles $r"
    done
    _check "IAM roles (tagged)" "$(echo "$iam_roles" | xargs)"

    # IAM policies (tagged)
    local iam_pols=""
    for arn in $(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text 2>/dev/null); do
        local tag
        tag=$(aws iam list-policy-tags --policy-arn "$arn" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && iam_pols="$iam_pols ${arn##*/}"
    done
    _check "IAM policies (tagged)" "$(echo "$iam_pols" | xargs)"

    # Instance profiles (empty, cluster-named)
    local ips
    ips=$(aws iam list-instance-profiles \
        --query "InstanceProfiles[?length(Roles)==\`0\` && starts_with(InstanceProfileName,'${DEFAULT_CLUSTER}')].InstanceProfileName" \
        --output text 2>/dev/null)
    [[ "$ips" == "None" ]] && ips=""
    _check "Instance profiles (empty)" "$ips"

    # EBS volumes
    local ebs
    ebs=$(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null)
    [[ "$ebs" == "None" ]] && ebs=""
    if [[ -z "$ebs" ]]; then
        ebs=$(aws ec2 describe-volumes --region "$REGION" \
            --filters "Name=tag:kubernetes.io/cluster/${DEFAULT_CLUSTER},Values=owned" \
            --query 'Volumes[].VolumeId' --output text 2>/dev/null)
        [[ "$ebs" == "None" ]] && ebs=""
    fi
    _check "EBS volumes" "$ebs"

    # Launch templates
    local lts
    lts=$(aws ec2 describe-launch-templates --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null)
    [[ "$lts" == "None" ]] && lts=""
    _check "Launch templates (tagged)" "$lts"

    # Orphan target groups (workshop-named, regardless of VPC)
    local orphan_tgs
    orphan_tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?length(LoadBalancerArns)==\`0\` && (starts_with(TargetGroupName,'k8s-bankinga-') || starts_with(TargetGroupName,'k8s-verifyac-') || starts_with(TargetGroupName,'k8s-banking') || starts_with(TargetGroupName,'k8s-verify'))].TargetGroupName" \
        --output text 2>/dev/null)
    [[ "$orphan_tgs" == "None" ]] && orphan_tgs=""
    _check "Target groups (orphan, workshop-named)" "$orphan_tgs"

    # ECR repositories
    local ecr_residual=""
    for repo in "${ECR_REPO_NAMES[@]}"; do
        aws ecr describe-repositories --repository-names "$repo" --region "$REGION" &>/dev/null \
            && ecr_residual="$ecr_residual $repo"
    done
    _check "ECR repositories" "$(echo "$ecr_residual" | xargs)"

    # Firehose delivery streams
    local firehose=""
    for s in $(aws firehose list-delivery-streams --region "$REGION" --delivery-stream-type DirectPut \
            --query 'DeliveryStreamNames[]' --output text 2>/dev/null); do
        [[ "$s" == "${DEFAULT_CLUSTER}-"* ]] && firehose="$firehose $s"
    done
    _check "Firehose streams (cluster-named)" "$(echo "$firehose" | xargs)"

    # Secrets Manager
    local secrets
    secrets=$(aws secretsmanager list-secrets --region "$REGION" \
        --filters Key=tag-key,Values="${WORKSHOP_TAG_KEY}" Key=tag-value,Values="${WORKSHOP_TAG_VAL}" \
        --query 'SecretList[].Name' --output text 2>/dev/null)
    [[ "$secrets" == "None" ]] && secrets=""
    _check "Secrets Manager (tagged)" "$secrets"

    # VPCs
    local vpcs
    vpcs=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null)
    [[ "$vpcs" == "None" ]] && vpcs=""
    _check "VPCs (tagged)" "$vpcs"

    # CFN stacks
    local cfn
    cfn=$(aws cloudformation list-stacks --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE \
        --query "StackSummaries[?contains(StackName,'workshop')||contains(StackName,'agentic-runtime')||starts_with(StackName,'${DEFAULT_CLUSTER}')].StackName" \
        --output text 2>/dev/null)
    [[ "$cfn" == "None" ]] && cfn=""
    _check "CFN stacks (workshop-named)" "$cfn"

    # Glue DBs
    local glue=""
    for db in "${GLUE_DB_NAMES[@]}"; do
        aws glue get-database --name "$db" --region "$REGION" &>/dev/null && glue="$glue $db"
    done
    _check "Glue databases" "$(echo "$glue" | xargs)"

    # Athena workgroups
    local athena=""
    for wg in "${ATHENA_WG_NAMES[@]}"; do
        aws athena get-work-group --work-group "$wg" --region "$REGION" &>/dev/null && athena="$athena $wg"
    done
    _check "Athena workgroups" "$(echo "$athena" | xargs)"

    # EKS OIDC providers
    local oidc=""
    for arn in $(aws iam list-open-id-connect-providers \
            --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null); do
        [[ "$arn" == *"oidc.eks.${REGION}.amazonaws.com/id/"* ]] && oidc="$oidc $arn"
    done
    _check "EKS OIDC providers" "$(echo "$oidc" | xargs)"

    # Load balancers (ALB/NLB) — AWS Load Balancer Controller names them k8s-*.
    # The controller's own resources are NOT workshop-tagged, so target the name
    # prefix instead. Caught after PR #6 cleanup audit gap review (2026-06-08).
    local albs
    albs=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-')].LoadBalancerName" \
        --output text 2>/dev/null)
    [[ "$albs" == "None" ]] && albs=""
    _check "Load balancers (ALB/NLB, k8s-named)" "$albs"

    # Orphan ENIs — #1 cause of stuck VPC delete. ALB Controller leaves ENIs with
    # description "ELB app/k8s-..." and VPC CNI leaves "aws-K8S-i-..." after pod
    # cleanup races. Filter on status=available to catch only the orphans.
    local enis
    enis=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=status,Values=available" \
        --query "NetworkInterfaces[?starts_with(Description,'ELB app/k8s-') || starts_with(Description,'aws-K8S-')].NetworkInterfaceId" \
        --output text 2>/dev/null)
    [[ "$enis" == "None" ]] && enis=""
    _check "Orphan ENIs (ALB/CNI residuals)" "$enis"

    # Security groups — both workshop-tagged (Terraform-created) and ALB-Controller-
    # created k8s-* named (controller does NOT propagate our Workshop tag).
    local sgs=""
    local sgs_tagged
    sgs_tagged=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)
    [[ -n "$sgs_tagged" && "$sgs_tagged" != "None" ]] && sgs="$sgs $sgs_tagged"
    local sgs_k8s
    sgs_k8s=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=k8s-*" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)
    [[ -n "$sgs_k8s" && "$sgs_k8s" != "None" ]] && sgs="$sgs $sgs_k8s"
    _check "Security groups (tagged + k8s-named)" "$(echo "$sgs" | xargs)"

    # NAT gateways — workshop-tagged, active states only (deleted/failed/etc
    # are fine to skip; we only want operationally-still-billable ones).
    local nats
    nats=$(aws ec2 describe-nat-gateways --region "$REGION" \
        --filter "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" "Name=state,Values=available,pending" \
        --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
    [[ "$nats" == "None" ]] && nats=""
    _check "NAT gateways (tagged, active)" "$nats"

    # Elastic IPs — workshop-tagged. NAT-attached EIPs survive a botched NAT delete.
    local eips
    eips=$(aws ec2 describe-addresses --region "$REGION" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Addresses[].AllocationId' --output text 2>/dev/null)
    [[ "$eips" == "None" ]] && eips=""
    _check "Elastic IPs (tagged)" "$eips"

    # Bedrock data sources — child of KB. Defense-in-depth: if a KB list returns
    # empty but a DS somehow lingered (orphaned via API failure), surface it.
    local bds=""
    for kb in $(aws bedrock-agent list-knowledge-bases --region "$KB_REGION" \
            --query 'knowledgeBaseSummaries[].knowledgeBaseId' --output text 2>/dev/null); do
        [[ -z "$kb" || "$kb" == "None" ]] && continue
        local ds
        ds=$(aws bedrock-agent list-data-sources --knowledge-base-id "$kb" --region "$KB_REGION" \
            --query 'dataSourceSummaries[].name' --output text 2>/dev/null)
        [[ -n "$ds" && "$ds" != "None" ]] && bds="$bds $ds"
    done
    _check "Bedrock data sources (children of surviving KBs)" "$(echo "$bds" | xargs)"

    # KMS keys in PendingDeletion — INFO line, not a FAIL. These auto-purge in
    # 7-30 days. Surfacing them lets Bear see what's still on the books without
    # blocking the audit on a state that resolves on its own.
    local kms_pending=""
    for k in $(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null); do
        local state
        state=$(aws kms describe-key --region "$REGION" --key-id "$k" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
        [[ "$state" != "PendingDeletion" ]] && continue
        local tag
        tag=$(aws kms list-resource-tags --region "$REGION" --key-id "$k" \
            --query "Tags[?TagKey=='${WORKSHOP_TAG_KEY}' && TagValue=='${WORKSHOP_TAG_VAL}'].TagValue" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && kms_pending="$kms_pending $k"
    done
    if [[ -n "$kms_pending" ]]; then
        echo -e "    ${BLUE}INFO${NC}  KMS keys (PendingDeletion, auto-purge in 7-30d):$kms_pending"
    fi

    echo ""
    if [[ $failures -eq 0 ]]; then
        print_success "Verification PASSED — zero residuals detected"
        return 0
    else
        print_error "Verification FAILED — $failures resource type(s) still have residuals"
        return 1
    fi
}

#===============================================================================
# --keep-eks MODE — surgical teardown that preserves EKS cluster + VPC + addons
#
# Workshop attendees + dev iteration both benefit from a "wipe everything except
# the slow-to-build infra" mode: keep the EKS cluster, node group, VPC, subnets,
# and EKS add-ons (the bits that take 15-20 min to (re)build); destroy every
# other workshop resource (RDS, Bedrock KB, Vault, IVIA, ECR, S3, KMS, IAM,
# all in-cluster helm releases + PVCs).
#
# Strategy: targeted `terraform destroy` for every module EXCEPT module.eks /
# module.vpc / module.addons (and the time_sleep that gates them). Terraform's
# dependency graph then unwinds the rest in the correct order. AWS sweep is
# limited to orphan classes that terraform doesn't track (StatefulSet PVCs,
# orphan target groups from ALB churn) — the per-module IAM/KMS/S3/RDS cleanup
# is done by terraform itself, so we don't risk killing EKS-tied IAM/KMS.
#===============================================================================
_keep_eks_targets() {
    # Emit `-target=ADDR` lines for every state entry to destroy.
    # Preserves: module.eks (cluster + node group + IAM), module.vpc (VPC +
    # subnets + IGW + NAT), module.addons (vpc-cni, kube-proxy, coredns, EBS
    # CSI, LB controller), time_sleep.alb_webhook_ready (no-op preserved with
    # the LB controller install), and pure-data sources.
    terraform -chdir="$REPO_ROOT/infrastructure" state list 2>/dev/null | while IFS= read -r addr; do
        case "$addr" in
            module.eks|module.eks.*) continue ;;
            module.vpc|module.vpc.*) continue ;;
            module.addons|module.addons.*) continue ;;
            time_sleep.alb_webhook_ready) continue ;;
            data.*) continue ;;
            *) printf -- '-target=%s\n' "$addr" ;;
        esac
    done
}

phase_aws_sweep_keep_eks() {
    phase_header "AWS Orphan Sweep (PVCs + EBS + orphan TGs — EKS/VPC preserved)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would sweep: Vault PVCs, orphan EBS volumes, orphan target groups"
        return 0
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured"; exit 1
    fi

    # PVCs that aren't tracked by terraform (StatefulSet/Operator-managed).
    step_header "Vault PVCs (Raft StatefulSet — Helm leaves these behind)"
    sweep_vault_pvcs || true

    # EBS volumes orphaned from any PVC the StatefulSet sweep just released.
    step_header "EBS volumes (orphaned from PVCs)"
    sweep_ebs_volumes || true

    # Orphan target groups from ALB churn (LBC v2.7.x doesn't GC the old TG on
    # group.name change — same issue handled in workshop-e2e's TGB sweep).
    step_header "Orphan target groups (workshop-named, no VPC binding)"
    sweep_orphan_target_groups || true

    print_success "Orphan sweep complete"
}

phase_verify_keep_eks() {
    phase_header "Post-Teardown Verification (--keep-eks zero-residual audit)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would run --keep-eks verification audit"
        return 0
    fi

    local failures=0

    _check() {
        local label=$1 result=$2
        if [[ -z "$result" || "$result" == "None" || "$result" == "0" ]]; then
            echo -e "    ${GREEN}PASS${NC}  $label"
        else
            echo -e "    ${RED}FAIL${NC}  $label: $result"
            failures=$((failures + 1))
        fi
    }

    # Positive check — EKS cluster must STILL be active (we preserved it).
    local eks_status
    eks_status=$(aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" \
        --query 'cluster.status' --output text 2>/dev/null || true)
    if [[ "$eks_status" == "ACTIVE" ]]; then
        echo -e "    ${GREEN}PASS${NC}  EKS cluster $DEFAULT_CLUSTER preserved (ACTIVE)"
    else
        echo -e "    ${RED}FAIL${NC}  EKS cluster $DEFAULT_CLUSTER status: ${eks_status:-MISSING}"
        failures=$((failures + 1))
    fi

    # RDS instance(s)
    local rds
    rds=$(aws rds describe-db-instances --region "$REGION" \
        --query "DBInstances[?TagList[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}']].DBInstanceIdentifier" \
        --output text 2>/dev/null)
    [[ "$rds" == "None" ]] && rds=""
    _check "RDS instances (tagged)" "$rds"

    # Bedrock KB
    local kbs
    kbs=$(aws bedrock-agent list-knowledge-bases --region "$KB_REGION" \
        --query 'knowledgeBaseSummaries[].name' --output text 2>/dev/null)
    [[ "$kbs" == "None" ]] && kbs=""
    _check "Bedrock knowledge bases ($KB_REGION)" "$kbs"

    # AOSS collections
    local aoss
    aoss=$(aws opensearchserverless list-collections --region "$KB_REGION" \
        --query 'collectionSummaries[].name' --output text 2>/dev/null)
    [[ "$aoss" == "None" ]] && aoss=""
    _check "AOSS collections ($KB_REGION)" "$aoss"

    # S3 buckets
    local s3=""
    for prefix in "${S3_BUCKET_PREFIXES[@]}"; do
        local b
        b=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'${prefix}')].Name" --output text 2>/dev/null)
        [[ -n "$b" && "$b" != "None" ]] && s3="$s3 $b"
    done
    _check "S3 buckets (workshop-named)" "$(echo "$s3" | xargs)"

    # ECR repos
    local ecr_residual=""
    for repo in "${ECR_REPO_NAMES[@]}"; do
        aws ecr describe-repositories --repository-names "$repo" --region "$REGION" &>/dev/null \
            && ecr_residual="$ecr_residual $repo"
    done
    _check "ECR repositories" "$(echo "$ecr_residual" | xargs)"

    # Workshop namespaces (in-cluster workloads — must be drained)
    local ns_residual=""
    for ns in vault verify-access banking-app uc1 uc3; do
        kubectl get namespace "$ns" &>/dev/null && ns_residual="$ns_residual $ns"
    done
    _check "Workshop namespaces (drained)" "$(echo "$ns_residual" | xargs)"

    # PVCs in workshop namespaces (StatefulSet leftovers)
    local pvc_residual=""
    for ns in vault verify-access banking-app uc1 uc3; do
        local p
        p=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | xargs)
        [[ -n "$p" ]] && pvc_residual="$pvc_residual ${ns}/${p}"
    done
    _check "Workshop PVCs (drained)" "$(echo "$pvc_residual" | xargs)"

    # KMS keys (active, tagged) — vault-unseal + KB KMS should be gone
    local kms_active=""
    for k in $(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null); do
        local state
        state=$(aws kms describe-key --region "$REGION" --key-id "$k" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
        [[ "$state" == "PendingDeletion" ]] && continue
        local tag
        tag=$(aws kms list-resource-tags --region "$REGION" --key-id "$k" \
            --query "Tags[?TagKey=='${WORKSHOP_TAG_KEY}' && TagValue=='${WORKSHOP_TAG_VAL}'].TagValue" \
            --output text 2>/dev/null)
        [[ -n "$tag" && "$tag" != "None" ]] && kms_active="$kms_active $k"
    done
    _check "KMS keys (active, tagged — Vault + KB)" "$(echo "$kms_active" | xargs)"

    # Orphan target groups
    local orphan_tgs
    orphan_tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?length(LoadBalancerArns)==\`0\` && (starts_with(TargetGroupName,'k8s-bankinga-') || starts_with(TargetGroupName,'k8s-verifyac-') || starts_with(TargetGroupName,'k8s-banking') || starts_with(TargetGroupName,'k8s-verify'))].TargetGroupName" \
        --output text 2>/dev/null)
    [[ "$orphan_tgs" == "None" ]] && orphan_tgs=""
    _check "Orphan target groups (workshop-named)" "$orphan_tgs"

    # ACM cert (self-signed wildcard) — gone, we kill it in targeted destroy
    local acm=""
    for arn in $(aws acm list-certificates --region "$REGION" \
            --query "CertificateSummaryList[?DomainName=='*.${REGION}.elb.amazonaws.com'].CertificateArn" \
            --output text 2>/dev/null); do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        local t
        t=$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        [[ -n "$t" && "$t" != "None" ]] && acm="$acm ${arn##*/}"
    done
    _check "ACM certs (workshop ALB wildcard)" "$(echo "$acm" | xargs)"

    echo ""
    if [[ $failures -eq 0 ]]; then
        print_success "Verification PASSED — EKS preserved, zero workshop residuals"
        return 0
    else
        print_error "Verification FAILED — $failures resource type(s) still have residuals"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Agentic Runtime Security Workshop -- Teardown${NC}"
echo -e "${BLUE}================================================================${NC}"
if [ "$DRY_RUN" = true ]; then print_warn "DRY RUN MODE — no changes will be made"; fi

if [ "$POST_DESTROY_ONLY" = true ]; then
    print_info "Mode: Post-destroy (full orphan sweep — all workshop resources)"
    phase_k8s_cleanup
    phase_aws_sweep
    phase_verify_zero_residuals || VERIFY_FAILED=true
elif [ "$AWS_ONLY" = true ]; then
    print_info "Mode: AWS-only (K8s drain + tag-scoped resource sweep)"
    phase_k8s_cleanup
    phase_aws_sweep
    phase_verify_zero_residuals || VERIFY_FAILED=true
elif [ "$KEEP_EKS" = true ]; then
    print_info "Mode: KEEP-EKS (preserves EKS cluster + node group + VPC + addons;"
    print_info "                wipes RDS, Vault, IVIA, Bedrock KB, S3, ECR, KMS, IAM, workloads)"

    # Sanity: EKS cluster must exist + be ACTIVE — otherwise --keep-eks is a no-op
    # and the targeted destroy fails. Fail fast with a clear message.
    if ! aws eks describe-cluster --name "$DEFAULT_CLUSTER" --region "$REGION" &>/dev/null; then
        print_error "EKS cluster $DEFAULT_CLUSTER not found — --keep-eks requires a live cluster to preserve."
        print_error "Either run a full nuke (drop --keep-eks) or deploy the foundation first."
        exit 1
    fi

    # Step 1: destroy the workload + service roots IN FULL via terraform while the
    # cluster is live, so Vault server / IVIA / banking app Helm + K8s resources
    # are cleanly uninstalled. tier-2/tier-3 carry NO EKS/VPC/addon state, so a
    # full destroy here never touches the infra we are preserving.
    step_header "Terraform destroy (tier 3 + tier 2 — workloads + services)..."
    _destroy_root "Tier 3 (workloads)" "$TIER3_DIR"
    _destroy_root "Tier 2 (services)"  "$TIER2_DIR"

    # Step 2: K8s drain any residual workshop namespaces so LB controller releases
    # ALBs before the tier-1 targeted destroy.
    phase_k8s_cleanup

    # Step 3: targeted terraform destroy of tier 1 — everything except EKS/VPC/addons
    step_header "Terraform destroy (tier 1 targeted — keep EKS + VPC + addons)..."
    infra_dir="$REPO_ROOT/infrastructure"
    if [ -f "$infra_dir/.terraform/terraform.tfstate" ] || [ -d "$infra_dir/.terraform" ]; then
        # Build a stable target list and pass it as one batch so terraform's
        # dependency graph resolves the destroy order in a single plan.
        mapfile -t TARGETS < <(_keep_eks_targets)
        if [ "${#TARGETS[@]}" -eq 0 ]; then
            print_info "No destroy targets — terraform state already aligned with --keep-eks (preserves match)"
        else
            print_info "Targeting ${#TARGETS[@]} state addresses (eks/vpc/addons preserved)"
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY-RUN] Would run: terraform destroy ${TARGETS[*]} -auto-approve"
            else
                terraform -chdir="$infra_dir" destroy "${TARGETS[@]}" -auto-approve \
                    || print_warn "terraform destroy had errors — falling back to sweep"
            fi
        fi
    else
        print_info "No terraform state — skipping terraform destroy"
    fi

    # Step 4: Minimal orphan sweep (PVCs, EBS volumes, orphan target groups)
    phase_aws_sweep_keep_eks

    # Step 5: Verify zero workshop residuals (EKS preserved)
    phase_verify_keep_eks || VERIFY_FAILED=true
else
    print_info "Mode: FULL (terraform destroy + AWS sweep)"

    # Primary destroy via Terraform — REVERSE dependency order across the three
    # roots so terraform uninstalls in-cluster Helm/K8s resources (Vault server,
    # IVIA, banking app) via the LIVE cluster API before the EKS control plane
    # and VPC are torn down by the tier-1 destroy.
    step_header "Terraform destroy (3 roots, reverse order: workloads → services → infra)..."
    _destroy_root "Tier 3 (workloads)" "$TIER3_DIR"
    _destroy_root "Tier 2 (services)"  "$TIER2_DIR"
    _destroy_root "Tier 1 (infrastructure)" "$TIER1_DIR"

    phase_k8s_cleanup
    phase_aws_sweep
    phase_verify_zero_residuals || VERIFY_FAILED=true
fi

echo ""

# Local-only state cleanup: Phase 07.8's `.acme-state` caches the FQDN
# tied to the destroyed ALB's IP. Leaving it on disk causes the next deploy's
# deploy-workshop.sh Step 4 to skip re-issuance and bake a stale FQDN.
acme_state="$REPO_ROOT/infrastructure/.acme-state"
acme_rerun="$REPO_ROOT/infrastructure/.acme-rerun-marker"
if [ "$DRY_RUN" = true ]; then
    [ -f "$acme_state" ] && print_info "[DRY-RUN] Would remove $acme_state"
    [ -f "$acme_rerun" ] && print_info "[DRY-RUN] Would remove $acme_rerun"
else
    rm -f "$acme_state" "$acme_rerun"
    print_info "Removed local Phase 07.8 ACME cache (.acme-state, .acme-rerun-marker)"
fi

phase_header "Teardown Complete"
if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN — no changes were made"
elif [ "${VERIFY_FAILED:-}" = true ]; then
    print_error "Teardown finished but verification found residuals — review output above"
    exit 1
else
    print_success "All targeted resources have been removed (KMS keys: 7-day deletion window)"
fi
echo ""
