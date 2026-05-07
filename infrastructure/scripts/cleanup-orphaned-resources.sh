#!/usr/bin/env bash
# Disable AWS CLI pager to prevent vi/less from capturing output
export AWS_PAGER=""
################################################################################
# Cleanup Orphaned AWS Resources — Agentic Runtime Security workshop
#
# Removes orphaned AWS resources that may remain after a failed or incomplete
# Terraform Stacks destroy operation. Scoped to workshop tag
# `Workshop=agentic-runtime-security` plus EKS-cluster name discovery.
#
# Resources cleaned (per VPC):
#   - Load Balancers (Classic ELB + ALB/NLB v2)
#   - Orphaned ENIs (waits for in-use ENIs to release after LB deletion)
#   - Security Groups (strips circular rules, then deletes non-default SGs)
#   - VPC resources (NAT GWs, EIPs, IGW, subnets, route tables, VPC)
#
# Per-cluster:
#   - EKS Node Groups (delete + wait)
#   - EKS Cluster (delete + wait)
#   - CloudWatch Log Group /aws/eks/<cluster>/cluster
#   - KMS Alias alias/eks/<cluster>
#
# Usage:
#   bash cleanup-orphaned-resources.sh [cluster:region ...]
#   bash cleanup-orphaned-resources.sh --tag Workshop=agentic-runtime-security
#
# Defaults: discover VPCs/clusters tagged with Workshop=agentic-runtime-security
# and use the canonical workshop region from infrastructure/deployments.tfdeploy.hcl
################################################################################

# Ensure bash 4+
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or higher."
    echo "Your version: ${BASH_VERSION}"
    echo ""
    echo "On macOS, install newer bash with: brew install bash"
    echo "Then run: /opt/homebrew/bin/bash cleanup-orphaned-resources.sh"
    exit 1
fi

# Note: no set -e — handle errors with an error counter, continue through all phases
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKSHOP_TAG_KEY="Workshop"
WORKSHOP_TAG_VAL="agentic-runtime-security"

print_header()  { echo -e "\n${BLUE}===============================================================${NC}"
                  echo -e "${BLUE}  Cleanup Orphaned AWS Resources (agentic-runtime-security)${NC}"
                  echo -e "${BLUE}===============================================================${NC}\n"; }
