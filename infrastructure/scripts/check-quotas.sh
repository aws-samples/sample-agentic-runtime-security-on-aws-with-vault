#!/usr/bin/env bash
#===============================================================================
# Pre-flight check: AWS service quotas (PREF-02)
#
# Verifies the four CONTEXT-locked quotas (CONTEXT.md line 94) in us-west-2:
#   1. EC2 Standard vCPU            — code L-1216C47A — required >= 32
#   2. VPC Elastic IPs              — code L-0263D0A3 — required >= 6
#   3. RDS DB instances per region  — code L-7B6409FD — required >= 1
#   4. AOSS OCU for indexing        — code L-CCD27F9D — required >= 2
#   5. AOSS OCU for search          — code L-A8E7DE8E — required >= 2
#
# Workshop Studio auto-requests these before account hand-off; this script
# verifies the request was applied. Each FAIL prints the exact AWS CLI command
# to request a quota increase.
#
# Per CONTEXT.md:
#   - Continue on failure (no set -e)
#   - Unicode markers (✓ PASS / ✗ FAIL / ⚠ WARN) via common-checks.sh
#   - Full inline copy-paste remediation per failure
#
# Service quota API returns floats (e.g., 32.0) so we compare with `bc -l`.
#
# Usage:
#   ./check-quotas.sh
#===============================================================================

# NOTE: NO `set -e` — continue-on-failure required (RESEARCH §Anti-pattern).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_PAGER=""

echo
echo -e "${BLUE}=== AWS Service Quotas (PREF-02) ===${NC}"
echo -e "  Region: ${AWS_REGION}"
echo

#-------------------------------------------------------------------------------
# Pre-flight: AWS credentials + bc
#-------------------------------------------------------------------------------
if ! command -v bc >/dev/null 2>&1; then
    print_fail "bc not installed (needed for float comparison)" \
        "macOS: bc is preinstalled. Linux: sudo apt-get install -y bc OR sudo yum install -y bc."
    exit 0
fi

if ! aws sts get-caller-identity --output text --query 'Account' >/dev/null 2>&1; then
    print_fail "AWS credentials not configured" \
        "Run 'aws configure' (or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)."
    exit 0
fi

#-------------------------------------------------------------------------------
# Helper: check_quota <label> <service-code> <quota-code> <required-min>
#
# Looks up the current applied quota and compares it (as a float) to the
# required minimum. On fail, prints the exact AWS CLI request-quota-increase
# command as remediation.
#-------------------------------------------------------------------------------
check_quota() {
    local label="$1"
    local service="$2"
    local code="$3"
    local required="$4"

    echo -e "${BLUE}[${label}] service=${service} quota=${code} required>=${required}${NC}"

    local current
    current=$(aws service-quotas get-service-quota \
        --service-code "$service" \
        --quota-code "$code" \
        --region "$AWS_REGION" \
        --query 'Quota.Value' \
        --output text 2>/dev/null)

    if [ -z "$current" ] || [ "$current" = "None" ]; then
        print_fail "${label}: failed to read current quota for ${service}/${code}" \
            "Quota code may have been rotated by AWS. Re-enumerate via: aws service-quotas list-service-quotas --service-code ${service} --region ${AWS_REGION} --query 'Quotas[].[QuotaCode,QuotaName,Value]' --output table"
        return
    fi

    # Float comparison via bc -l (returns 1 if true, 0 if false)
    local meets
    meets=$(echo "$current >= $required" | bc -l 2>/dev/null)
    if [ "$meets" = "1" ]; then
        print_pass "${label}: current=${current} (>= ${required})"
    else
        print_fail "${label}: current=${current}, required>=${required}" \
            "Request an increase: aws service-quotas request-service-quota-increase --region ${AWS_REGION} --service-code ${service} --quota-code ${code} --desired-value ${required}. Approval typically takes 15 minutes — 24 hours; for the workshop, contact your AWS account team if blocked."
    fi
}

#-------------------------------------------------------------------------------
# 1. EC2 Standard vCPU (Running On-Demand Standard A/C/D/H/I/M/R/T/Z)
#    Default account quota is typically 5 (new account) or 32+ (mature).
#    Workshop topology: EKS managed node group (m5/m6 family) + Karpenter
#    headroom + RDS host = ~28 vCPU peak. Requirement: 32.
#-------------------------------------------------------------------------------
check_quota "EC2 Standard vCPU"          ec2  L-1216C47A 32

#-------------------------------------------------------------------------------
# 2. VPC Elastic IPs per region
#    Default is 5; workshop needs 6 (3 NAT GW + 1 IVIA admin EIP + 2 spare for
#    re-deploys). Requirement: 6.
#-------------------------------------------------------------------------------
check_quota "VPC Elastic IPs"            ec2  L-0263D0A3 6

#-------------------------------------------------------------------------------
# 3. RDS DB instances per region
#    Default is 40, but CONTEXT mandates explicit verification.
#    Requirement: 1.
#-------------------------------------------------------------------------------
check_quota "RDS DB instances per region" rds L-7B6409FD 1

#-------------------------------------------------------------------------------
# 4. OpenSearch Serverless OCU — indexing
#    Default is 10 OCU; workshop KB needs 2 (1 indexing + 1 search; indexing
#    OCUs are consumed during embed-and-load). Requirement: 2.
#-------------------------------------------------------------------------------
check_quota "AOSS OCU (indexing)"        aoss L-CCD27F9D 2

#-------------------------------------------------------------------------------
# 5. OpenSearch Serverless OCU — search
#    Default is 10 OCU; workshop KB needs 2 search OCU at query time.
#    Requirement: 2.
#-------------------------------------------------------------------------------
check_quota "AOSS OCU (search)"          aoss L-A8E7DE8E 2

# trap registered in common-checks.sh emits the summary
