#!/usr/bin/env bash
#===============================================================================
# test-eks.sh — verify the workshop EKS cluster is healthy
#
# Checks:
#   - aws eks describe-cluster status == ACTIVE
#   - kubectl get nodes returns >= 2 Ready nodes
#   - 5 managed addons all ACTIVE: vpc-cni, coredns, kube-proxy,
#     eks-pod-identity-agent, aws-ebs-csi-driver
#   - aws eks list-access-entries returns the workshop admin entry
#
# Usage:
#   ./test-eks.sh --cluster-name <name> [--region <region>]
#
# Region resolution: --region arg, then $AWS_REGION, then deployments.tfdeploy.hcl.
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AWS_PAGER=""

CLUSTER_NAME=""
CLI_REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift ;;
        --region)       CLI_REGION="$2"; shift ;;
        --help|-h)
            cat <<USAGE
Usage: $0 --cluster-name <name> [--region <region>]

Verifies the workshop EKS cluster: status, nodes, 5 managed addons, access entry.
USAGE
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$CLUSTER_NAME" ]; then
    echo "ERROR: --cluster-name is required" >&2
    exit 1
fi

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"
# shellcheck source=resolve-region.sh
source "$SCRIPT_DIR/resolve-region.sh"
resolve_region "$CLI_REGION" || exit 1
REGION="$RESOLVED_REGION"

echo
echo -e "${BLUE}=== test-eks.sh ===${NC}"
echo -e "  Cluster: ${CLUSTER_NAME}"
echo -e "  Region:  ${REGION}"
echo

# 1. Cluster status
status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query 'cluster.status' --output text 2>&1)
if [ "$status" = "ACTIVE" ]; then
    print_pass "Cluster status: ACTIVE"
else
    print_fail "Cluster status: ${status}" \
        "Run: aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}. If 'ResourceNotFoundException', the cluster does not exist — verify the foundation Stack converged in HCP Terraform UI."
fi

# 2. kubectl get nodes — require >= 2 Ready
if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" \
        --alias "$CLUSTER_NAME" >/dev/null 2>&1; then
    print_fail "Could not update kubeconfig for ${CLUSTER_NAME}" \
        "Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}. Verify AWS credentials and that the cluster is ACTIVE."
else
    ready_nodes=$(kubectl --context "$CLUSTER_NAME" get nodes --no-headers 2>/dev/null \
        | awk '$2=="Ready"{c++} END{print c+0}')
    if [ "$ready_nodes" -ge 2 ]; then
        print_pass "Ready nodes: ${ready_nodes} (>= 2)"
    else
        print_fail "Ready nodes: ${ready_nodes} (require >= 2)" \
            "Run: kubectl --context ${CLUSTER_NAME} get nodes. Inspect node-group scaling in EKS console; managed node group desired_size should be >= 2."
    fi
fi

# 3. Managed addons
REQUIRED_ADDONS=(vpc-cni coredns kube-proxy eks-pod-identity-agent aws-ebs-csi-driver)
addon_list=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --query 'addons[]' --output text 2>/dev/null)

for addon in "${REQUIRED_ADDONS[@]}"; do
    if ! echo "$addon_list" | tr '\t' '\n' | grep -qx "$addon"; then
        print_fail "Addon missing: ${addon}" \
            "Install: aws eks create-addon --cluster-name ${CLUSTER_NAME} --region ${REGION} --addon-name ${addon}. Or re-run the foundation Stack apply."
        continue
    fi
    addon_status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" \
        --addon-name "$addon" --query 'addon.status' --output text 2>/dev/null)
    if [ "$addon_status" = "ACTIVE" ]; then
        print_pass "Addon ${addon}: ACTIVE"
    else
        print_fail "Addon ${addon}: ${addon_status}" \
            "Run: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --region ${REGION} --addon-name ${addon}. If DEGRADED/CREATE_FAILED, inspect 'health.issues' and re-create."
    fi
done

# 4. Access entries — at least one entry should exist (workshop admin)
entries=$(aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --query 'accessEntries[]' --output text 2>/dev/null)
if [ -n "$entries" ] && [ "$entries" != "None" ]; then
    print_pass "Access entries present"
else
    print_fail "No EKS access entries found" \
        "Run: aws eks list-access-entries --cluster-name ${CLUSTER_NAME} --region ${REGION}. The foundation Stack should create an admin access entry for the workshop principal."
fi

# common-checks.sh EXIT trap emits print_summary and propagates exit code.