print_success() { echo -e "${GREEN}  $1${NC}"; }
print_warning() { echo -e "${YELLOW}  $1${NC}"; }
print_error()   { echo -e "${RED}  $1${NC}"; }
print_info()    { echo -e "${BLUE}  $1${NC}"; }
print_section() { echo -e "\n${YELLOW}-----------------------------------------------------------------${NC}"
                  echo -e "${YELLOW}  $1${NC}"
                  echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"; }

#-------------------------------------------------------------------------------
# Region resolution (no us-west-2 string literal — canonical contract)
#-------------------------------------------------------------------------------
DEFAULT_REGION=""
if [ -n "${AWS_REGION:-}" ]; then
    DEFAULT_REGION="$AWS_REGION"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    TF_DEPLOY="${REPO_ROOT}/infrastructure/deployments.tfdeploy.hcl"
    if [ -f "$TF_DEPLOY" ]; then
        DEFAULT_REGION=$(grep -E '^\s*region\s*=\s*"' "$TF_DEPLOY" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
fi

#-------------------------------------------------------------------------------
# Per-cluster cleanup
#-------------------------------------------------------------------------------

get_vpc_ids_by_tag() {
    local region=$1
    aws ec2 describe-vpcs \
        --region "$region" \
        --filters "Name=tag:${WORKSHOP_TAG_KEY},Values=${WORKSHOP_TAG_VAL}" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null
}

get_vpc_ids_for_cluster() {
    local cluster=$1
    local region=$2
    aws ec2 describe-vpcs \
        --region "$region" \
        --filters "Name=tag:Name,Values=${cluster}*" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null
}

cleanup_security_groups() {
    local region=$1
    local vpc_id=$2
    echo -n "  Orphaned Security Groups in ${vpc_id}... "

    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo -e "${YELLOW}no VPC (skipped)${NC}"; return 0
    fi

    local sg_ids
    sg_ids=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text 2>/dev/null)

    if [[ -z "$sg_ids" || "$sg_ids" == "None" ]]; then
        echo -e "${YELLOW}none found${NC}"; return 0
    fi

    echo ""
    local count=0

    # Phase 1: strip rules to break circular deps
    for sg_id in $sg_ids; do
        local ingress_rules
        ingress_rules=$(aws ec2 describe-security-group-rules \
            --region "$region" \
            --filters "Name=group-id,Values=${sg_id}" \
            --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' \
            --output text 2>/dev/null)
        if [[ -n "$ingress_rules" && "$ingress_rules" != "None" ]]; then
            # shellcheck disable=SC2086
            aws ec2 revoke-security-group-ingress \
                --group-id "$sg_id" --region "$region" \
                --security-group-rule-ids $ingress_rules &>/dev/null
        fi
        local egress_rules
        egress_rules=$(aws ec2 describe-security-group-rules \
            --region "$region" \
            --filters "Name=group-id,Values=${sg_id}" \
            --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' \
            --output text 2>/dev/null)
        if [[ -n "$egress_rules" && "$egress_rules" != "None" ]]; then
            # shellcheck disable=SC2086
            aws ec2 revoke-security-group-egress \
                --group-id "$sg_id" --region "$region" \
                --security-group-rule-ids $egress_rules &>/dev/null
        fi
    done

    # Phase 2: delete SGs
    for sg_id in $sg_ids; do
        echo -n "    Deleting SG: ${sg_id}... "
        if aws ec2 delete-security-group --group-id "$sg_id" --region "$region" &>/dev/null; then
            echo -e "${GREEN}deleted${NC}"
            ((count++))
        else
            echo -e "${RED}failed (may still have dependencies)${NC}"
        fi
    done
    print_success "  Removed $count security group(s)"
}

cleanup_eks_nodegroups() {
    local cluster=$1
    local region=$2
    echo -n "  EKS Node Groups for ${cluster}... "

    if ! aws eks describe-cluster --name "$cluster" --region "$region" &>/dev/null; then
        echo -e "${YELLOW}cluster not found (skipped)${NC}"; return 0
    fi

    local nodegroups
    nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster" --region "$region" \
        --query 'nodegroups[]' --output text 2>/dev/null)

    if [[ -z "$nodegroups" ]]; then
        echo -e "${YELLOW}none found${NC}"; return 0
    fi

    echo ""
    for ng in $nodegroups; do
        echo -n "    Deleting node group: ${ng}... "
        if aws eks delete-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" \
                --region "$region" 2>/dev/null; then
            echo -e "${GREEN}initiated${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    done

    echo -n "    Waiting for node groups to delete... "
    local max_wait=600 waited=0 remaining
    while [[ $waited -lt $max_wait ]]; do
        remaining=$(aws eks list-nodegroups --cluster-name "$cluster" --region "$region" \
            --query 'nodegroups[]' --output text 2>/dev/null)
        if [[ -z "$remaining" ]]; then
            echo -e "${GREEN}done${NC}"; return 0
        fi
        sleep 15; waited=$((waited + 15)); echo -n "."
    done
    echo -e "${YELLOW}timeout (continuing)${NC}"
}

cleanup_eks_cluster() {
    local cluster=$1 region=$2
    echo -n "  EKS Cluster: ${cluster}... "
    if aws eks describe-cluster --name "$cluster" --region "$region" &>/dev/null; then
        if aws eks delete-cluster --name "$cluster" --region "$region" 2>/dev/null; then
            echo -e "${GREEN}delete initiated${NC}"
            echo -n "    Waiting for cluster to delete... "
            local max_wait=900 waited=0
            while [[ $waited -lt $max_wait ]]; do
                if ! aws eks describe-cluster --name "$cluster" --region "$region" 2>/dev/null \
                        | grep -q "clusterName"; then
                    echo -e "${GREEN}done${NC}"; return 0
                fi
                sleep 30; waited=$((waited + 30)); echo -n "."
            done
            echo -e "${YELLOW}timeout (continuing)${NC}"
        else
            echo -e "${RED}failed to delete${NC}"; return 1
        fi
    else
        echo -e "${YELLOW}not found (skipped)${NC}"
    fi
}

cleanup_cloudwatch_logs() {
    local cluster=$1 region=$2
    local log_group="/aws/eks/${cluster}/cluster"
    echo -n "  CloudWatch Log Group: ${log_group}... "
    local found
    found=$(aws logs describe-log-groups --log-group-name-prefix "$log_group" \
        --region "$region" \
        --query "logGroups[?logGroupName=='${log_group}'].logGroupName" \
        --output text 2>/dev/null)
    if [[ -n "$found" && "$found" != "None" ]]; then
        if aws logs delete-log-group --log-group-name "$log_group" --region "$region" 2>/dev/null; then
            echo -e "${GREEN}deleted${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    else
        echo -e "${YELLOW}not found (skipped)${NC}"
    fi
}

cleanup_iam_cluster_roles() {
    local cluster=$1
    echo -n "  IAM roles tagged ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VAL}... "
    # Tag-only sweep — name prefix is unsafe across multi-project accounts AND
    # too narrow (terraform-aws-modules generates names like
    # 'default-eks-node-group-*' that don't include the cluster name).
    local role_names=""
    local all_roles
    all_roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null)
    for r in $all_roles; do
        local tag_match
        tag_match=$(aws iam list-role-tags --role-name "$r" \
            --query "Tags[?Key=='${WORKSHOP_TAG_KEY}' && Value=='${WORKSHOP_TAG_VAL}'].Value" \
            --output text 2>/dev/null)
        if [[ -n "$tag_match" && "$tag_match" != "None" ]]; then
            role_names="$role_names $r"
        fi
    done
    if [[ -z "$role_names" || "$role_names" == "None" ]]; then
        echo -e "${YELLOW}none found${NC}"; return 0
    fi
    echo ""
    for role in $role_names; do
        echo -n "    Role: ${role}... "
        local attached
        attached=$(aws iam list-attached-role-policies --role-name "$role" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
        for p in $attached; do
            aws iam detach-role-policy --role-name "$role" --policy-arn "$p" &>/dev/null
        done
        local inline
        inline=$(aws iam list-role-policies --role-name "$role" \
            --query 'PolicyNames[]' --output text 2>/dev/null)
        for p in $inline; do
            aws iam delete-role-policy --role-name "$role" --policy-name "$p" &>/dev/null
        done
        if aws iam delete-role --role-name "$role" &>/dev/null; then
            echo -e "${GREEN}deleted${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    done
}

cleanup_eks_oidc_provider() {
    local cluster=$1 region=$2
    echo -n "  EKS IAM OIDC provider for ${cluster}... "
    # Find the OIDC provider whose URL matches the (possibly-deleted) cluster's
    # issuer. If the cluster still exists, we can read .identity.oidc.issuer.
    # If it's already deleted, fall back to deleting any oidc.eks.<region>
    # provider that is NOT referenced by any current EKS cluster in the region.
    local issuer=""
    if aws eks describe-cluster --name "$cluster" --region "$region" &>/dev/null; then
        issuer=$(aws eks describe-cluster --name "$cluster" --region "$region" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)
    fi

    # Build the set of issuers in use by remaining EKS clusters in the region
    local in_use_issuers=""
    local clusters_now
    clusters_now=$(aws eks list-clusters --region "$region" --query 'clusters[]' --output text 2>/dev/null)
    for c in $clusters_now; do
        local i
        i=$(aws eks describe-cluster --name "$c" --region "$region" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)
        in_use_issuers="$in_use_issuers $i"
    done

    local providers
    providers=$(aws iam list-open-id-connect-providers \
        --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null)

    local count=0
    for arn in $providers; do
        # Only target EKS-cluster OIDC providers in this region
        [[ "$arn" == *"oidc.eks.${region}.amazonaws.com/id/"* ]] || continue
        local arn_url="https://${arn#*oidc-provider/}"

        # Match by exact issuer if known, else by "not in use"
        local should_delete=false
        if [[ -n "$issuer" && "$arn_url" == "$issuer" ]]; then
            should_delete=true
        elif [[ -z "$issuer" ]]; then
            # Cluster gone: delete only if not referenced by any current cluster
            local in_use=false
            for u in $in_use_issuers; do
                [[ "$arn_url" == "$u" ]] && in_use=true
            done
            [[ "$in_use" == false ]] && should_delete=true
        fi

        if [[ "$should_delete" == true ]]; then
            if aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" &>/dev/null; then
                ((count++))
            fi
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}none to delete${NC}"
    else
        echo -e "${GREEN}deleted $count provider(s)${NC}"
    fi
}

cleanup_workshop_kms() {
    local region=$1
    echo -n "  KMS keys tagged ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VAL}... "
    local key_ids
    key_ids=$(aws kms list-keys --region "$region" --query 'Keys[].KeyId' --output text 2>/dev/null)
    local matching=""
    for k in $key_ids; do
        # Skip AWS-managed keys (their tag list call errors)
        local tag
        tag=$(aws kms list-resource-tags --region "$region" --key-id "$k" \
            --query "Tags[?TagKey=='${WORKSHOP_TAG_KEY}' && TagValue=='${WORKSHOP_TAG_VAL}'].TagValue" \
            --output text 2>/dev/null)
        if [[ -n "$tag" && "$tag" != "None" ]]; then
            matching="$matching $k"
        fi
    done
    if [[ -z "$matching" ]]; then
        echo -e "${YELLOW}none found${NC}"; return 0
    fi
    echo ""
    for k in $matching; do
        # Delete any aliases pointing at this key first
        local aliases
        aliases=$(aws kms list-aliases --region "$region" \
            --query "Aliases[?TargetKeyId=='${k}'].AliasName" --output text 2>/dev/null)
        for a in $aliases; do
            aws kms delete-alias --region "$region" --alias-name "$a" &>/dev/null \
                && echo -e "    Deleted alias ${a}" || echo -e "    ${RED}Failed alias ${a}${NC}"
        done
        echo -n "    Scheduling key deletion (7-day window): ${k}... "
        if aws kms schedule-key-deletion --region "$region" --key-id "$k" \
                --pending-window-in-days 7 &>/dev/null; then
            echo -e "${GREEN}scheduled${NC}"
        else
            echo -e "${YELLOW}skipped (may be already pending)${NC}"
        fi
    done
}

cleanup_kms_alias() {
    local cluster=$1 region=$2
    local alias_name="alias/eks/${cluster}"
    echo -n "  KMS Alias: ${alias_name}... "
    local found
    found=$(aws kms list-aliases --region "$region" \
        --query "Aliases[?AliasName=='${alias_name}'].AliasName" \
        --output text 2>/dev/null)
    if [[ -n "$found" && "$found" != "None" ]]; then
        if aws kms delete-alias --alias-name "$alias_name" --region "$region" 2>/dev/null; then
            echo -e "${GREEN}deleted${NC}"
        else
            echo -e "${RED}failed${NC}"
        fi
    else
        echo -e "${YELLOW}not found (skipped)${NC}"
    fi
}

cleanup_enis() {
    local vpc_id=$1 region=$2
    echo -n "  Orphaned ENIs in ${vpc_id}... "
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo -e "${YELLOW}no VPC (skipped)${NC}"; return 0
    fi

    local in_use=0
    in_use=$(aws ec2 describe-network-interfaces --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=in-use" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)

    if [[ "$in_use" -gt 0 ]]; then
        echo ""
        echo -n "    Waiting for $in_use in-use ENI(s) to release (up to 5 min)"
        local waited=0
        while [[ $waited -lt 300 ]]; do
            in_use=$(aws ec2 describe-network-interfaces --region "$region" \
                --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=in-use" \
                --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
            if [[ "$in_use" -eq 0 ]]; then
                echo -e " ${GREEN}released${NC}"; break
            fi
            sleep 10; waited=$((waited + 10)); echo -n "."
        done
        if [[ "$in_use" -gt 0 ]]; then
            echo -e " ${YELLOW}timeout ($in_use still in-use)${NC}"
        fi
    fi

    local eni_ids
    eni_ids=$(aws ec2 describe-network-interfaces --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)

    if [[ -z "$eni_ids" || "$eni_ids" == "None" ]]; then
        if [[ "$in_use" -eq 0 ]]; then
            echo -e "${YELLOW}none found${NC}"
        fi
        return 0
    fi
    local count=0
    for eni_id in $eni_ids; do
        if aws ec2 delete-network-interface --network-interface-id "$eni_id" \
                --region "$region" &>/dev/null; then
            ((count++))
        fi
    done
    echo -e "    ${GREEN}deleted $count ENI(s)${NC}"
}

cleanup_vpc_endpoints() {
    local vpc_id=$1 region=$2
    echo -n "  VPC Endpoints in ${vpc_id}... "
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo -e "${YELLOW}no VPC (skipped)${NC}"; return 0
    fi
    local vpce_ids
    vpce_ids=$(aws ec2 describe-vpc-endpoints --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" \
        --output text 2>/dev/null)
    if [[ -z "$vpce_ids" || "$vpce_ids" == "None" ]]; then
        echo -e "${YELLOW}none found${NC}"; return 0
    fi
    echo ""
    echo -n "    Deleting endpoints: $vpce_ids... "
    # shellcheck disable=SC2086
    aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids $vpce_ids &>/dev/null
    echo -e "${GREEN}initiated${NC}"
    echo -n "    Waiting for endpoints + ENIs to release"
    local waited=0 remaining
    while [[ $waited -lt 180 ]]; do
        remaining=$(aws ec2 describe-vpc-endpoints --region "$region" \
            --filters "Name=vpc-id,Values=${vpc_id}" \
            --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" \
            --output text 2>/dev/null)
        if [[ -z "$remaining" || "$remaining" == "None" ]]; then
            echo -e " ${GREEN}done${NC}"; return 0
        fi
        sleep 10; waited=$((waited + 10)); echo -n "."
    done
    echo -e " ${YELLOW}timeout (continuing)${NC}"
}

cleanup_elbs() {
    local vpc_id=$1 region=$2
    echo -n "  Load Balancers in ${vpc_id}... "
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo -e "${YELLOW}no VPC (skipped)${NC}"; return 0
    fi
    local count=0
    declare -A lb_arns_to_delete

    local classic_lbs
    classic_lbs=$(aws elb describe-load-balancers --region "$region" \
        --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" \
        --output text 2>/dev/null)
    if [[ -n "$classic_lbs" && "$classic_lbs" != "None" ]]; then
        for lb_name in $classic_lbs; do
            if aws elb delete-load-balancer --load-balancer-name "$lb_name" \
                    --region "$region" &>/dev/null; then
                ((count++))
            fi
        done
    fi

    local v2_lb_arns
    v2_lb_arns=$(aws elbv2 describe-load-balancers --region "$region" \
        --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" \
        --output text 2>/dev/null)
    if [[ -n "$v2_lb_arns" && "$v2_lb_arns" != "None" ]]; then
        for arn in $v2_lb_arns; do lb_arns_to_delete["$arn"]=1; done
    fi

    for arn in "${!lb_arns_to_delete[@]}"; do
        if aws elbv2 delete-load-balancer --load-balancer-arn "$arn" \
                --region "$region" &>/dev/null; then
            ((count++))
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}none found${NC}"
    else
        echo -e "${GREEN}deleted $count load balancer(s)${NC}"
    fi
}

cleanup_vpc_resources() {
    local region=$1 vpc_id=$2
    echo -n "  VPC cleanup for ${vpc_id}... "
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo -e "${YELLOW}not found (skipped)${NC}"; return 0
    fi
    echo ""

    # 1. NAT Gateways
    local nat_gws
    # shellcheck disable=SC2016
    nat_gws=$(aws ec2 describe-nat-gateways --region "$region" \
        --filter "Name=vpc-id,Values=${vpc_id}" \
        --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
        --output text 2>/dev/null)
    if [[ -n "$nat_gws" && "$nat_gws" != "None" ]]; then
        for nat_id in $nat_gws; do
            echo -n "    Deleting NAT Gateway: ${nat_id}... "
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --region "$region" &>/dev/null
            echo -e "${GREEN}initiated${NC}"
        done
        echo -n "    Waiting for NAT Gateways to delete"
        local waited=0 remaining
        while [[ $waited -lt 120 ]]; do
            # shellcheck disable=SC2016
            remaining=$(aws ec2 describe-nat-gateways --region "$region" \
                --filter "Name=vpc-id,Values=${vpc_id}" \
                --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
                --output text 2>/dev/null)
            if [[ -z "$remaining" || "$remaining" == "None" ]]; then
                echo -e " ${GREEN}done${NC}"; break
            fi
            sleep 10; waited=$((waited + 10)); echo -n "."
        done
        if [[ $waited -ge 120 ]]; then
            echo -e " ${YELLOW}timeout${NC}"
        fi
    fi

    # 2. Release unassociated EIPs
    local eip_allocs
    eip_allocs=$(aws ec2 describe-addresses --region "$region" \
        --filters "Name=domain,Values=vpc" \
        --query "Addresses[?NetworkInterfaceId==null || NetworkInterfaceId==''].AllocationId" \
        --output text 2>/dev/null)
    if [[ -n "$eip_allocs" && "$eip_allocs" != "None" ]]; then
        for alloc_id in $eip_allocs; do
            echo -n "    Releasing EIP: ${alloc_id}... "
            if aws ec2 release-address --allocation-id "$alloc_id" --region "$region" &>/dev/null; then
                echo -e "${GREEN}released${NC}"
            else
                echo -e "${YELLOW}skipped${NC}"
            fi
        done
    fi

    # 3. IGW
    local igw_ids
    igw_ids=$(aws ec2 describe-internet-gateways --region "$region" \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null)
    if [[ -n "$igw_ids" && "$igw_ids" != "None" ]]; then
        for igw_id in $igw_ids; do
            echo -n "    Detaching IGW: ${igw_id}... "
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" \
                --vpc-id "$vpc_id" --region "$region" &>/dev/null
            echo -e "${GREEN}detached${NC}"
            echo -n "    Deleting IGW: ${igw_id}... "
            if aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" \
                    --region "$region" &>/dev/null; then
                echo -e "${GREEN}deleted${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        done
    fi

    # 4. Subnets
    local subnet_ids
    subnet_ids=$(aws ec2 describe-subnets --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].SubnetId' --output text 2>/dev/null)
    if [[ -n "$subnet_ids" && "$subnet_ids" != "None" ]]; then
        for subnet_id in $subnet_ids; do
            echo -n "    Deleting subnet: ${subnet_id}... "
            if aws ec2 delete-subnet --subnet-id "$subnet_id" --region "$region" &>/dev/null; then
                echo -e "${GREEN}deleted${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        done
    fi

    # 5. Route tables
    local rtb_ids
    rtb_ids=$(aws ec2 describe-route-tables --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
        --output text 2>/dev/null)
    if [[ -n "$rtb_ids" && "$rtb_ids" != "None" ]]; then
        for rtb_id in $rtb_ids; do
            echo -n "    Deleting route table: ${rtb_id}... "
            if aws ec2 delete-route-table --route-table-id "$rtb_id" --region "$region" &>/dev/null; then
                echo -e "${GREEN}deleted${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        done
    fi

    # 6. VPC
    echo -n "    Deleting VPC: ${vpc_id}... "
    if aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$region" &>/dev/null; then
        echo -e "${GREEN}deleted${NC}"
    else
        echo -e "${RED}failed${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    print_header

    local TAG_ARG=""
    CLUSTER_LIST=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) TAG_ARG="$2"; shift ;;
            --help|-h)
                cat <<USAGE
Usage: $0 [--tag Key=Value] [cluster:region ...]

Default tag: Workshop=agentic-runtime-security
Default region: from \$AWS_REGION or infrastructure/deployments.tfdeploy.hcl
USAGE
                exit 0 ;;
            *) CLUSTER_LIST+=("$1") ;;
        esac
        shift
    done

    if [ -n "$TAG_ARG" ]; then
        WORKSHOP_TAG_KEY="${TAG_ARG%%=*}"
        WORKSHOP_TAG_VAL="${TAG_ARG#*=}"
    fi

    if ! command -v aws &>/dev/null; then
        print_error "AWS CLI is not installed."; exit 1
    fi
    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured."; exit 1
    fi

    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    print_info "AWS Account:   ${account_id}"
    print_info "Workshop tag:  ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VAL}"
    print_info "Default region: ${DEFAULT_REGION:-<unresolved>}"

    local errors=0

    if [ ${#CLUSTER_LIST[@]} -gt 0 ]; then
        # Per-cluster cleanup mode
        for item in "${CLUSTER_LIST[@]}"; do
            local cluster="${item%%:*}"
            local region="${item##*:}"
            [ "$cluster" = "$item" ] && region="$DEFAULT_REGION"

            print_section "Cleaning up: ${cluster} (${region})"

            cleanup_eks_nodegroups "$cluster" "$region" || errors=$((errors + 1))
            cleanup_eks_cluster   "$cluster" "$region" || errors=$((errors + 1))
            cleanup_cloudwatch_logs "$cluster" "$region" || errors=$((errors + 1))
            cleanup_kms_alias       "$cluster" "$region" || errors=$((errors + 1))
            cleanup_eks_oidc_provider "$cluster" "$region" || errors=$((errors + 1))
            cleanup_iam_cluster_roles "$cluster"        || errors=$((errors + 1))
            cleanup_workshop_kms    "$region"           || errors=$((errors + 1))

            local vpc_ids
            vpc_ids=$(get_vpc_ids_for_cluster "$cluster" "$region")
            if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
                for vpc_id in $vpc_ids; do
                    print_info "VPC: ${vpc_id}"
                    cleanup_elbs           "$vpc_id" "$region" || errors=$((errors + 1))
                    cleanup_vpc_endpoints  "$vpc_id" "$region" || errors=$((errors + 1))
                    cleanup_enis           "$vpc_id" "$region" || errors=$((errors + 1))
                    cleanup_security_groups "$region" "$vpc_id" || errors=$((errors + 1))
                    cleanup_vpc_resources  "$region" "$vpc_id" || errors=$((errors + 1))
                done
            else
                print_info "No VPCs found for ${cluster}"
            fi
        done
    else
        # Tag-scoped sweep
        if [ -z "$DEFAULT_REGION" ]; then
            print_error "Could not resolve default region. Set AWS_REGION or pass cluster:region pairs."
            exit 1
        fi
        print_section "Sweeping VPCs tagged ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VAL} in ${DEFAULT_REGION}"

        local vpc_ids
        vpc_ids=$(get_vpc_ids_by_tag "$DEFAULT_REGION")
        if [[ -z "$vpc_ids" || "$vpc_ids" == "None" ]]; then
            print_info "No tagged VPCs found in ${DEFAULT_REGION}"
        else
            for vpc_id in $vpc_ids; do
                print_info "VPC: ${vpc_id}"
                cleanup_elbs           "$vpc_id" "$DEFAULT_REGION" || errors=$((errors + 1))
                cleanup_vpc_endpoints  "$vpc_id" "$DEFAULT_REGION" || errors=$((errors + 1))
                cleanup_enis           "$vpc_id" "$DEFAULT_REGION" || errors=$((errors + 1))
                cleanup_security_groups "$DEFAULT_REGION" "$vpc_id" || errors=$((errors + 1))
                cleanup_vpc_resources  "$DEFAULT_REGION" "$vpc_id" || errors=$((errors + 1))
            done
        fi
        # Tag-scoped cross-VPC sweeps (run once after VPC loop)
        cleanup_workshop_kms "$DEFAULT_REGION" || errors=$((errors + 1))
        # IAM is global — pass dummy cluster arg for log line
        cleanup_iam_cluster_roles "tag-scoped" || errors=$((errors + 1))
    fi

    echo ""
    print_section "Summary"
    if [[ $errors -eq 0 ]]; then
        print_success "Cleanup completed successfully!"
    else
        print_warning "Cleanup completed with ${errors} error(s) — some resources may need manual cleanup"
    fi
    echo ""
}

main "$@"
