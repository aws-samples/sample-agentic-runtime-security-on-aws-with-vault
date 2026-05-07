#!/usr/bin/env bash
#===============================================================================
# Workshop Pre-Flight (consolidated)
#
# Single entry-point that:
#   1. Installs missing CLI prereqs (kubectl 1.33.x, helm 3.12+, terraform 1.10+,
#      vault 1.21.x, aws v2, jq, yq) — macOS Homebrew or Linux apt/yum
#   2. Verifies Amazon Bedrock model access (anthropic.claude-sonnet-4-6 +
#      us.anthropic.claude-sonnet-4-6 inference profile) in us-west-2
#   3. Verifies AWS service quotas in us-west-2 (EC2 vCPU >= 32,
#      VPC EIP >= 6, RDS DB instances >= 1, AOSS OCU indexing >= 2,
#      AOSS OCU search >= 2)
#   4. Verifies IAM permissions for HCP Stacks bootstrap (17 actions via
#      iam:SimulatePrincipalPolicy with self-test fallback)
#
# Exit codes:
#   0 — all checks passed (or --dry-run completed without error)
#   1 — one or more failures (consolidated summary printed)
#
# Usage:
#   ./preflight.sh                 # default: auto-install + run all checks
#   ./preflight.sh --interactive   # prompt before each install + each check
#   ./preflight.sh --dry-run       # print actions without executing installs
#   ./preflight.sh --help          # usage
#
# Replaces (and consolidates) the previous 4 scripts:
#   install-prereqs.sh, check-bedrock-access.sh, check-quotas.sh,
#   check-permissions.sh — DELETED. See infrastructure/scripts/README.md.
#===============================================================================

# NOTE: NO `set -e` at the top level. The install section uses local set -e
# via subshell () so install failures abort the install but the check
# sections still run. Check sections accumulate failures into FAILURES[]
# and continue (CONTEXT.md mandate).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default mode: WORKSHOP_AUTO_YES=1 so confirm() returns 0 without prompting.
# --interactive UNSETS this so prompts appear. Set BEFORE sourcing
# common-checks.sh because the auto-yes branch in confirm() reads the var.
export WORKSHOP_AUTO_YES=1

DRY_RUN=false
INTERACTIVE=false

# Argument parsing — keep simple, no shift loops with positional args
for arg in "$@"; do
    case "$arg" in
        --interactive)    INTERACTIVE=true; unset WORKSHOP_AUTO_YES ;;
        --dry-run|--noop) DRY_RUN=true ;;
        --help|-h)
            cat <<USAGE
Usage: $0 [--interactive] [--dry-run] [--help]

Workshop pre-flight: installs CLI prereqs, then verifies Bedrock model access,
AWS service quotas, and IAM permissions for HCP Stacks bootstrap.

Modes:
  (no flags)        Default: auto-install missing CLIs (no per-tool prompts),
                    then run Bedrock + quotas + IAM checks straight through.
                    Failures accumulate into a consolidated summary at the end.
  --interactive     Prompt before each install AND before each check section
                    ("Install kubectl? [y/N]", "Run Bedrock check? [y/N]", ...).
  --dry-run         Print every install command prefixed [dry-run] without
                    executing. AWS read-only API calls (get-service-quota,
                    get-caller-identity, etc.) DO run live since they have no
                    side effects.
  --help, -h        Show this help and exit.
USAGE
            exit 0
            ;;
        *)
            echo -e "ERROR: unknown argument: $arg" >&2
            echo -e "Try: $0 --help" >&2
            exit 1
            ;;
    esac
done

# Source common-checks.sh AFTER setting WORKSHOP_AUTO_YES (the trap and
# confirm() rely on env). Suppress the EXIT-trap summary because we emit
# a single explicit summary at the end of preflight.sh ourselves
# (combining install + check failures).
export COMMON_CHECKS_SUMMARY=0
# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

# Workshop-locked model + region (CONTEXT.md decisions)
MODEL_ID="anthropic.claude-sonnet-4-6"
INFERENCE_PROFILE_ID="us.anthropic.claude-sonnet-4-6"
AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_PAGER=""

