#!/usr/bin/env bash
#===============================================================================
# seed-secrets.sh — author-side bootstrap for the Instruqt invite link.
#
# Per https://docs.instruqt.com/sandboxes/runtime/secrets.md, team-level
# `secrets:` can only be created by team Owners; this track author does NOT
# hold that role on hashicorp-field-ops. We therefore deliver confidential
# values to the sandbox via the invite link's Advanced options → +Runtime
# parameters UI instead of `secrets:`. The track config maps those to env
# vars consumed by track_scripts/setup-cloud-client.
#
# This script handles the two pieces that CAN be done from the author's
# laptop without the team-Owner role:
#
#   1. Generate an SSH ed25519 deploy keypair if one isn't already present
#      at ~/.ssh/instruqt-deploy-key.
#   2. Register the matching .pub as a READ-ONLY Deploy Key on
#      github.ibm.com/Oscar-Medina/agentic-runtime-security-aws via
#      `gh api`. Idempotent — same pub re-runs as a no-op; different pub
#      triggers a rotation (delete-old, create-new).
#
# After this script finishes, the operator pastes:
#   - the contents of ~/.ssh/instruqt-deploy-key (the PRIVATE key, multi-line)
#     into the invite link's Advanced options as runtime parameter
#     INSTRUQT_GITHUB_IBM_DEPLOY_KEY
#   - ICR_ENTITLEMENT_KEY and IVIA_MMFA_PUSH_SECRET values into the same
#     Advanced options panel
#
# See instruqt/README.md → "Invite link workflow" for the full operator flow.
#===============================================================================

set -euo pipefail

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
        echo "--- SSH deploy key ---"
        echo "    Reusing existing keypair at ${DEPLOY_KEY_PATH}"
    fi

    # Authenticated request against the enterprise host. gh inherits the token
    # from `gh auth login --hostname github.ibm.com` — same setup the
    # IBM-host close-out flow already requires.
    if ! GH_HOST="${GHE_HOST}" gh auth status --hostname "${GHE_HOST}" >/dev/null 2>&1; then
        echo "FATAL: gh is not authenticated against ${GHE_HOST}." >&2
        echo "    Run: gh auth login --hostname ${GHE_HOST}" >&2
        exit 1
    fi

    local pub_key existing_json existing_id existing_key
    pub_key="$(awk '{print $1" "$2}' "${DEPLOY_KEY_PATH}.pub")"

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

_ensure_deploy_key

cat <<EOF

==> Deploy key ready.

Next: create / edit the Instruqt invite link and paste ONE value into
Advanced options → +Runtime parameters (Add variable):

   INSTRUQT_GITHUB_IBM_DEPLOY_KEY  =  <full contents of ${DEPLOY_KEY_PATH}>

To pipe the private key to your clipboard for pasting:

   pbcopy < ${DEPLOY_KEY_PATH}

Invite link UI:
   https://play.instruqt.com/manage/$(instruqt config get team | tr -d '[:space:]')/tracks/${DEPLOY_REPO_NAME}/invites

After saving the invite, attendees use THAT specific invite URL (not the
generic published URL) so the SSH key gets injected as an env var into
track_scripts/setup-cloud-client.

LE_EMAIL / ICR_ENTITLEMENT_KEY / IVIA_MMFA_PUSH_SECRET are NOT pre-set
here — deploy-workshop.sh preflight prompts the attendee for them when
they run the tier-1 deploy from the Terminal tab, same flow as the
Workshop Studio distribution.
EOF
