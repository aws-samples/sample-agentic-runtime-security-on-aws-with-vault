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
# `instruqt config get team` returns the bare value with a trailing newline
# (verified empirically); just strip whitespace.
TEAM=$(instruqt config get team 2>/dev/null | tr -d '[:space:]')
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

# _ensure_deploy_key
#
# Idempotently ensure that:
#   1. an SSH ed25519 keypair exists at ${DEPLOY_KEY_PATH} (generate if absent)
#   2. its public half is registered as a READ-ONLY Deploy Key on the
#      github.ibm.com repo that the Instruqt sandbox clones from.
#
# Uses 'gh api' with GH_HOST=github.ibm.com so the call goes to the enterprise
# host, not github.com. Title is stable so re-runs converge:
#   - title present + same public key  -> no-op (idempotent)
#   - title present + different key    -> delete old, create new (rotation)
#   - title absent                     -> create
#
# Sets DEPLOY_KEY_PATH so the subsequent _upsert_secret_from_file call can
# default to it (Bear hits Enter, no path typing needed).
DEPLOY_KEY_PATH="${HOME}/.ssh/instruqt-deploy-key"
DEPLOY_REPO_OWNER="Oscar-Medina"
DEPLOY_REPO_NAME="agentic-runtime-security-aws"
DEPLOY_KEY_TITLE="instruqt-agentic-runtime-security-aws"
GHE_HOST="github.ibm.com"

_ensure_deploy_key() {
    if [[ ! -f "${DEPLOY_KEY_PATH}" ]]; then
        echo
        echo "--- SSH deploy key ---"
        echo "    No keypair at ${DEPLOY_KEY_PATH} — generating ed25519 (no passphrase)."
        ssh-keygen -t ed25519 \
            -f "${DEPLOY_KEY_PATH}" \
            -C "instruqt-readonly@${DEPLOY_REPO_NAME}" \
            -N '' >/dev/null
        chmod 600 "${DEPLOY_KEY_PATH}"
        echo "    OK: generated ${DEPLOY_KEY_PATH} + ${DEPLOY_KEY_PATH}.pub"
    else
        echo "    Reusing existing keypair at ${DEPLOY_KEY_PATH}"
    fi

    # Authenticated request against the enterprise host. gh inherits the
    # token from `gh auth login --hostname github.ibm.com` (Bear's standard
    # auth path — same flow as the IBM-host close-out rules).
    if ! GH_HOST="${GHE_HOST}" gh auth status --hostname "${GHE_HOST}" >/dev/null 2>&1; then
        echo "FATAL: gh is not authenticated against ${GHE_HOST}." >&2
        echo "    Run: gh auth login --hostname ${GHE_HOST}" >&2
        exit 1
    fi

    local pub_key existing_id existing_key
    pub_key="$(awk '{print $1" "$2}' "${DEPLOY_KEY_PATH}.pub")"

    # Look up an existing deploy key on the repo by our stable title.
    # gh api uses the same REST path as github.com so this is identical.
    local existing_json
    existing_json=$(GH_HOST="${GHE_HOST}" gh api \
        "repos/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/keys" \
        --jq ".[] | select(.title==\"${DEPLOY_KEY_TITLE}\") | {id, key}" 2>/dev/null || true)

    if [[ -n "${existing_json}" ]]; then
        existing_id=$(jq -r '.id' <<<"${existing_json}")
        existing_key=$(jq -r '.key' <<<"${existing_json}" | awk '{print $1" "$2}')
        if [[ "${existing_key}" == "${pub_key}" ]]; then
            echo "    Deploy key '${DEPLOY_KEY_TITLE}' already registered on ${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME} and matches local pub — no-op."
            return 0
        fi
        echo "    Deploy key '${DEPLOY_KEY_TITLE}' exists with a DIFFERENT public key — rotating."
        GH_HOST="${GHE_HOST}" gh api \
            "repos/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/keys/${existing_id}" \
            -X DELETE >/dev/null
    fi

    echo "    Registering ${DEPLOY_KEY_TITLE} as a read-only deploy key on ${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}..."
    GH_HOST="${GHE_HOST}" gh api \
        "repos/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/keys" \
        -f title="${DEPLOY_KEY_TITLE}" \
        -f key="$(cat "${DEPLOY_KEY_PATH}.pub")" \
        -F read_only=true >/dev/null
    echo "    OK: registered."
}

# _upsert_secret_from_file_default NAME DESCRIPTION DEFAULT_PATH
#
# Same as _upsert_secret_from_file but offers DEFAULT_PATH as the default if
# the user hits Enter. Used so the SSH key path doesn't have to be typed when
# _ensure_deploy_key just generated it.
_upsert_secret_from_file_default() {
    local name="$1" description="$2" default_path="$3"
    local path=""

    printf '\n--- %s ---\n%s\n' "${name}" "${description}"
    read -r -p "Path to file containing the value for ${name} [${default_path}]: " path
    path="${path:-${default_path}}"
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

_ensure_deploy_key

_upsert_secret ICR_ENTITLEMENT_KEY \
    "IBM Container Registry entitlement key — lets the workshop pull IVIA images from icr.io. Get one at myibm.ibm.com/products-services/containerlibrary."

_upsert_secret IVIA_MMFA_PUSH_SECRET \
    "IVIA MMFA push-provider client secret — used by Use Case 3 (CIBA mobile-push) to send Approve notifications via the IBM Verify mobile app."

_upsert_secret_from_file_default INSTRUQT_GITHUB_IBM_DEPLOY_KEY \
    "SSH private key (read-only) for cloning git@github.ibm.com:${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}.git inside the Instruqt sandbox. The matching .pub was registered as a deploy key in the previous step." \
    "${DEPLOY_KEY_PATH}"

echo
echo "==> All three secrets in place on team '${TEAM}'."
echo "    Next step: bash instruqt/scripts/push.sh"