# ---- Banner ----
echo
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE} Workshop Pre-Flight${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo -e "  Mode:   $([ "$INTERACTIVE" = true ] && echo INTERACTIVE || echo DEFAULT)$([ "$DRY_RUN" = true ] && echo " + DRY-RUN")"
echo -e "  Region: ${AWS_REGION}"
echo

# ---- run() helper — gates install commands on $DRY_RUN ----
run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
    else
        eval "$@"
    fi
}

# =============================================================================
# SECTION 1: Install CLI tools
# =============================================================================
echo -e "${BLUE}=== Install CLI tools ===${NC}"

# Tool versions (matches PREF-05 documentation)
KUBECTL_MAJOR_MINOR="1.33"
AWS_CLI_MAJOR="2"

# Per-section gate (only matters in --interactive mode; auto-yes otherwise)
if confirm "Install / verify CLI tools (kubectl, helm, terraform, vault, aws, jq, yq)?"; then
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Darwin)
            # macOS Homebrew path — port from old install-prereqs.sh install_macos
            if ! command -v brew >/dev/null 2>&1; then
                print_fail "Homebrew not found" \
                    "Install from https://brew.sh — paste this in a terminal: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            else
                print_info "Using Homebrew at: $(command -v brew)"
                # bash 5.x — newer than macOS system bash 3.2 (Pitfall §3); needed for
                # check-*.sh associative arrays and \x1f field separator.
                if ! brew list bash >/dev/null 2>&1; then
                    if confirm "Install bash 5.x via Homebrew (newer than macOS system bash 3.2)?"; then
                        print_info "Installing bash"; run "brew install bash"
                    else
                        print_warn "Skipped bash install"
                    fi
                else
                    print_info "bash already installed"
                fi
                # Standard tools
                for tool in awscli terraform helm jq yq vault; do
                    if brew list "$tool" >/dev/null 2>&1; then
                        print_info "${tool} already installed"
                    else
                        if confirm "Install ${tool} via Homebrew?"; then
                            print_info "Installing ${tool}"; run "brew install ${tool}"
                        else
                            print_warn "Skipped ${tool} install"
                        fi
                    fi
                done
                # kubectl — install kubernetes-cli; verify version contains 1.33
                if command -v kubectl >/dev/null 2>&1 && \
                   kubectl version --client --output=yaml 2>/dev/null | grep -q "${KUBECTL_MAJOR_MINOR}"; then
                    print_info "kubectl ${KUBECTL_MAJOR_MINOR}.x already installed"
                else
                    if confirm "Install kubectl ${KUBECTL_MAJOR_MINOR}.x via Homebrew?"; then
                        print_info "Installing kubectl"; run "brew install kubernetes-cli"
                    else
                        print_warn "Skipped kubectl install"
                    fi
                fi
            fi
            ;;
        Linux)
            # Linux path — preserve apt + yum branches from old install-prereqs.sh
            if command -v apt-get >/dev/null 2>&1; then
                # ----- Linux apt-based (Debian / Ubuntu) -----
                print_info "Using apt-get on $(lsb_release -ds 2>/dev/null || echo Linux)"

                # HashiCorp apt repo — provides terraform + vault
                if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
                    if confirm "Add HashiCorp apt repo (provides terraform + vault)?"; then
                        print_info "Adding HashiCorp apt repo"
                        run "curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
                        run "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list"
                    else
                        print_warn "Skipped HashiCorp apt repo add"
                    fi
                else
                    print_info "HashiCorp apt repo already configured"
                fi

                # Kubernetes apt repo — provides kubectl ${KUBECTL_MAJOR_MINOR}.x
                if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
                    if confirm "Add Kubernetes ${KUBECTL_MAJOR_MINOR} apt repo (provides kubectl)?"; then
                        print_info "Adding Kubernetes ${KUBECTL_MAJOR_MINOR} apt repo"
                        run "sudo mkdir -p /etc/apt/keyrings"
                        run "curl -fsSL \"https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/deb/Release.key\" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
                        run "echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/deb/ /\" | sudo tee /etc/apt/sources.list.d/kubernetes.list"
                    else
                        print_warn "Skipped Kubernetes apt repo add"
                    fi
                else
                    print_info "Kubernetes apt repo already configured"
                fi

                # Helm baltocdn repo
                if [ ! -f /etc/apt/sources.list.d/helm-stable-debian.list ]; then
                    if confirm "Add Helm apt repo (provides helm)?"; then
                        print_info "Adding Helm apt repo"
                        run "curl -fsSL https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg"
                        run "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main\" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list"
                    else
                        print_warn "Skipped Helm apt repo add"
                    fi
                else
                    print_info "Helm apt repo already configured"
                fi

                # apt-get update + install
                if confirm "Refresh apt indexes and install terraform/vault/kubectl/helm/jq/unzip/ca-certificates/curl?"; then
                    print_info "Refreshing apt indexes"
                    run "sudo apt-get update -qq"
                    print_info "Installing terraform, vault, kubectl, helm, jq, unzip, ca-certificates"
                    run "sudo apt-get install -y -qq terraform vault kubectl helm jq unzip ca-certificates curl"
                else
                    print_warn "Skipped apt-get update + batch install"
                fi

                # yq — direct binary from GitHub releases
                if ! command -v yq >/dev/null 2>&1; then
                    if confirm "Install yq (direct binary from GitHub)?"; then
                        print_info "Installing yq (direct binary from GitHub)"
                        arch_dpkg=$(dpkg --print-architecture)
                        run "sudo curl -fsSL \"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch_dpkg}\" -o /usr/local/bin/yq"
                        run "sudo chmod +x /usr/local/bin/yq"
                    else
                        print_warn "Skipped yq install"
                    fi
                else
                    print_info "yq already installed"
                fi

                # AWS CLI v2 — official installer (apt has v1 only on most distros)
                if ! aws --version 2>/dev/null | grep -q "aws-cli/${AWS_CLI_MAJOR}"; then
                    if confirm "Install AWS CLI v${AWS_CLI_MAJOR} (official installer)?"; then
                        print_info "Installing AWS CLI v${AWS_CLI_MAJOR}"
                        run "curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip\" -o /tmp/awscliv2.zip"
                        run "unzip -q -o /tmp/awscliv2.zip -d /tmp"
                        run "sudo /tmp/aws/install --update"
                    else
                        print_warn "Skipped AWS CLI v${AWS_CLI_MAJOR} install"
                    fi
                else
                    print_info "AWS CLI v${AWS_CLI_MAJOR} already installed"
                fi
            elif command -v yum >/dev/null 2>&1; then
                # ----- Linux yum-based (RHEL / Amazon Linux 2 / Rocky) -----
                print_warn "RHEL/Amazon Linux support — verify on first run; reach for the apt path or macOS if anything fails."

                # HashiCorp yum repo
                if [ ! -f /etc/yum.repos.d/hashicorp.repo ]; then
                    if confirm "Add HashiCorp yum repo (provides terraform + vault)?"; then
                        print_info "Adding HashiCorp yum repo"
                        run "sudo yum install -y -q yum-utils"
                        run "sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo"
                    else
                        print_warn "Skipped HashiCorp yum repo add"
                    fi
                fi

                # Kubernetes yum repo
                if [ ! -f /etc/yum.repos.d/kubernetes.repo ]; then
                    if confirm "Add Kubernetes ${KUBECTL_MAJOR_MINOR} yum repo (provides kubectl)?"; then
                        print_info "Adding Kubernetes ${KUBECTL_MAJOR_MINOR} yum repo"
                        run "cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/rpm/repodata/repomd.xml.key
