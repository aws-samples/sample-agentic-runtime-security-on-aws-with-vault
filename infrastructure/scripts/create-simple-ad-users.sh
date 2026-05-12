#!/usr/bin/env bash
#===============================================================================
# create-simple-ad-users.sh — Provision workshop test users in AWS Simple AD
#
# Creates Oscar and Adriana in the Simple AD directory via LDAP. Called from
# configure-workshop.sh after Terraform deploys the Simple AD directory.
#
# Idempotent: ldapsearch before ldapadd — skips users that already exist.
#
# Prerequisites:
#   - ldap-utils installed (ldapadd, ldapsearch, ldapmodify)
#   - Network access to Simple AD DNS IPs on port 389
#
# Environment / flags:
#   --ldap-host HOST       Simple AD DNS IP (required)
#   --base-dn DN           LDAP base DN (default: DC=workshop,DC=internal)
#   --admin-password PWD   Administrator password (or SIMPLE_AD_ADMIN_PASSWORD env)
#   --dry-run              Show what would be done
#===============================================================================

set -e
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=common-checks.sh
source "$SCRIPT_DIR/common-checks.sh"

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
LDAP_HOST=""
BASE_DN="DC=workshop,DC=internal"
ADMIN_PASSWORD="${SIMPLE_AD_ADMIN_PASSWORD:-}"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --ldap-host)       LDAP_HOST="$2"; shift ;;
        --base-dn)         BASE_DN="$2"; shift ;;
        --admin-password)  ADMIN_PASSWORD="$2"; shift ;;
        --dry-run)         DRY_RUN=true ;;
        --help|-h)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

BIND_DN="CN=Administrator,CN=Users,${BASE_DN}"

if [ -z "$LDAP_HOST" ]; then
    print_fail "Missing --ldap-host (Simple AD DNS IP)"
    print_summary
    exit 1
fi
if [ -z "$ADMIN_PASSWORD" ]; then
    print_fail "Missing --admin-password or SIMPLE_AD_ADMIN_PASSWORD env var"
    print_summary
    exit 1
fi

#-------------------------------------------------------------------------------
# User definitions
#-------------------------------------------------------------------------------
declare -A USERS
USERS=(
    ["oscar"]="Oscar|Medina|Oscar Medina|oscar@workshop.internal"
    ["adriana"]="Adriana|Medina|Adriana Medina|adriana@workshop.internal"
)

#-------------------------------------------------------------------------------
# Create a user if it doesn't exist
#-------------------------------------------------------------------------------
create_user() {
    local username="$1"
    local given_name display_name mail
    IFS='|' read -r given_name sn display_name mail <<< "${USERS[$username]}"

    local user_dn="CN=${given_name},CN=Users,${BASE_DN}"

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would create user: ${username} (${display_name})"
        return 0
    fi

    if ldapsearch -x -H "ldap://${LDAP_HOST}" -b "$BASE_DN" \
        -D "$BIND_DN" -w "$ADMIN_PASSWORD" \
        "(sAMAccountName=${username})" dn 2>/dev/null | grep -q "^dn:"; then
        print_pass "User '${username}' already exists — skipping"
        return 0
    fi

    local ldif
    ldif=$(cat <<LDIF
dn: ${user_dn}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
cn: ${given_name}
sn: ${sn}
givenName: ${given_name}
displayName: ${display_name}
sAMAccountName: ${username}
userPrincipalName: ${username}@$(echo "$BASE_DN" | sed 's/DC=//g; s/,/./g')
mail: ${mail}
userAccountControl: 512
LDIF
    )

    if echo "$ldif" | ldapadd -x -H "ldap://${LDAP_HOST}" \
        -D "$BIND_DN" -w "$ADMIN_PASSWORD" 2>/dev/null; then
        print_pass "Created user '${username}' (${display_name})"
    else
        print_fail "Failed to create user '${username}'" \
            "Check LDAP connectivity: ldapsearch -x -H ldap://${LDAP_HOST} -D '${BIND_DN}' -w '<password>' -b '${BASE_DN}'"
        return 1
    fi

    local encoded_password
    encoded_password=$(python3 -c "import base64; print(base64.b64encode('\"WorkshopUser1!\"'.encode('utf-16-le')).decode())" 2>/dev/null)

    if [ -n "$encoded_password" ]; then
        local modify_ldif
        modify_ldif=$(cat <<MODLDIF
dn: ${user_dn}
changetype: modify
replace: unicodePwd
unicodePwd:: ${encoded_password}
MODLDIF
        )
        echo "$modify_ldif" | ldapmodify -x -H "ldap://${LDAP_HOST}" \
            -D "$BIND_DN" -w "$ADMIN_PASSWORD" 2>/dev/null \
            && print_pass "Set password for '${username}'" \
            || print_warn "Could not set password for '${username}' — Simple AD may require LDAPS for password changes"
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
echo
echo -e "${BLUE}=== Simple AD User Provisioning ===${NC}"
echo -e "  LDAP host: ${LDAP_HOST}"
echo -e "  Base DN:   ${BASE_DN}"
echo

for username in oscar adriana; do
    create_user "$username"
done

echo
print_summary
