#!/usr/bin/env bash
#===============================================================================
# Pre-flight check: Amazon Bedrock model access (PREF-01)
#
# Verifies that the AWS account has access to the workshop's required model
# (anthropic.claude-sonnet-4-6) AND its cross-region inference profile
# (us.anthropic.claude-sonnet-4-6) in us-west-2.
#
# Three checks:
#   1. Base model agreement available (foundation-model-availability:
#      agreementAvailability.status == AVAILABLE)
#   2. Base model entitlement available (entitlementAvailability == AVAILABLE)
#   3. Cross-region inference profile us.anthropic.claude-sonnet-4-6 exists
#
# Per CONTEXT.md §pre-flight scripts:
#   - Continue on failure (no set -e)
#   - Unicode markers (✓ PASS / ✗ FAIL / ⚠ WARN) via common-checks.sh
#   - Full inline copy-paste remediation per failure
#
# Usage:
#   ./check-bedrock-access.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more failed (summary printed by common-checks.sh EXIT trap)
#===============================================================================

# NOTE: NO `set -e` — RESEARCH §Anti-pattern. Continue-on-failure is required.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

# Workshop-locked model + region (CONTEXT.md decisions)
MODEL_ID="anthropic.claude-sonnet-4-6"
INFERENCE_PROFILE_ID="us.anthropic.claude-sonnet-4-6"
AWS_REGION="${AWS_REGION:-us-west-2}"

# Disable AWS CLI pager (would otherwise capture stdout in less/vi)
export AWS_PAGER=""

echo
echo -e "${BLUE}=== Bedrock Model Access (PREF-01) ===${NC}"
echo -e "  Region:            ${AWS_REGION}"
echo -e "  Model:             ${MODEL_ID}"
echo -e "  Inference Profile: ${INFERENCE_PROFILE_ID}"
echo

#-------------------------------------------------------------------------------
# Pre-flight: AWS credentials
#-------------------------------------------------------------------------------
if ! aws sts get-caller-identity --output text --query 'Account' >/dev/null 2>&1; then
    print_fail "AWS credentials not configured" \
        "Run 'aws configure' (or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY). Workshop attendees: see workshop/content/20-prerequisites/."
    # Without credentials the rest of the script cannot run — return early but
    # do NOT exit 1 directly; the EXIT trap in common-checks.sh emits the
    # summary and propagates the failure via `exit $?`.
    return 0 2>/dev/null || exit 0
fi

#-------------------------------------------------------------------------------
# Check 1: Base model agreement available
#-------------------------------------------------------------------------------
echo -e "${BLUE}[1/3] Base model agreement (${MODEL_ID})${NC}"
agreement_status=$(aws bedrock get-foundation-model-availability \
    --model-id "$MODEL_ID" \
    --region "$AWS_REGION" \
    --query 'agreementAvailability.status' \
    --output text 2>/dev/null || echo "ERROR")

if [ "$agreement_status" = "AVAILABLE" ]; then
    print_pass "Base model agreement is AVAILABLE"
else
    print_fail "Base model agreement is '${agreement_status}' (expected AVAILABLE)" \
        "Visit https://${AWS_REGION}.console.aws.amazon.com/bedrock/home?region=${AWS_REGION}#/modelaccess and request access for '${MODEL_ID}' (Anthropic Claude Sonnet 4.6). Approval is typically immediate for Anthropic models."
fi

#-------------------------------------------------------------------------------
# Check 2: Base model entitlement available
#-------------------------------------------------------------------------------
echo -e "${BLUE}[2/3] Base model entitlement (${MODEL_ID})${NC}"
entitlement_status=$(aws bedrock get-foundation-model-availability \
    --model-id "$MODEL_ID" \
    --region "$AWS_REGION" \
    --query 'entitlementAvailability' \
    --output text 2>/dev/null || echo "ERROR")

if [ "$entitlement_status" = "AVAILABLE" ]; then
    print_pass "Base model entitlement is AVAILABLE"
else
    print_fail "Base model entitlement is '${entitlement_status}' (expected AVAILABLE)" \
        "Entitlement reflects account-level access; if 'NOT_AVAILABLE' or 'PENDING', complete model access at https://${AWS_REGION}.console.aws.amazon.com/bedrock/home?region=${AWS_REGION}#/modelaccess. If status persists, contact AWS support — entitlement provisioning can lag behind agreement approval by a few minutes."
fi

#-------------------------------------------------------------------------------
# Check 3: Cross-region inference profile exists
#-------------------------------------------------------------------------------
echo -e "${BLUE}[3/3] Cross-region inference profile (${INFERENCE_PROFILE_ID})${NC}"
profile_id=$(aws bedrock list-inference-profiles \
    --region "$AWS_REGION" \
    --query "inferenceProfileSummaries[?inferenceProfileId=='${INFERENCE_PROFILE_ID}'].inferenceProfileId" \
    --output text 2>/dev/null || echo "")

if [ "$profile_id" = "$INFERENCE_PROFILE_ID" ]; then
    print_pass "Inference profile ${INFERENCE_PROFILE_ID} is provisioned"
else
    print_fail "Inference profile ${INFERENCE_PROFILE_ID} not found in ${AWS_REGION}" \
        "Cross-region inference profiles are auto-provisioned by AWS once the base model is granted. If still missing 10+ minutes after Check 1 passes, contact AWS support and reference inference profile id '${INFERENCE_PROFILE_ID}'. Alternative diagnostics: aws bedrock list-inference-profiles --region ${AWS_REGION} --query 'inferenceProfileSummaries[].inferenceProfileId'."
fi

# trap registered in common-checks.sh emits the summary