EOF"
                    else
                        print_warn "Skipped Kubernetes yum repo add"
                    fi
                fi

                if confirm "yum install terraform/vault/kubectl/jq/unzip?"; then
                    print_info "Installing terraform, vault, kubectl, jq, unzip"
                    run "sudo yum install -y -q terraform vault kubectl jq unzip"
                else
                    print_warn "Skipped yum batch install"
                fi

                # helm — install script (no official yum repo)
                if ! command -v helm >/dev/null 2>&1; then
                    if confirm "Install helm via get-helm-3 install script?"; then
                        print_info "Installing helm via get-helm-3 install script"
                        run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
                    else
                        print_warn "Skipped helm install"
                    fi
                fi

                # yq, AWS CLI v2 — same as apt path
                if ! command -v yq >/dev/null 2>&1; then
                    if confirm "Install yq (direct binary)?"; then
                        print_info "Installing yq (direct binary)"
                        run "sudo curl -fsSL \"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64\" -o /usr/local/bin/yq"
                        run "sudo chmod +x /usr/local/bin/yq"
                    else
                        print_warn "Skipped yq install"
                    fi
                fi

                if ! aws --version 2>/dev/null | grep -q "aws-cli/${AWS_CLI_MAJOR}"; then
                    if confirm "Install AWS CLI v${AWS_CLI_MAJOR}?"; then
                        print_info "Installing AWS CLI v${AWS_CLI_MAJOR}"
                        run "curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip\" -o /tmp/awscliv2.zip"
                        run "unzip -q -o /tmp/awscliv2.zip -d /tmp"
                        run "sudo /tmp/aws/install --update"
                    else
                        print_warn "Skipped AWS CLI v${AWS_CLI_MAJOR} install"
                    fi
                fi
            else
                print_fail "Unsupported Linux distro (no apt-get, no yum)" \
                    "Install kubectl/helm/terraform/vault/aws/jq/yq manually."
            fi
            ;;
        *)
            print_fail "Unsupported OS: $OS" \
                "macOS and Linux only — Windows users use WSL2."
            ;;
    esac
