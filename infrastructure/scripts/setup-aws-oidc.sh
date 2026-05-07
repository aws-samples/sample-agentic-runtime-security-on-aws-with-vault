#!/usr/bin/env bash
#===============================================================================
# Setup AWS IAM Role for HCP Terraform Stacks OIDC Authentication
#
# Mirrors the structure of:
#   ~/git-repos/eks-terraform-stacks/infrastructure/scripts/setup-aws-oidc.sh
#
# Differences from the reference repo (intentional, minor):
# - ROLE_NAME = "hcp-stacks-deploy" (workshop-local convention,
#   vs eks-stacks "hcp-terraform-stacks-role")
# - Attaches AdministratorAccess (workshop pedagogical scope — the workshop
#   teaches the 5 control objectives at workload-identity / data-plane,
#   NOT IAM least-privilege design). The reference repo creates a scoped
#   policy "hcp-terraform-stacks-policy"; we deliberately skip that here.
#
# This script creates:
# 1. OIDC Identity Provider for HCP Terraform (if not exists)
# 2. IAM Role with trust policy for the Stack
# 3. Attaches AdministratorAccess to the role
#
# Idempotent: re-running updates the trust policy + thumbprint and re-attaches
# the policy. Safe to call from bootstrap.sh and from workshop-e2e.sh.
#
# Usage: ./setup-aws-oidc.sh <HCP_ORG>
# Example: ./setup-aws-oidc.sh DevOpsOscar
#===============================================================================

set -e

# Disable AWS CLI pager to prevent vi/less from capturing output
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Input validation
#-------------------------------------------------------------------------------
if [ $# -ne 1 ]; then
    echo -e "${RED}Error: Missing required argument${NC}"
    echo ""
    echo "Usage: $0 <HCP_ORG>"
    echo ""
    echo "Arguments:"
    echo "  HCP_ORG - Your HCP Terraform organization name"
    echo ""
    echo "Example:"
    echo "  $0 DevOpsOscar"
    exit 1
fi

HCP_ORG="$1"

#-------------------------------------------------------------------------------
# Get AWS Account ID
#-------------------------------------------------------------------------------
echo -e "${YELLOW}Fetching AWS Account ID...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Could not retrieve AWS Account ID. Check your AWS credentials.${NC}"
    exit 1
fi

echo -e "${GREEN}AWS Account ID: ${AWS_ACCOUNT_ID}${NC}"

#-------------------------------------------------------------------------------
# Variables
#-------------------------------------------------------------------------------
OIDC_PROVIDER="app.terraform.io"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
ROLE_NAME="hcp-stacks-deploy"

#-------------------------------------------------------------------------------
# Create OIDC Identity Provider (if not exists)
#-------------------------------------------------------------------------------
echo -e "${YELLOW}Checking for existing OIDC provider...${NC}"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" > /dev/null 2>&1; then
    echo -e "${GREEN}OIDC provider already exists.${NC}"

    # Verify thumbprint is current (TFC rotates certs periodically)
    CURRENT_THUMBPRINT=$(aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
        --query 'ThumbprintList[0]' --output text 2>/dev/null)
    LIVE_THUMBPRINT=$(echo | openssl s_client -servername "$OIDC_PROVIDER" -connect "${OIDC_PROVIDER}:443" -showcerts 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' \
        | awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; cert=""} {cert=cert"\n"$0} /END CERTIFICATE/{certs[n]=cert} END{print certs[n]}' \
        | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
        | sed 's/://g' | awk -F= '{print tolower($2)}')

    if [ -n "$LIVE_THUMBPRINT" ] && [ "$CURRENT_THUMBPRINT" != "$LIVE_THUMBPRINT" ]; then
        echo -e "${YELLOW}Updating stale OIDC thumbprint...${NC}"
        aws iam update-open-id-connect-provider-thumbprint \
            --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
            --thumbprint-list "$LIVE_THUMBPRINT" > /dev/null
        echo -e "${GREEN}Thumbprint updated to: $LIVE_THUMBPRINT${NC}"
    fi
else
    echo -e "${YELLOW}Creating OIDC Identity Provider for HCP Terraform...${NC}"

    # Dynamically fetch the root CA thumbprint for app.terraform.io.
    # AWS OIDC requires the top intermediate/root CA thumbprint, NOT the leaf cert.
    # We extract the last certificate in the chain (root CA) and compute its SHA-1 fingerprint.
    # (Terraform Cloud rotates certificates periodically; hardcoded thumbprints go stale.)
    THUMBPRINT=$(echo | openssl s_client -servername "$OIDC_PROVIDER" -connect "${OIDC_PROVIDER}:443" -showcerts 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' \
        | awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; cert=""} {cert=cert"\n"$0} /END CERTIFICATE/{certs[n]=cert} END{print certs[n]}' \
        | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
        | sed 's/://g' | awk -F= '{print tolower($2)}')

    if [ -z "$THUMBPRINT" ]; then
        echo -e "${RED}Failed to fetch TLS thumbprint for $OIDC_PROVIDER${NC}"
        exit 1
    fi
    echo -e "${YELLOW}Using thumbprint: $THUMBPRINT${NC}"

    aws iam create-open-id-connect-provider \
        --url "https://${OIDC_PROVIDER}" \
        --client-id-list "aws.workload.identity" \
        --thumbprint-list "$THUMBPRINT" > /dev/null

    echo -e "${GREEN}OIDC provider created successfully.${NC}"

    # Wait for OIDC provider to propagate globally in IAM
    echo -e "${YELLOW}Waiting 15s for OIDC provider to propagate...${NC}"
    sleep 15
fi

#-------------------------------------------------------------------------------
# Create Trust Policy
# Uses both the provided org name AND its lowercase form in StringLike
# because HCP Terraform may normalize org names to lowercase in OIDC tokens.
# AWS StringLike is case-sensitive, so we accept both to be safe.
#-------------------------------------------------------------------------------
echo -e "${YELLOW}Creating trust policy...${NC}"

HCP_ORG_LOWER=$(echo "$HCP_ORG" | tr '[:upper:]' '[:lower:]')

# Build the sub condition — single value if already lowercase, array if mixed case
if [ "$HCP_ORG" = "$HCP_ORG_LOWER" ]; then
    SUB_CONDITION="\"organization:${HCP_ORG}:*\""
else
    SUB_CONDITION="[\"organization:${HCP_ORG}:*\", \"organization:${HCP_ORG_LOWER}:*\"]"
fi

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "app.terraform.io:aud": "aws.workload.identity"
        },
        "StringLike": {
          "app.terraform.io:sub": ${SUB_CONDITION}
        }
      }
    }
  ]
}
EOF
)

