#!/usr/bin/env bash
#===============================================================================
# Workshop CLI Prerequisite Installer (companion to PREF-05)
#
# Auto-installs every CLI tool the workshop needs so attendees never install
# anything by hand. CONTEXT.md mandates auto-install over manual steps in
# 20-prerequisites/.
#
# Tools installed (matches PREF-05 docs):
#   - aws CLI v2
#   - terraform 1.10+         (HashiCorp apt repo on Linux, brew on macOS)
#   - vault   1.21.x          (HashiCorp apt repo on Linux, brew on macOS)
#   - kubectl 1.33.x          (Kubernetes apt repo on Linux, brew on macOS)
#   - helm    3.12+
#   - jq, yq
#
# Targets: macOS (Homebrew) + Linux (apt/yum). Windows users use WSL2.
#
# Usage:
#   ./install-prereqs.sh                # full install
#   ./install-prereqs.sh --dry-run      # detect OS and print plan; install nothing
#
# Behavior:
#   - `set -e` IS used here — installer scripts SHOULD fail fast on a broken
#     install (broken apt repo, missing package, etc.). This is OPPOSITE of
#     check-*.sh continue-on-failure.
#   - COMMON_CHECKS_SUMMARY=0 is exported BEFORE sourcing common-checks.sh so
#     the EXIT-trap "All checks passed" banner is suppressed. Otherwise a
#     `set -e` install abort would print a misleading green summary.
#   - Idempotent: skip already-installed tools.
#   - CI-safe: no interactive prompts (apt-get -y, brew install).
#===============================================================================

set -e

# Suppress common-checks.sh EXIT trap BEFORE sourcing
export COMMON_CHECKS_SUMMARY=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|--noop) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run]"
            echo
            echo "Auto-installs the workshop's CLI prerequisites."
            echo "  --dry-run   Detect OS and print install plan; install nothing."
            exit 0
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Tool versions (matches PREF-05 documentation)
#-------------------------------------------------------------------------------
KUBECTL_MAJOR_MINOR="1.33"  # Kubernetes apt repo URL uses major.minor form
HELM_MIN="3.12"
TERRAFORM_MIN="1.10"
VAULT_MIN="1.21"
AWS_CLI_MAJOR="2"

OS="$(uname -s)"
ARCH="$(uname -m)"

echo
echo -e "${BLUE}=== Workshop CLI Prerequisites Installer ===${NC}"
echo -e "  OS:           ${OS}"
echo -e "  Arch:         ${ARCH}"
echo -e "  Mode:         $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'INSTALL')"
echo

#-------------------------------------------------------------------------------
# DRY-RUN guard
# In dry-run mode we still detect OS, then print the plan and exit clean
# (without sourcing apt repos or running brew install).
#-------------------------------------------------------------------------------
run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
    else
        eval "$@"
    fi
}

#===============================================================================
# macOS (Homebrew)
#===============================================================================
install_macos() {
    if ! command -v brew >/dev/null 2>&1; then
        print_fail "Homebrew not found" \
            "Install from https://brew.sh — paste this in a terminal: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi

    print_info "Using Homebrew at: $(command -v brew)"

    # bash 5.x — newer than macOS system bash 3.2 (Pitfall §3); needed for
    # check-*.sh associative arrays and \x1f field separator.
    if ! brew list bash >/dev/null 2>&1; then
        print_info "Installing bash (5.x)"
        run "brew install bash"
    else
        print_info "bash already installed via Homebrew"
    fi

    # Standard tools
    for tool in awscli terraform helm jq yq vault; do
        if brew list "$tool" >/dev/null 2>&1; then
            print_info "${tool} already installed via Homebrew"
        else
            print_info "Installing ${tool}"
            run "brew install ${tool}"
        fi
    done

    # kubectl — install kubernetes-cli; verify version contains 1.33
    if command -v kubectl >/dev/null 2>&1 && \
       kubectl version --client --output=yaml 2>/dev/null | grep -q "${KUBECTL_MAJOR_MINOR}"; then
        print_info "kubectl ${KUBECTL_MAJOR_MINOR}.x already installed"
    else
        print_info "Installing kubectl (${KUBECTL_MAJOR_MINOR}.x)"
        run "brew install kubernetes-cli"
    fi
}