else
    print_warn "Skipped CLI install section"
fi

echo

# =============================================================================
# SECTION 2: Check Bedrock access (PREF-01)
#
# Three checks (ported verbatim from deleted check-bedrock-access.sh):
#   1. Base model agreement available (foundation-model-availability:
#      agreementAvailability.status == AVAILABLE)
#   2. Base model entitlement available (entitlementAvailability == AVAILABLE)
#   3. Cross-region inference profile us.anthropic.claude-sonnet-4-6 exists
# =============================================================================
echo -e "${BLUE}=== Check Bedrock access ===${NC}"
echo -e "  Region:            ${AWS_REGION}"
echo -e "  Model:             ${MODEL_ID}"
echo -e "  Inference Profile: ${INFERENCE_PROFILE_ID}"
echo

if confirm "Run Bedrock model access check (anthropic.claude-sonnet-4-6)?"; then
    # Pre-flight: AWS credentials
    if ! aws sts get-caller-identity --output text --query 'Account' >/dev/null 2>&1; then
        print_fail "AWS credentials not configured" \
            "Run 'aws configure' (or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY). Workshop attendees: see workshop/content/20-prerequisites/."
    else
        # Check 1: Base model agreement available
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

        # Check 2: Base model entitlement available
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

        # Check 3: Cross-region inference profile exists
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
    fi
else
    print_warn "Skipped Bedrock access check"
fi

echo

# =============================================================================
# SECTION 3: Check AWS service quotas (PREF-02)
#
# GAP 3 FIXES APPLIED:
#   - Corrected AOSS indexing code to L-50FA809B (Default indexing MAX OCU = 10.0)
#   - Corrected AOSS search code to L-4E98D4EB (Default search MAX OCU = 10.0)
#     (the previously-shipped fabricated codes are deliberately not enumerated
#      here so a future grep cannot reintroduce them by copy/paste)
#   - Runtime validation gate: assert every configured code exists in
#     `aws service-quotas list-service-quotas --service-code <svc>` BEFORE
#     the per-quota loop runs. FAIL-fast with the documented remediation
#     if any code is unknown.
#   - AWS CLI stderr captured (no longer hidden behind 2>/dev/null) and
#     surfaced in FAIL message.
# =============================================================================
echo -e "${BLUE}=== Check AWS service quotas ===${NC}"

