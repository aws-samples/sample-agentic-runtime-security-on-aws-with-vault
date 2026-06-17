#!/usr/bin/env bash
#===============================================================================
# seed-secrets.sh — bootstrap the three Instruqt org-level secrets the track
# references in instruqt/track/config.yml.tmpl.
#
# Prompts interactively for each secret value (never echoes input). Creates
# the secret if absent; updates it if already present (idempotent — safe to
# re-run when a value rotates). Aborts loud on any non-zero CLI exit.
#
# Required for an attendee track-play to succeed:
#   1. ICR_ENTITLEMENT_KEY            — IBM Container Registry entitlement key
#                                       (lets attendees pull IVIA images)
#   2. IVIA_MMFA_PUSH_SECRET          — IVIA MMFA push-provider client secret
#                                       (Use Case 3 mobile-push notifications)
#   3. INSTRUQT_GITHUB_IBM_DEPLOY_KEY — SSH private key (read-only) to clone
#                                       github.ibm.com/Oscar-Medina/agentic-
#                                       runtime-security-aws inside the sandbox
#
# Run BEFORE instruqt/scripts/push.sh — push will fail with the misleading
# "Entity not found" error until all three secrets exist on the team.
#===============================================================================

set -euo pipefail

# Resolve the active Instruqt team from the CLI config so this script can't
# silently target the wrong team (Bear, CLAUDE.md: never hardcode identity).
TEAM=$(instruqt config get team 2>/dev/null \
    | awk '/^[[:space:]]*team[[:space:]]*=/ {print $3}' \
    | tr -d '[:space:]')
if [[ -z "${TEAM}" ]]; then
    echo "FATAL: no Instruqt team configured. Run: instruqt auth login" >&2
    exit 1
fi

cat <<EOF

==> Instruqt secrets bootstrap

   Team:  ${TEAM}
   Track: agentic-runtime-security-aws (instruqt/track/config.yml.tmpl)

   This script will create / update three org-level secrets. Values are
   read silently (no echo) and passed to 'instruqt secrets create|update'
   via stdin / --data-file — never written to a log or to disk in plaintext.

EOF

read -r -p "Continue with team '${TEAM}'? [y/N] " CONFIRM
case "${CONFIRM}" in
    [yY]|[yY][eE][sS]) : ;;
    *) echo "Aborted."; exit 0 ;;
esac

# Cache the existing secret names ONCE so each idempotency check is a local
# lookup instead of a per-secret CLI roundtrip.
EXISTING_SECRETS=$(instruqt secrets list 2>/dev/null \
    | awk '/^[[:space:]]*[A-Z][A-Z0-9_]+[[:space:]]+[0-9]{4}-/ {print $1}')

# Strip the ANSI escape sequences the CLI emits around the NAME column.
EXISTING_SECRETS=$(printf '%s\n' "${EXISTING_SECRETS}" | sed -E 's/\x1b\[[0-9;]*[mGK]//g')

_secret_exists() {
    local name="$1"
    grep -Fxq "${name}" <<<"${EXISTING_SECRETS}"
}

# _upsert_secret NAME DESCRIPTION
#
# Prompts silently for the value, then routes to create or update depending
# on whether the secret already exists. Empty input aborts loudly (no silent
# accept-empty path that would clobber a good value with "").
_upsert_secret() {
    local name="$1" description="$2"
    local value=""

    printf '\n--- %s ---\n%s\n' "${name}" "${description}"
    read -r -s -p "Paste value for ${name} (input hidden): " value
    echo
    if [[ -z "${value}" ]]; then
        echo "FATAL: empty value for ${name}; aborting (re-run when you have it)." >&2
        exit 1
    fi

    if _secret_exists "${name}"; then
        echo "    Updating existing secret ${name}..."
        instruqt secrets update "${name}" "${value}" >/dev/null
    else
        echo "    Creating secret ${name}..."
        instruqt secrets create "${name}" "${value}" \
            --description "${description}" >/dev/null
    fi
    echo "    OK"
}

# _upsert_secret_from_file NAME DESCRIPTION
#
# Variant for multi-line values (e.g. an SSH private key PEM). Prompts for a
# file path, validates the file exists and is non-empty, then routes via
# --data-file so the value never appears in argv or env.
_upsert_secret_from_file() {
    local name="$1" description="$2"
    local path=""

    printf '\n--- %s ---\n%s\n' "${name}" "${description}"
    read -r -p "Path to file containing the value for ${name}: " path
    if [[ -z "${path}" || ! -s "${path}" ]]; then
        echo "FATAL: file '${path}' missing or empty for ${name}; aborting." >&2
        exit 1
    fi

    if _secret_exists "${name}"; then
        echo "    Updating existing secret ${name} from ${path}..."
        instruqt secrets update "${name}" --data-file "${path}" >/dev/null
    else
        echo "    Creating secret ${name} from ${path}..."
        instruqt secrets create "${name}" \
            --data-file "${path}" \
            --description "${description}" >/dev/null
    fi
    echo "    OK"
}

_upsert_secret ICR_ENTITLEMENT_KEY \
    "IBM Container Registry entitlement key — lets the workshop pull IVIA images from icr.io. Get one at myibm.ibm.com/products-services/containerlibrary."

_upsert_secret IVIA_MMFA_PUSH_SECRET \
    "IVIA MMFA push-provider client secret — used by Use Case 3 (CIBA mobile-push) to send Approve notifications via the IBM Verify mobile app."

_upsert_secret_from_file INSTRUQT_GITHUB_IBM_DEPLOY_KEY \
    "SSH private key (read-only) for cloning git@github.ibm.com:Oscar-Medina/agentic-runtime-security-aws.git. Add the matching .pub as a Deploy Key on the repo. Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/instruqt-deploy-key -C 'instruqt-readonly@agentic-runtime-security-aws' -N ''"

echo
echo "==> All three secrets in place on team '${TEAM}'."
echo "    Next step: bash instruqt/scripts/push.sh"