#-------------------------------------------------------------------------------
# Create or Update IAM Role
#-------------------------------------------------------------------------------
echo -e "${YELLOW}Checking for existing IAM role...${NC}"

if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    echo -e "${YELLOW}Role exists. Updating trust policy...${NC}"
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "$TRUST_POLICY" > /dev/null
    echo -e "${GREEN}Trust policy updated.${NC}"
else
    echo -e "${YELLOW}Creating IAM role: ${ROLE_NAME}...${NC}"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "IAM role for HCP Terraform Stacks OIDC authentication — Agentic Runtime Security workshop" > /dev/null
    echo -e "${GREEN}IAM role created.${NC}"
fi

#-------------------------------------------------------------------------------
# Attach AdministratorAccess (workshop pedagogical scope)
#
# NOTE: The eks-terraform-stacks reference repo creates and attaches a
# scoped IAM policy ("hcp-terraform-stacks-policy") here. This workshop
# intentionally uses AdministratorAccess to keep IAM out of the teaching
# surface — see CLAUDE.md "Workshop pedagogical scope". For production
# deployments, replace this attach with the scoped policy from the
# reference repo's setup-aws-oidc.sh lines 184-339.
#-------------------------------------------------------------------------------
echo -e "${YELLOW}Attaching AdministratorAccess (workshop pedagogical scope)...${NC}"

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" > /dev/null

echo -e "${GREEN}AdministratorAccess attached.${NC}"

#-------------------------------------------------------------------------------
# Output
#-------------------------------------------------------------------------------
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo -e "${GREEN}===============================================================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}===============================================================================${NC}"
echo ""
echo -e "Role ARN (use this in HCP Terraform):"
echo -e "${YELLOW}${ROLE_ARN}${NC}"
echo ""
echo -e "Next steps:"
echo -e "1. In HCP Terraform, set the ${YELLOW}aws_role_arn${NC} variable to:"
echo -e "   ${ROLE_ARN}"
echo ""
echo -e "2. Run your Stack deployment"
echo ""
echo -e "${GREEN}===============================================================================${NC}"