if confirm "Run AWS service quotas check?"; then
    # ---- Pre-flight: bc + AWS creds ----
    if ! command -v bc >/dev/null 2>&1; then
        print_fail "bc not installed (needed for float comparison)" \
            "macOS: bc is preinstalled. Linux: sudo apt-get install -y bc OR sudo yum install -y bc."
    elif ! aws sts get-caller-identity --output text --query 'Account' >/dev/null 2>&1; then
        print_fail "AWS credentials not configured" \
            "Run 'aws configure' (or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)."
    else
        # ---- GAP 3 RUNTIME VALIDATION GATE ----
        # Before any check_quota call, validate every configured code exists.
        # Replaces the executor-time validation gate (which was skipped during
        # plan 01-04 execution) with runtime enforcement.
        print_info "Validating quota codes against live AWS Service Quotas catalog..."
        _val_failed=false
        for pair in ec2:L-1216C47A ec2:L-0263D0A3 rds:L-7B6409FD aoss:L-50FA809B aoss:L-4E98D4EB; do
            svc="${pair%%:*}"; code="${pair##*:}"
            # Capture stderr to surface AWS errors (e.g., NoSuchResourceException)
            if ! val_stderr=$(aws service-quotas get-service-quota \
                    --service-code "$svc" \
                    --quota-code "$code" \
                    --region "$AWS_REGION" \
                    --query 'Quota.QuotaName' \
                    --output text 2>&1 >/dev/null); then
                print_fail "Quota code ${svc}/${code} not in AWS catalog: ${val_stderr}" \
                    "Re-enumerate via: aws service-quotas list-service-quotas --service-code ${svc} --region ${AWS_REGION} --query 'Quotas[].[QuotaCode,QuotaName,Value]' --output table — then update preflight.sh with the correct code. This validation gate prevents check failures from masking fabricated codes (UAT Gap 3, plan 01-04 process defect)."
                _val_failed=true
            fi
        done

        if [ "$_val_failed" = false ]; then
            print_pass "All 5 quota codes are valid in AWS Service Quotas catalog"

            # Per-call stderr file (cleaned up at end of section)
            err_file=$(mktemp)

            # ---- Helper: check_quota <label> <service-code> <quota-code> <required-min> ----
            # Stderr capture (Gap 3 fix): surface AWS CLI error in FAIL message
            # instead of hiding behind 2>/dev/null.
            check_quota() {
                local label="$1"
                local service="$2"
                local code="$3"
                local required="$4"

                echo -e "${BLUE}[${label}] service=${service} quota=${code} required>=${required}${NC}"

                local current err
                # Run AWS CLI capturing stdout AND stderr separately so we can
                # surface the stderr in the FAIL message.
                current=$(aws service-quotas get-service-quota \
                    --service-code "$service" \
                    --quota-code "$code" \
                    --region "$AWS_REGION" \
                    --query 'Quota.Value' \
                    --output text 2>"$err_file")
                err=$(cat "$err_file" 2>/dev/null)

                if [ -z "$current" ] || [ "$current" = "None" ]; then
                    print_fail "${label}: failed to read current quota for ${service}/${code} (AWS CLI: ${err:-no stderr})" \
                        "Re-enumerate: aws service-quotas list-service-quotas --service-code ${service} --region ${AWS_REGION}. If the code rotated, update preflight.sh."
                    return
                fi

                local meets
                meets=$(echo "$current >= $required" | bc -l 2>/dev/null)
                if [ "$meets" = "1" ]; then
                    print_pass "${label}: current=${current} (>= ${required})"
                else
                    print_fail "${label}: current=${current}, required>=${required}" \
                        "Request increase: aws service-quotas request-service-quota-increase --region ${AWS_REGION} --service-code ${service} --quota-code ${code} --desired-value ${required}. Approval typically takes 15 min — 24 h."
                fi
            }

            # ---- 5 quota checks (CORRECTED AOSS CODES) ----
            # 1. EC2 Standard vCPU (Running On-Demand Standard A/C/D/H/I/M/R/T/Z)
            #    Default account quota is typically 5 (new account) or 32+ (mature).
            #    Workshop topology: EKS managed node group + Karpenter headroom +
            #    RDS host = ~28 vCPU peak. Requirement: 32.
            check_quota "EC2 Standard vCPU"           ec2  L-1216C47A 32
            # 2. VPC Elastic IPs per region — default 5; workshop needs 6 (3 NAT GW
            #    + 1 IVIA admin EIP + 2 spare for re-deploys).
            check_quota "VPC Elastic IPs"             ec2  L-0263D0A3 6
            # 3. RDS DB instances per region — default 40, but explicit verify.
            check_quota "RDS DB instances per region" rds  L-7B6409FD 1
            # 4. AOSS OCU indexing — default 10; workshop KB needs 2.
            check_quota "AOSS OCU (indexing)"         aoss L-50FA809B 2
            # 5. AOSS OCU search — default 10; workshop KB needs 2 at query time.
            check_quota "AOSS OCU (search)"           aoss L-4E98D4EB 2

            rm -f "$err_file"
        fi
    fi
