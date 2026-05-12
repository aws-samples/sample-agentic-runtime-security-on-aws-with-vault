#!/usr/bin/env bash
#===============================================================================
# Workshop Teardown — Agentic Runtime Security on AWS
#
# Single-file teardown. Wipes EVERYTHING the workshop provisioned.
#
# Usage:
#   teardown.sh                Full nuke: AWS resources + HCP infra
#   teardown.sh --aws-only     Only AWS resources (K8s drain + tag-scoped sweep)
#   teardown.sh --hcp-only     Only HCP infra (Stack, varset, IAM role, OIDC)
#   teardown.sh --dry-run      Preview without executing
#   teardown.sh --help         Show this help
#
# Discovery: Workshop tag `Workshop=agentic-runtime-security` + the well-known
# names this workshop uses (cluster `agentic-runtime-usw2`, S3 buckets prefixed
# `workshop-kb-corpus`, Glue DB `workshop_logs`, Athena workgroup `workshop`,
# CW log groups `/workshop/*`, RDS instance `<cluster>-pg`).
#
# Default behavior is "skip the HCP destroy plan and just nuke." If the deploy
# already broke (orphans exist with HCP state diverged from AWS), there is no
# value in waiting for a destroy plan that will fail or no-op.
#===============================================================================

set -e
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

#-------------------------------------------------------------------------------
# Workshop constants
#-------------------------------------------------------------------------------
WORKSHOP_TAG_KEY="Workshop"
WORKSHOP_TAG_VAL="agentic-runtime-security"
HCP_ROLE_NAME="hcp-stacks-deploy"
HCP_STACK_NAME="agentic-runtime-security"
HCP_WORKSPACE_NAME="agentic-runtime-security"
HCP_PROJECT_NAME="Agentic Runtime Security"
HCP_VARSET_NAME="agentic-runtime-stacks-config"
TFE_API="https://app.terraform.io/api/v2"

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
HCP_ONLY=false

usage() {
    sed -n '2,21p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --aws-only) AWS_ONLY=true ;;
        --hcp-only) HCP_ONLY=true ;;
        --dry-run)  DRY_RUN=true ;;
        --help|-h)  usage ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            ;;
    esac
    shift
done

if [ "$AWS_ONLY" = true ] && [ "$HCP_ONLY" = true ]; then
    echo -e "${RED}Error: --aws-only and --hcp-only are mutually exclusive${NC}" >&2
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

# KB region — Nova 2 Multimodal Embeddings is us-east-1 only; KB components
# (AOSS, Bedrock KB, S3 corpus/multimodal, CFN index stack) live there.
KB_REGION="${KB_REGION:-us-east-1}"