#===============================================================================
# Linux apt-based (Debian / Ubuntu)
#===============================================================================
install_linux_apt() {
    print_info "Using apt-get on $(lsb_release -ds 2>/dev/null || echo Linux)"

    # HashiCorp apt repo — provides terraform + vault
    if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
        print_info "Adding HashiCorp apt repo"
        run "curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
        run "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list"
    else
        print_info "HashiCorp apt repo already configured"
    fi

    # Kubernetes apt repo — provides kubectl ${KUBECTL_MAJOR_MINOR}.x
    if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
        print_info "Adding Kubernetes ${KUBECTL_MAJOR_MINOR} apt repo"
        run "sudo mkdir -p /etc/apt/keyrings"
        run "curl -fsSL \"https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/deb/Release.key\" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
        run "echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/deb/ /\" | sudo tee /etc/apt/sources.list.d/kubernetes.list"
    else
        print_info "Kubernetes apt repo already configured"
    fi

    # Helm baltocdn repo
    if [ ! -f /etc/apt/sources.list.d/helm-stable-debian.list ]; then
        print_info "Adding Helm apt repo"
        run "curl -fsSL https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg"
        run "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main\" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list"
    else
        print_info "Helm apt repo already configured"
    fi

    # apt-get update + install
    print_info "Refreshing apt indexes"
    run "sudo apt-get update -qq"
    print_info "Installing terraform, vault, kubectl, helm, jq, unzip, ca-certificates"
    run "sudo apt-get install -y -qq terraform vault kubectl helm jq unzip ca-certificates curl"

    # yq — direct binary from GitHub releases
    if ! command -v yq >/dev/null 2>&1; then
        print_info "Installing yq (direct binary from GitHub)"
        local arch_dpkg
        arch_dpkg=$(dpkg --print-architecture)
        run "sudo curl -fsSL \"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch_dpkg}\" -o /usr/local/bin/yq"
        run "sudo chmod +x /usr/local/bin/yq"
    else
        print_info "yq already installed"
    fi

    # AWS CLI v2 — official installer (apt has v1 only on most distros)
    if ! aws --version 2>/dev/null | grep -q "aws-cli/${AWS_CLI_MAJOR}"; then
        print_info "Installing AWS CLI v${AWS_CLI_MAJOR}"
        run "curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip\" -o /tmp/awscliv2.zip"
        run "unzip -q -o /tmp/awscliv2.zip -d /tmp"
        run "sudo /tmp/aws/install --update"
    else
        print_info "AWS CLI v${AWS_CLI_MAJOR} already installed"
    fi
}

#===============================================================================
# Linux yum-based (RHEL / Amazon Linux 2 / Rocky)
#
# Thinner implementation — RESEARCH §Open Question 4 prioritized apt-based
# distros + macOS. RHEL/Amazon Linux support: verify on first run.
#===============================================================================
install_linux_yum() {
    print_warn "RHEL/Amazon Linux support — verify on first run; reach for the apt path or macOS if anything fails."

    # HashiCorp yum repo
    if [ ! -f /etc/yum.repos.d/hashicorp.repo ]; then
        print_info "Adding HashiCorp yum repo"
        run "sudo yum install -y -q yum-utils"
        run "sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo"
    fi

    # Kubernetes yum repo
    if [ ! -f /etc/yum.repos.d/kubernetes.repo ]; then
        print_info "Adding Kubernetes ${KUBECTL_MAJOR_MINOR} yum repo"
        run "cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MAJOR_MINOR}/rpm/repodata/repomd.xml.key
EOF"
    fi

    print_info "Installing terraform, vault, kubectl, jq, unzip"
    run "sudo yum install -y -q terraform vault kubectl jq unzip"

    # helm — install script (no official yum repo)
    if ! command -v helm >/dev/null 2>&1; then
        print_info "Installing helm via get-helm-3 install script"
        run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    fi

    # yq, AWS CLI v2 — same as apt path
    if ! command -v yq >/dev/null 2>&1; then
        print_info "Installing yq (direct binary)"
        run "sudo curl -fsSL \"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64\" -o /usr/local/bin/yq"
        run "sudo chmod +x /usr/local/bin/yq"
    fi

    if ! aws --version 2>/dev/null | grep -q "aws-cli/${AWS_CLI_MAJOR}"; then
        print_info "Installing AWS CLI v${AWS_CLI_MAJOR}"
        run "curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip\" -o /tmp/awscliv2.zip"
        run "unzip -q -o /tmp/awscliv2.zip -d /tmp"
        run "sudo /tmp/aws/install --update"
    fi
}

#===============================================================================
# Dispatch on OS
#===============================================================================
case "$OS" in
    Darwin)
        install_macos
        ;;
    Linux)
        if command -v apt-get >/dev/null 2>&1; then
            install_linux_apt
        elif command -v yum >/dev/null 2>&1; then
            install_linux_yum
        else
            print_fail "Unsupported Linux distro (no apt-get, no yum)" \
                "Install kubectl/helm/terraform/vault/aws/jq/yq manually. See workshop/content/20-prerequisites/ for the full list."
            exit 1
        fi
        ;;
    *)
        print_fail "Unsupported OS: $OS" \
            "macOS and Linux only. Windows users: install WSL2 (Ubuntu 22.04+) and re-run this script inside WSL."
        exit 1
        ;;
esac

#-------------------------------------------------------------------------------
# Post-install verification
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}=== Installed versions ===${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[dry-run] Skipping version checks${NC}"
else
    kubectl version --client --output=yaml 2>/dev/null | grep -E '(gitVersion|clientVersion)' | head -2 || true
    terraform version | head -1
    vault version || true
    helm version --short
    aws --version
    jq --version
    yq --version
fi

echo
echo -e "${GREEN}===============================================================================${NC}"
echo -e "${GREEN} ✓ Workshop CLI prerequisites installed${NC}"
echo -e "${GREEN}===============================================================================${NC}"
echo
echo -e "Next steps:"
echo -e "  1. ${YELLOW}terraform login${NC}           (authenticate the terraform CLI to HCP Terraform)"
echo -e "  2. ${YELLOW}aws configure${NC}             (or set AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)"
echo -e "  3. ${YELLOW}./infrastructure/scripts/check-bedrock-access.sh${NC}"
echo -e "  4. ${YELLOW}./infrastructure/scripts/check-quotas.sh${NC}"
echo -e "  5. ${YELLOW}./infrastructure/scripts/check-permissions.sh${NC}"
echo -e "  6. ${YELLOW}./infrastructure/scripts/bootstrap.sh <HCP_ORG>${NC}"
echo