else
    print_warn "Skipped service quotas check"
fi

echo

# =============================================================================
# SECTION 4: Check IAM permissions (PREF-03)
#
# Ported verbatim from deleted check-permissions.sh:
#   - caller identity → assumed-role rewrite
#   - simulator self-test fallback (Pitfall §7)
#   - 17-action batch simulation
# =============================================================================
echo -e "${BLUE}=== Check IAM permissions ===${NC}"

if confirm "Run IAM permissions check (iam:SimulatePrincipalPolicy)?"; then
    # Step 1 — derive PRINCIPAL_ARN
    RAW_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)

    if [ -z "$RAW_ARN" ] || [ "$RAW_ARN" = "None" ]; then
        print_fail "Could not resolve caller identity" \
            "Run 'aws configure' or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY. If using AWS SSO: 'aws sso login --profile <profile>'."
    else
        # Step 2 — assumed-role -> underlying IAM role rewrite
        # Mirrors reference bootstrap.sh lines 286-303: simulate-principal-policy
        # requires an IAM ARN (role/user), not an STS assumed-role ARN.
        if [[ "$RAW_ARN" == *":assumed-role/"* ]]; then
            ROLE_NAME=$(echo "$RAW_ARN" | sed 's|.*assumed-role/\([^/]*\)/.*|\1|')
            PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
            print_info "Caller is assumed-role; using underlying IAM role ARN: ${PRINCIPAL_ARN}"
        else
            PRINCIPAL_ARN="$RAW_ARN"
            print_info "Principal ARN: ${PRINCIPAL_ARN}"
        fi
        echo

        # Step 3 — self-test the simulator (Pitfall §7)
        # If the calling principal can't even simulate itself for sts:GetCallerIdentity,
        # the simulator is unavailable — emit WARN and skip the action loop.
        echo -e "${BLUE}[Self-test] iam:SimulatePrincipalPolicy availability${NC}"
        selftest=$(aws iam simulate-principal-policy \
            --policy-source-arn "$PRINCIPAL_ARN" \
            --action-names "sts:GetCallerIdentity" \
            --query 'EvaluationResults[0].EvalDecision' \
            --output text 2>/dev/null || echo "ERROR")

        if [ "$selftest" = "ERROR" ] || [ "$selftest" = "" ] || [ "$selftest" = "None" ]; then
            print_warn "iam:SimulatePrincipalPolicy unavailable — falling back to heuristic"
            print_info "The calling principal cannot simulate-principal-policy on itself. This is common for SSO/federated/restricted principals. Skipping action-loop verification — proceed and rely on bootstrap.sh / Stacks deploys to surface real permission failures."
        else
            print_pass "Simulator is available (self-test EvalDecision=${selftest})"
            echo

            # Step 4 — required actions
            # Stacks bootstrap-time IAM actions. 17 actions total — well under the
            # simulator's 100-action API limit.
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
            else
                # Iterate over the simulator output (tab-separated).
                while IFS=$'\t' read -r action decision; do
                    if [ "$decision" = "allowed" ]; then
                        print_pass "${action}: allowed"
                    else
                        print_fail "${action}: ${decision}" \
                            "Attach a policy granting ${action} to ${PRINCIPAL_ARN}, or use AWS managed policy AdministratorAccess for the workshop. Workshop pedagogical scope = Admin; production deployments use the scoped least-privilege policy in infrastructure/scripts/hcp-setup."
                    fi
                done <<< "$sim_out"
            fi
        fi
    fi
else
    print_warn "Skipped IAM permissions check"
fi

echo

# =============================================================================
# Final summary (combine install + check failures)
# =============================================================================
print_summary
summary_exit=$?
[ "$DRY_RUN" = true ] && exit 0
exit "$summary_exit"