# HCP organization — source-of-truth is the `hcp_org` terraform variable in
# infrastructure/scripts/hcp-setup/terraform.tfvars (written by bootstrap.sh
# from the operator's shell). Override with $HCP_ORG env var.
HCP_SETUP_TFVARS="${SCRIPT_DIR}/hcp-setup/terraform.tfvars"
HCP_ORG="${HCP_ORG:-}"
if [ -z "$HCP_ORG" ] && [ -f "$HCP_SETUP_TFVARS" ]; then
    HCP_ORG=$(grep -E '^\s*hcp_org\s*=\s*"' "$HCP_SETUP_TFVARS" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
# Don't fail-fast here — phase_hcp_cleanup may be skipped (--aws-only mode).
# Validation deferred to that phase.

#-------------------------------------------------------------------------------
# TFE token loader
#-------------------------------------------------------------------------------
load_tfe_token() {
    if [ -z "${TFE_TOKEN:-}" ] && [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
        TFE_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' \
            "$HOME/.terraform.d/credentials.tfrc.json" 2>/dev/null || true)
        export TFE_TOKEN
    fi
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

    # Delete workshop namespaces (vault, verify-access, uc1, etc.) so any LB
    # Services in them get torn down by the LB controller.
    for ns in vault verify-access uc1; do
        if kubectl get namespace "$ns" &>/dev/null; then
            print_info "Deleting namespace $ns..."
            kubectl delete namespace "$ns" --ignore-not-found --timeout=120s 2>/dev/null || true
        fi
    done

    # Force-delete any LBs still in the cluster's VPC.
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
            UPDATE_IN_PROGRESS DELETE_FAILED \
        --query "StackSummaries[?contains(StackName,'workshop')||contains(StackName,'agentic-runtime')].StackName" \
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
        # Skip the HCP role — that's handled by hcp-only path
        [[ "$r" == "$HCP_ROLE_NAME" ]] && continue
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
        print_info "  RDS, Secrets Manager, Bedrock KB, AOSS,"
        print_info "  S3, Glue/Athena, CW logs, KMS (alias/vault-unseal + workshop keys),"
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

    step_header "IAM roles tagged Workshop (excluding HCP role)"
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

    print_success "AWS sweep complete"
}

#===============================================================================
# HCP CLEANUP — delete Stack, variable set, AWS IAM role for HCP, OIDC provider
#===============================================================================
phase_hcp_cleanup() {
    phase_header "HCP Cleanup (Workspace + Stack + variable set + IAM role + OIDC)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would delete HCP Workspace '$HCP_WORKSPACE_NAME', Stack '$HCP_STACK_NAME',"
        print_info "          variable set, IAM role '$HCP_ROLE_NAME', OIDC provider 'app.terraform.io'"
        return 0
    fi

    load_tfe_token
    local hcp_setup_dir="$SCRIPT_DIR/hcp-setup"

    if [ -z "$HCP_ORG" ]; then
        print_error "Could not resolve HCP org from $HCP_SETUP_TFVARS or \$HCP_ORG."
        print_info "Run bootstrap.sh first to populate hcp-setup/terraform.tfvars."
        return 1
    fi
    print_info "HCP org: $HCP_ORG"

    #-- Workspace delete via API
    step_header "Delete HCP Terraform Workspace"
    if [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not set — skipping Workspace delete (manual: HCP UI > Workspaces)"
    else
        local ws_id
        ws_id=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/organizations/$HCP_ORG/workspaces/$HCP_WORKSPACE_NAME" 2>/dev/null \
            | jq -r '.data.id // empty')
        if [ -z "$ws_id" ]; then
            print_info "No HCP Workspace '$HCP_WORKSPACE_NAME' found in org '$HCP_ORG'"
        else
            print_info "Workspace id: $ws_id"
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/workspaces/$ws_id" 2>/dev/null)
            case "$code" in
                200|204|404) print_success "HCP Workspace deleted (HTTP $code)" ;;
                *)           print_warn "Workspace delete returned HTTP $code — check HCP UI" ;;
            esac
        fi
    fi

    #-- Stack delete via API
    step_header "Delete HCP Terraform Stack"
    if [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not set — skipping Stack delete (manual: HCP UI > Stack > Settings)"
    else
        local stack_id
        stack_id=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            "$TFE_API/organizations/$HCP_ORG/stacks" 2>/dev/null \
            | jq -r --arg n "$HCP_STACK_NAME" '.data[] | select(.attributes.name==$n) | .id' | head -1)
        if [ -z "$stack_id" ]; then
            print_info "No HCP Stack '$HCP_STACK_NAME' found in org '$HCP_ORG'"
        else
            print_info "Stack id: $stack_id"
            # Disconnect VCS to stop new runs, then cancel any active runs.
            curl -s -X PATCH -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                -d '{"data":{"type":"stacks","attributes":{"vcs-repo":null}}}' \
                "$TFE_API/stacks/$stack_id" >/dev/null 2>&1
            for cid in $(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
                    -H "Content-Type: application/vnd.api+json" \
                    "$TFE_API/stacks/$stack_id/stack-configurations?page%5Bsize%5D=20" 2>/dev/null \
                    | jq -r '.data[].id'); do
                curl -s -H "Authorization: Bearer $TFE_TOKEN" \
                    -H "Content-Type: application/vnd.api+json" \
                    "$TFE_API/stack-configurations/$cid/stack-deployment-runs" 2>/dev/null \
                    | jq -r '.data[] | select(.attributes.status != "abandoned" and .attributes.status != "failed" and .attributes.status != "succeeded") | .id' \
                    | while read -r rid; do
                        [ -n "$rid" ] && curl -s -X POST \
                            -H "Authorization: Bearer $TFE_TOKEN" \
                            -H "Content-Type: application/vnd.api+json" \
                            "$TFE_API/stack-deployment-runs/$rid/cancel" >/dev/null 2>&1
                    done
            done
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/stacks/$stack_id" 2>/dev/null)
            case "$code" in
                200|204|404) print_success "HCP Stack deleted (HTTP $code)" ;;
                *)           print_warn "Stack delete returned HTTP $code — check HCP UI" ;;
            esac
        fi
    fi

    #-- Variable set + project (terraform destroy in hcp-setup)
    step_header "Destroy variable set + project (terraform destroy in hcp-setup/)"
    if [ ! -f "$hcp_setup_dir/terraform.tfstate" ]; then
        print_info "No hcp-setup terraform state — skipping"
    elif [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not set — skipping"
    else
        if terraform -chdir="$hcp_setup_dir" destroy -auto-approve -input=false; then
            print_success "Variable set + project destroyed"
        else
            print_warn "terraform destroy in hcp-setup/ had errors — check HCP UI"
        fi
    fi

    #-- AWS IAM role for HCP (hcp-stacks-deploy)
    step_header "Delete AWS IAM role $HCP_ROLE_NAME"
    if aws iam get-role --role-name "$HCP_ROLE_NAME" &>/dev/null; then
        for p in $(aws iam list-attached-role-policies --role-name "$HCP_ROLE_NAME" \
                --query 'AttachedPolicies[].PolicyArn' --output text); do
            aws iam detach-role-policy --role-name "$HCP_ROLE_NAME" --policy-arn "$p" 2>/dev/null || true
        done
        for p in $(aws iam list-role-policies --role-name "$HCP_ROLE_NAME" \
                --query 'PolicyNames[]' --output text); do
            aws iam delete-role-policy --role-name "$HCP_ROLE_NAME" --policy-name "$p" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$HCP_ROLE_NAME" 2>/dev/null \
            && print_success "Deleted IAM role $HCP_ROLE_NAME" \
            || print_error "Could not delete $HCP_ROLE_NAME"
    else
        print_info "IAM role $HCP_ROLE_NAME not found"
    fi

    #-- AWS OIDC provider for app.terraform.io
    step_header "Delete AWS OIDC provider app.terraform.io"
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    local oidc_arn="arn:aws:iam::${account_id}:oidc-provider/app.terraform.io"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" &>/dev/null; then
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" 2>/dev/null \
            && print_success "Deleted OIDC provider" \
            || print_error "Could not delete OIDC provider"
    else
        print_info "OIDC provider not found"
    fi

    print_success "HCP cleanup complete"
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
        [[ "$r" == "$HCP_ROLE_NAME" ]] && continue
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
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
        --query "StackSummaries[?contains(StackName,'workshop')||contains(StackName,'agentic-runtime')].StackName" \
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
# MAIN
#===============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  Agentic Runtime Security Workshop -- Teardown${NC}"
echo -e "${BLUE}================================================================${NC}"
if [ "$DRY_RUN" = true ]; then print_warn "DRY RUN MODE — no changes will be made"; fi

if [ "$AWS_ONLY" = true ]; then
    print_info "Mode: AWS-only (K8s drain + tag-scoped resource sweep)"
    phase_k8s_cleanup
    phase_aws_sweep
    phase_verify_zero_residuals || VERIFY_FAILED=true
elif [ "$HCP_ONLY" = true ]; then
    print_info "Mode: HCP-only (Stack + varset + IAM role + OIDC)"
    phase_hcp_cleanup
else
    print_info "Mode: FULL (AWS resources + HCP infra)"
    phase_k8s_cleanup
    phase_aws_sweep
    phase_hcp_cleanup
    phase_verify_zero_residuals || VERIFY_FAILED=true
fi

echo ""
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
