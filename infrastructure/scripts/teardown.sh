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
HCP_PROJECT_NAME="Agentic Runtime Security"
HCP_VARSET_NAME="agentic-runtime-stacks-config"
TFE_API="https://app.terraform.io/api/v2"

# Default cluster — workshop is single-region single-cluster.
DEFAULT_CLUSTER="agentic-runtime-usw2"

# Known name-prefixes the workshop uses (for resources without tag visibility).
S3_BUCKET_PREFIXES=("workshop-kb-corpus" "workshop-athena-results")
GLUE_DB_NAMES=("workshop_logs")
ATHENA_WG_NAMES=("workshop")
CW_LOG_PREFIXES=("/workshop/" "/aws/eks/${DEFAULT_CLUSTER}/" "/aws/rds/instance/${DEFAULT_CLUSTER}-pg")

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
# Region resolution (canonical contract: only deployments.tfdeploy.hcl carries
# the literal "us-west-2" — everything else reads it from there or $AWS_REGION).
#-------------------------------------------------------------------------------
REGION="${AWS_REGION:-}"
if [ -z "$REGION" ]; then
    TF_DEPLOY="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
    if [ -f "$TF_DEPLOY" ]; then
        REGION=$(grep -E '^\s*region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
fi
if [ -z "$REGION" ]; then
    echo -e "${RED}Error: could not resolve region. Set AWS_REGION.${NC}" >&2
    exit 1
fi

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

    # Delete workshop namespaces (vault, verify-access, etc.) so any LB Services
    # in them get torn down by the LB controller.
    for ns in vault verify-access; do
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

#----- KMS (workshop-tagged keys + their aliases) ------------------------------
sweep_kms() {
    # Aliases first (eks/<cluster> + workshop-data + any with workshop in name)
    local aliases
    aliases=$(aws kms list-aliases --region "$REGION" \
        --query "Aliases[?contains(AliasName,'workshop') || contains(AliasName,'agentic') || AliasName=='alias/eks/${DEFAULT_CLUSTER}'].AliasName" \
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
        print_info "[DRY-RUN] Would sweep: EKS pod-identity, node groups, cluster, RDS,"
        print_info "  AOSS, S3, Bedrock KB, Glue/Athena, CW logs, KMS, IAM roles, VPC + deps"
        return 0
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured"; exit 1
    fi
    print_info "AWS account: $(aws sts get-caller-identity --query Account --output text)"
    print_info "Region:      $REGION"

    step_header "EKS pod-identity associations"
    sweep_eks_pod_identity || true

    step_header "EKS node groups"
    sweep_eks_nodegroups || true

    step_header "EKS cluster"
    sweep_eks_cluster || true

    step_header "RDS (instance + subnet + param + monitoring role)"
    sweep_rds || true

    step_header "Bedrock Knowledge Base + data sources"
    sweep_bedrock_kb || true

    step_header "AOSS (collection + 3 policies)"
    sweep_aoss || true

    step_header "S3 buckets (workshop-named)"
    sweep_s3_buckets || true

    step_header "Glue catalog DB + Athena workgroup"
    sweep_glue_athena || true

    step_header "EKS cluster IAM OIDC provider"
    sweep_eks_oidc_provider || true

    step_header "CloudWatch log groups"
    sweep_cw_log_groups || true

    step_header "KMS aliases + workshop-tagged keys (7-day deletion window)"
    sweep_kms || true

    step_header "IAM roles tagged Workshop (excluding HCP role)"
    sweep_iam_roles || true

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
            sweep_vpc_elbs           "$vpc" || true
            sweep_vpc_endpoints      "$vpc" || true
            sweep_vpc_enis           "$vpc" || true
            sweep_vpc_security_groups "$vpc" || true
            sweep_vpc_resources      "$vpc" || true
        done
    fi

    print_success "AWS sweep complete"
}

#===============================================================================
# HCP CLEANUP — delete Stack, variable set, AWS IAM role for HCP, OIDC provider
#===============================================================================
phase_hcp_cleanup() {
    phase_header "HCP Cleanup (Stack + variable set + IAM role + OIDC provider)"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would delete HCP Stack '$HCP_STACK_NAME', variable set,"
        print_info "          IAM role '$HCP_ROLE_NAME', OIDC provider 'app.terraform.io'"
        return 0
    fi

    load_tfe_token
    local hcp_setup_dir="$SCRIPT_DIR/hcp-setup"

    #-- Stack delete via API
    step_header "Delete HCP Terraform Stack"
    if [ -z "${TFE_TOKEN:-}" ]; then
        print_warn "TFE_TOKEN not set — skipping Stack delete (manual: HCP UI > Stack > Settings)"
    else
        local hcp_org=""
        [ -f "$hcp_setup_dir/terraform.tfvars" ] && hcp_org=$(grep -E '^\s*tfc_organization' \
            "$hcp_setup_dir/terraform.tfvars" 2>/dev/null | head -1 | awk -F'"' '{print $2}')

        if [ -z "$hcp_org" ]; then
            print_warn "Could not resolve HCP org — skipping Stack delete"
        else
            local stack_id
            stack_id=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" \
                -H "Content-Type: application/vnd.api+json" \
                "$TFE_API/organizations/$hcp_org/stacks" 2>/dev/null \
                | jq -r --arg n "$HCP_STACK_NAME" '.data[] | select(.attributes.name==$n) | .id' | head -1)
            if [ -z "$stack_id" ]; then
                print_info "No HCP Stack '$HCP_STACK_NAME' found"
            else
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
elif [ "$HCP_ONLY" = true ]; then
    print_info "Mode: HCP-only (Stack + varset + IAM role + OIDC)"
    phase_hcp_cleanup
else
    print_info "Mode: FULL (AWS resources + HCP infra)"
    phase_k8s_cleanup
    phase_aws_sweep
    phase_hcp_cleanup
fi

echo ""
phase_header "Teardown Complete"
if [ "$DRY_RUN" = true ]; then
    print_warn "DRY RUN — no changes were made"
else
    print_success "All targeted resources have been removed (KMS keys: 7-day deletion window)"
fi
echo ""
