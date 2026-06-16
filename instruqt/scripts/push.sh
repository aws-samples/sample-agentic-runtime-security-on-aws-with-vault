#!/usr/bin/env bash
#===============================================================================
# push.sh — ONLY supported way to push the Instruqt track.
#
# Wraps:
#   1. instruqt/scripts/render-config.sh   (regenerates instruqt/track/config.yml
#                                           from infrastructure/terraform.tfvars.example
#                                           via envsubst — see Decision 7).
#   2. cd instruqt/track && instruqt track push "$@"   (passes any flags through
#                                           to the Instruqt CLI, e.g., --force).
#
# Direct `instruqt track push` is NOT supported because it would push a stale
# (or missing) config.yml. Always go through this wrapper.
#
# Idempotent — re-running on the same workspace produces a no-op render + a
# regular `instruqt track push` (Instruqt itself handles the version bump).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRACK_DIR="${REPO_ROOT}/instruqt/track"

if ! command -v instruqt >/dev/null 2>&1; then
    echo "ERROR: instruqt CLI not found on PATH" >&2
    echo "Install per https://docs.instruqt.com/reference/cli/installation.md" >&2
    exit 1
fi

bash "${SCRIPT_DIR}/render-config.sh"

cd "${TRACK_DIR}"
echo "→ instruqt track push $*  (cwd: ${TRACK_DIR})"
instruqt track push "$@"

echo "OK: instruqt track push completed for $(basename "${TRACK_DIR}")"
