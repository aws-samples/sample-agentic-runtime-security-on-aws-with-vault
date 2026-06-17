#!/usr/bin/env bash
#===============================================================================
# render-config.sh — generate instruqt/track/config.yml from config.yml.tmpl.
#
# Extracts REGION_PRIMARY + REGION_KB at render-time from
# infrastructure/terraform.tfvars.example (today's single-source-of-truth per
# its file-header comment, lines 21-22) and substitutes them into the tracked
# template via envsubst.
#
# Per Decision 7 in 10-01-PLAN.md + CLAUDE.md region contract:
#   - config.yml.tmpl is TRACKED (no region literal)
#   - config.yml is GENERATED (gitignored, contains region literals)
#   - No AWS region literal ever appears in a tracked instruqt/ file.
#
# Idempotent — re-running produces the same byte-identical config.yml; safe to
# re-run end-to-end per project CLAUDE.md mandate.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TFVARS_EXAMPLE="${REPO_ROOT}/infrastructure/terraform.tfvars.example"
TMPL="${REPO_ROOT}/instruqt/track/config.yml.tmpl"
OUT="${REPO_ROOT}/instruqt/track/config.yml"

# Fail loud if any of the three inputs is missing — the canonical SoT MUST exist.
for required in "${TFVARS_EXAMPLE}" "${TMPL}"; do
    if [ ! -f "${required}" ]; then
        echo "ERROR: required input missing: ${required}" >&2
        echo "render-config.sh aborted — repo state is broken; cannot continue." >&2
        exit 1
    fi
done

# envsubst lives in gettext (Linux: apt install gettext-base; macOS: brew install gettext).
if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not found on PATH" >&2
    echo "Install: macOS \`brew install gettext && brew link --force gettext\` | Linux \`sudo apt-get install -y gettext-base\`" >&2
    exit 1
fi

# Parse the single-quoted-or-double-quoted region literal from the canonical SoT.
# The pattern matches a `region = "..."` or `kb_region = "..."` line,
# tolerating any amount of whitespace around the `=`.
_extract_region() {
    local key="$1" file="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" \
        | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

REGION_PRIMARY="$(_extract_region region "${TFVARS_EXAMPLE}")"
REGION_KB="$(_extract_region kb_region "${TFVARS_EXAMPLE}")"

if [ -z "${REGION_PRIMARY}" ]; then
    echo "ERROR: could not parse 'region = \"...\"' from ${TFVARS_EXAMPLE}" >&2
    echo "Single-source-of-truth file is malformed; fix it before re-running." >&2
    exit 1
fi
if [ -z "${REGION_KB}" ]; then
    echo "ERROR: could not parse 'kb_region = \"...\"' from ${TFVARS_EXAMPLE}" >&2
    echo "Single-source-of-truth file is malformed; fix it before re-running." >&2
    exit 1
fi

export REGION_PRIMARY REGION_KB
envsubst '${REGION_PRIMARY} ${REGION_KB}' < "${TMPL}" > "${OUT}"

echo "OK: rendered ${OUT} (REGION_PRIMARY=${REGION_PRIMARY}, REGION_KB=${REGION_KB})"
