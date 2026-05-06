#!/usr/bin/env bash
#===============================================================================
# Pre-flight check: IAM permissions for HCP Stacks bootstrap (PREF-03)
#
# Calls iam:SimulatePrincipalPolicy for the actions Stacks needs at
# bootstrap-time (OIDC, IAM role, EKS, EC2, RDS, AOSS, Bedrock).
#
# Pitfall §7 mitigation: many restricted principals lack
# iam:SimulatePrincipalPolicy itself. We "self-test" the simulator first by
# simulating a free action (sts:GetCallerIdentity); if the simulator denies
# itself, we WARN (not FAIL) and skip the action loop — falling back to
# heuristic best-effort.
#
# Per CONTEXT.md:
#   - Continue on failure (no set -e)
#   - Unicode markers (✓ PASS / ✗ FAIL / ⚠ WARN) via common-checks.sh
#   - Full inline copy-paste remediation per failure
#
# Usage:
#   ./check-permissions.sh
#===============================================================================

# NOTE: NO `set -e` — continue-on-failure required.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_PAGER=""

echo
echo -e "${BLUE}=== IAM Permissions for Stacks Bootstrap (PREF-03) ===${NC}"
echo

#-------------------------------------------------------------------------------
# Step 1 — derive PRINCIPAL_ARN
#-------------------------------------------------------------------------------
RAW_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)

if [ -z "$RAW_ARN" ] || [ "$RAW_ARN" = "None" ]; then
    print_fail "Could not resolve caller identity" \
        "Run 'aws configure' or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY. If using AWS SSO: 'aws sso login --profile <profile>'."
    exit 0
fi

#-------------------------------------------------------------------------------
# Step 2 — assumed-role -> underlying IAM role rewrite
#
# Mirrors reference bootstrap.sh lines 286-303: simulate-principal-policy
# requires an IAM ARN (role/user), not an STS assumed-role ARN.
#-------------------------------------------------------------------------------
if [[ "$RAW_ARN" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "$RAW_ARN" | sed 's|.*assumed-role/\([^/]*\)/.*|\1|')
    PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    print_info "Caller is assumed-role; using underlying IAM role ARN: ${PRINCIPAL_ARN}"
else
    PRINCIPAL_ARN="$RAW_ARN"
    print_info "Principal ARN: ${PRINCIPAL_ARN}"
fi
echo

#-------------------------------------------------------------------------------
# Step 3 — self-test the simulator (Pitfall §7)
#
# If the calling principal can't even simulate itself for sts:GetCallerIdentity,
# the simulator is unavailable — emit WARN and exit early (do NOT FAIL the
# entire script; many federated/SSO/restricted principals legitimately lack
# iam:SimulatePrincipalPolicy and there's nothing the workshop attendee can do
# to grant it to themselves).
#-------------------------------------------------------------------------------
echo -e "${BLUE}[Self-test] iam:SimulatePrincipalPolicy availability${NC}"
selftest=$(aws iam simulate-principal-policy \
    --policy-source-arn "$PRINCIPAL_ARN" \
    --action-names "sts:GetCallerIdentity" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text 2>/dev/null || echo "ERROR")

if [ "$selftest" = "ERROR" ] || [ "$selftest" = "" ] || [ "$selftest" = "None" ]; then
    print_warn "iam:SimulatePrincipalPolicy unavailable — falling back to heuristic"
    print_info "The calling principal cannot simulate-principal-policy on itself. This is common for SSO/federated/restricted principals. Skipping action-loop verification — proceed and rely on bootstrap.sh / Stacks deploys to surface real permission failures."
    exit 0
fi

print_pass "Simulator is available (self-test EvalDecision=${selftest})"
echo

#-------------------------------------------------------------------------------
# Step 4 — required actions
#
# Stacks bootstrap-time IAM actions. List adapted from RESEARCH §Code Example 5
# plus the additions required by 01-04-PLAN.md:
#   - iam:CreateOpenIDConnectProvider, iam:CreateRole, iam:AttachRolePolicy,
#     iam:CreateInstanceProfile, iam:PassRole, iam:CreateServiceLinkedRole
#   - sts:AssumeRoleWithWebIdentity (HCP OIDC trust)
#   - eks:CreateCluster, eks:DescribeCluster, eks:CreateAddon
#   - ec2:DescribeVpcs, ec2:CreateSubnet, ec2:CreateNatGateway, ec2:AllocateAddress
#   - rds:CreateDBInstance
#   - aoss:CreateCollection
#   - bedrock:GetFoundationModelAvailability
# 17 actions total — well under the simulator's 100-action API limit.
#-------------------------------------------------------------------------------
REQUIRED_ACTIONS=(
    iam:CreateOpenIDConnectProvider
    iam:CreateRole
    iam:AttachRolePolicy
    iam:CreateInstanceProfile
    iam:PassRole
    iam:CreateServiceLinkedRole
    sts:AssumeRoleWithWebIdentity
    eks:CreateCluster
    eks:DescribeCluster
    eks:CreateAddon
    ec2:DescribeVpcs
    ec2:CreateSubnet
    ec2:CreateNatGateway
    ec2:AllocateAddress
    rds:CreateDBInstance
    aoss:CreateCollection
    bedrock:GetFoundationModelAvailability
)

echo -e "${BLUE}[Action loop] Simulating ${#REQUIRED_ACTIONS[@]} required actions${NC}"

# Build a comma-separated list of actions for one batched simulator call.
# (simulate-principal-policy supports up to 100 actions per call.)
actions_csv=$(IFS=,; echo "${REQUIRED_ACTIONS[*]}")

# Run the simulator once; output JSON of EvalActionName + EvalDecision.
sim_out=$(aws iam simulate-principal-policy \
    --policy-source-arn "$PRINCIPAL_ARN" \
    --action-names ${REQUIRED_ACTIONS[@]} \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' \
    --output text 2>/dev/null)

if [ -z "$sim_out" ]; then
    print_fail "Batched simulator call returned no results (actions=${actions_csv})" \
        "Re-run with --debug: aws iam simulate-principal-policy --policy-source-arn ${PRINCIPAL_ARN} --action-names ${actions_csv} --debug. If 'AccessDenied: not authorized to perform iam:SimulatePrincipalPolicy', attach a policy granting that action OR use AdministratorAccess for the workshop."
    exit 0
fi

# Iterate over the simulator output (tab-separated).
while IFS=$'\t' read -r action decision; do
    if [ "$decision" = "allowed" ]; then
        print_pass "${action}: allowed"
    else
        print_fail "${action}: ${decision}" \
            "Attach a policy granting ${action} to ${PRINCIPAL_ARN}, or use AWS managed policy AdministratorAccess for the workshop. Workshop pedagogical scope = Admin; production deployments use the scoped least-privilege policy in infrastructure/scripts/hcp-setup."
    fi
done <<< "$sim_out"

# trap registered in common-checks.sh emits the summary
