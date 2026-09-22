#!/usr/bin/env bash
#===============================================================================
# infrastructure/scripts/test-vault-alias-gate.sh
#
# Offline behaviour test for the Vault OAuth entity-alias sweep and gate
# (issue #5).
#
# Vault enforces (issuer, external_id) UNIQUE per namespace for an identity
# entity alias. The workshop's TLS host names embed the ALB's IP, so every host
# change replaces the oauth-resource-server profile and strands that generation's
# aliases in Vault forever — harmless until an ALB is re-created and handed an
# address it held before, at which point the stranded alias squats the exact
# (issuer, external_id) the new profile needs and all four alias writes fail with
# 400. vault-configure.sh answers that by sweeping the stranded generation before
# the apply and then asserting, against Vault rather than against Terraform state,
# that every identity really does have an alias at the live profile.
#
# That collision has been observed exactly once on a live cluster and cannot be
# provoked on demand — it needs AWS to hand back a specific IP address. This test
# drives the sweep and the gate against a MODELLED Vault instead: no cluster, no
# port-forward, no AWS.
#
# It does NOT copy the code under test. It extracts the REAL functions out of
# vault-configure.sh at runtime, by anchor, and fails loudly if it cannot find
# them — a copy silently goes stale and then certifies code that is no longer
# shipped.
#
# The model of Vault is the oracle; the TRANSPORT is stubbed twice, because the
# transport is itself one of the things under test. vault_exec (kubectl exec) and
# curl (the 127.0.0.1:8200 port-forward) both answer out of the same modelled
# state, and the port-forward can be taken down independently of Vault. That is
# what lets scenario 8 show the older, curl-based sweep going silently blind on a
# cluster where Vault is perfectly healthy.
#
# Usage:
#   bash infrastructure/scripts/test-vault-alias-gate.sh
#
# To prove a case actually fails without the fix in place, point it at an older
# copy of the script:
#   VAULT_CONFIGURE_SCRIPT=/tmp/old-vault-configure.sh \
#     bash infrastructure/scripts/test-vault-alias-gate.sh
#===============================================================================
# The stubs below are invoked INDIRECTLY — by the code extracted out of
# vault-configure.sh and sourced at runtime. ShellCheck cannot see that call
# graph, so it reports live stubs as dead (SC2329) and live fixtures as unused
# (SC2034); SC1091 is the generated files it is asked to follow.
# shellcheck disable=SC2329,SC2034,SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the suite can be pointed at an older copy of vault-configure.sh
# to prove a regression assertion actually fails without the fix in place.
VAULT_CONFIGURE_SCRIPT="${VAULT_CONFIGURE_SCRIPT:-${SCRIPT_DIR}/vault-configure.sh}"
VAULT_VERIFY_SCRIPT="${VAULT_VERIFY_SCRIPT:-${SCRIPT_DIR}/test-vault-verify.sh}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASSED=0; FAILED=0
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

fatal() { echo -e "${RED}FATAL:${NC} $*" >&2; exit 2; }
assert() {
    local what="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo -e "    ${GREEN}✓${NC} ${what}"; PASSED=$(( PASSED + 1 ))
    else
        echo -e "    ${RED}✗${NC} ${what}"
        echo -e "        expected: ${expected}"
        echo -e "        actual:   ${actual}"
        FAILED=$(( FAILED + 1 ))
    fi
}

#-- 1. Extract the code under test, live -------------------------------------
[ -f "${VAULT_CONFIGURE_SCRIPT}" ] || fatal "vault-configure.sh not found at ${VAULT_CONFIGURE_SCRIPT}"

# Each function: from its definition line to the first column-0 closing brace.
_extract() {
    local fn="$1" out="$2"
    awk -v fn="^${fn}\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f{print} f&&/^\}/{exit}' \
        "${VAULT_CONFIGURE_SCRIPT}" > "${out}"
}

_extract heal_orphan_oauth_aliases   "${WORK}/sweep.sh"
_extract assert_oauth_aliases_current "${WORK}/gate.sh"
# Present only from the fix onwards. An older copy of vault-configure.sh inlines
# the same jq into the gate and has no helper, so its absence is expected when
# the suite is pointed at a baseline — not a fatal.
_extract _workshop_oauth_expected_aliases "${WORK}/expected.sh"

grep -q '^heal_orphan_oauth_aliases() {' "${WORK}/sweep.sh" \
    || fatal "could not extract heal_orphan_oauth_aliases() from ${VAULT_CONFIGURE_SCRIPT} (was it renamed?)"
grep -q '^}' "${WORK}/sweep.sh" \
    || fatal "extracted heal_orphan_oauth_aliases() is not closed — extraction is wrong"
grep -q '^assert_oauth_aliases_current() {' "${WORK}/gate.sh" \
    || fatal "could not extract assert_oauth_aliases_current() from ${VAULT_CONFIGURE_SCRIPT} (was it renamed?)"
grep -q '^}' "${WORK}/gate.sh" \
    || fatal "extracted assert_oauth_aliases_current() is not closed — extraction is wrong"
# Prove the extraction stopped where it should: neither body may drag in the
# next function definition that follows it in the file.
grep -qE '^(activate_oauth_resource_server|phase_ivia_verify|vault_exec)\(\) \{' "${WORK}/sweep.sh" \
    && fatal "the extracted sweep ran past its closing brace into the next function"
grep -qE '^(phase_ivia_verify|vault_exec)\(\) \{' "${WORK}/gate.sh" \
    && fatal "the extracted gate ran past its closing brace into the next function"

#-- 2. Model Vault -----------------------------------------------------------
# One file is the whole of Vault's relevant state. Both transports read it, so a
# scenario is written once and judged the same way whichever transport the code
# under test happens to use.
#
#   ALIASES  one alias per line: id|name|mount_accessor|issuer|canonical_id
#   PROFILE  the live oauth-resource-server config_id ("" = no profile yet)
#   ISSUER   the live profile's issuer_id
#   VAULT_UP whether Vault answers at all
#   PF_UP    whether the 127.0.0.1:8200 port-forward is bound
#   DELFAIL  alias ids whose DELETE is refused
#   TFOUT    terraform output -json
#   TFRC     the exit code that terraform stub returns
ALIASES="${WORK}/aliases"; PROFILE="${WORK}/profile"; ISSUER="${WORK}/issuer"
VAULT_UP="${WORK}/vault_up"; PF_UP="${WORK}/pf_up"; DELFAIL="${WORK}/delfail"
TFOUT="${WORK}/tfout.json"; DELETED="${WORK}/deleted"; TFRC="${WORK}/tfrc"

_alias_json() {   # <id>
    local id="$1" line
    line="$(grep "^${id}|" "${ALIASES}" 2>/dev/null | head -1)" || true
    [[ -z "${line}" ]] && return 1
    local name acc iss can
    name="$(cut -d'|' -f2 <<<"${line}")"; acc="$(cut -d'|' -f3 <<<"${line}")"
    iss="$(cut -d'|' -f4 <<<"${line}")";  can="$(cut -d'|' -f5 <<<"${line}")"
    printf '{"data":{"id":"%s","name":"%s","mount_accessor":"%s","issuer":"%s","canonical_id":"%s"}}\n' \
        "${id}" "${name}" "${acc}" "${iss}" "${can}"
}
_alias_ids() { cut -d'|' -f1 "${ALIASES}" 2>/dev/null | grep -v '^$' || true; }
_ids_json() {
    local ids first=1 out="["
    ids="$(_alias_ids)"
    [[ -z "${ids}" ]] && return 1
    while IFS= read -r i; do
        [[ -z "${i}" ]] && continue
        [[ ${first} -eq 0 ]] && out="${out},"
        out="${out}\"${i}\""; first=0
    done <<<"${ids}"
    echo "${out}]"
}
_profile_json() {
    local id iss
    id="$(cat "${PROFILE}")"; iss="$(cat "${ISSUER}")"
    [[ -z "${id}" ]] && return 2
    printf '{"data":{"config_id":"%s","issuer_id":"%s"}}\n' "${id}" "${iss}"
}
_do_delete() {    # <id>
    local id="$1"
    grep -qx "${id}" "${DELFAIL}" 2>/dev/null && return 1
    grep -q "^${id}|" "${ALIASES}" 2>/dev/null || return 1
    grep -v "^${id}|" "${ALIASES}" > "${ALIASES}.tmp" 2>/dev/null || true
    mv "${ALIASES}.tmp" "${ALIASES}"
    echo "${id}" >> "${DELETED}"
    return 0
}

# Transport A: kubectl exec. What the fixed sweep and the gate use.
vault_exec() {
    local cmd="$1"
    [[ "$(cat "${VAULT_UP}")" == yes ]] || return 1
    case "${cmd}" in
        *"vault status"*)                                   echo '{"sealed":false}'; return 0 ;;
        *"sys/config/oauth-resource-server/ivia"*)          _profile_json; return $? ;;
        # The gate asks for every alias in one shell loop. Answer it the same way
        # a Vault pod would: one JSON object per alias, concatenated.
        *"for i in "*"identity/entity-alias/id"*)
            local i
            for i in $(_alias_ids); do _alias_json "${i}"; done
            return 0 ;;
        *"vault list"*"identity/entity-alias/id"*)          _ids_json; return $? ;;
        *"vault delete identity/entity-alias/id/"*)
            _do_delete "${cmd##*identity/entity-alias/id/}"; return $? ;;
        *"vault read"*"identity/entity-alias/id/"*)
            _alias_json "${cmd##*identity/entity-alias/id/}"; return $? ;;
    esac
    return 1
}
vault_pod() { [[ "$(cat "${VAULT_UP}")" == yes ]] && echo vault-0 || return 1; }

# Transport B: the 127.0.0.1:8200 port-forward. What the PRE-FIX sweep used, and
# the reason scenario 8 exists — it can be down while Vault itself is healthy.
curl() {
    local url="" method=GET a
    for a in "$@"; do
        case "${a}" in
            http://127.0.0.1:8200/*) url="${a}" ;;
            LIST|DELETE)             method="${a}" ;;
        esac
    done
    [[ -z "${url}" ]] && return 1
    [[ "$(cat "${PF_UP}")" == yes ]] || return 7        # curl(7): failed to connect
    [[ "$(cat "${VAULT_UP}")" == yes ]] || return 22    # curl(22): HTTP error
    local path="${url#http://127.0.0.1:8200/v1/}"
    case "${method}:${path}" in
        GET:sys/config/oauth-resource-server/ivia)
            _profile_json >/dev/null 2>&1 || return 22
            _profile_json; return 0 ;;
        LIST:identity/entity-alias/id)
            local ids json; ids="$(_alias_ids)"
            [[ -z "${ids}" ]] && return 22
            json="$(tr '\n' ' ' <<<"${ids}" | sed 's/ $//' | sed 's/ /","/g')"
            printf '{"data":{"keys":["%s"]}}\n' "${json}"; return 0 ;;
        DELETE:identity/entity-alias/id/*)
            _do_delete "${path##*/}" || return 22
            return 0 ;;
        GET:identity/entity-alias/id/*)
            _alias_json "${path##*/}" || return 22
            return 0 ;;
    esac
    return 22
}

# TFRC lets a scenario model a terraform workspace that answers badly. `terraform
# output -json` returns {} with exit 0 when there is no state (verified: an
# uninitialised dir with a provider block answers {} rc=0, and a dir holding
# state answers its outputs with no init at all), so the empty-declaration case
# is reached through TFOUT, not through a non-zero exit. TFRC covers the exit
# anyway, because the sweep must not be able to tell the difference.
terraform() { cat "${TFOUT}"; return "$(cat "${TFRC}" 2>/dev/null || echo 0)"; }

# Reporters. Captured so a scenario can assert on what the operator was told,
# not merely on an exit status.
LAST_OK=""; LAST_FAIL=""; LAST_WARN=""; LAST_INFO=""
ok()   { echo "      OK   $*";   LAST_OK="${LAST_OK}$*"$'\n'; }
fail() { echo "      FAIL $*";   LAST_FAIL="${LAST_FAIL}$*"$'\n'; }
warn() { echo "      WARN $*";   LAST_WARN="${LAST_WARN}$*"$'\n'; }
info() { echo "      INFO $*";   LAST_INFO="${LAST_INFO}$*"$'\n'; }

VAULT_TOKEN="hvs.test-token"
VAULT_CONFIG_DIR="${WORK}/vault-config"
mkdir -p "${VAULT_CONFIG_DIR}"

# shellcheck source=/dev/null
[[ -s "${WORK}/expected.sh" ]] && source "${WORK}/expected.sh"
# shellcheck source=/dev/null
source "${WORK}/sweep.sh"
# shellcheck source=/dev/null
source "${WORK}/gate.sh"

# The sweep's CALL SITE inside phase_vault_config decides what a given exit
# status does to the deploy, and that decision is not in either function. It is
# top-level code, so it is extracted by anchor and wrapped, with both anchors
# asserted the same way check 14's are.
{
    echo '_heal_call_site() {'
    awk '/^  local _heal_rc=0$/{f=1} f{print} f&&/^  fi$/{exit}' "${VAULT_CONFIGURE_SCRIPT}"
    echo '    return 0'
    echo '}'
} > "${WORK}/callsite.sh"
# A missing call site is FATAL for the shipped script — that is anchor drift, and
# silently skipping the scenario is the same fail-open this whole suite exists to
# close. Against an explicitly-named older copy it is expected (the first
# implementation swallowed the status with `|| true` and had no such block), so
# there the scenario is SKIPPED out loud and counted as neither pass nor fail.
CALLSITE_OK=yes
if ! grep -q 'heal_orphan_oauth_aliases || _heal_rc=' "${WORK}/callsite.sh"; then
    if [[ "${VAULT_CONFIGURE_SCRIPT}" == "${SCRIPT_DIR}/vault-configure.sh" ]]; then
        fatal "could not extract the sweep call site from ${VAULT_CONFIGURE_SCRIPT} (was it rewritten?)"
    fi
    CALLSITE_OK=no
fi
if [[ "${CALLSITE_OK}" == yes ]]; then
    grep -q '^  fi$' "${WORK}/callsite.sh" \
        || fatal "the extracted call site is not closed — extraction ran past its block"
    grep -q 'record "vault_config"' "${WORK}/callsite.sh" \
        || fatal "the extracted call site no longer records a phase result — anchors moved"
    # shellcheck source=/dev/null
    source "${WORK}/callsite.sh"
fi

LAST_RECORD=""
record() { LAST_RECORD="$1=$2"; }
# Drives the real call-site block against a sweep that returns a chosen status.
_run_call_site() {   # <status heal_orphan_oauth_aliases returns>
    local want="$1"
    LAST_RECORD=""; LAST_FAIL=""
    heal_orphan_oauth_aliases() { return "${want}"; }
    CS_RC=0; _heal_call_site >/dev/null 2>&1 || CS_RC=$?
}

# Check 14 of test-vault-verify.sh is top-level code, not a function, so it is
# extracted by comment anchor and wrapped — the same way test-acme-fallback.sh
# wraps the ACME fallback caller. Both anchors are asserted: without the STOP
# anchor awk would swallow the tail of the file into the function body.
{
    echo '_issuer_coherence_check() {'
    awk '/^# Check 14 — issuer coherence/{f=1} /^# Summary is printed automatically/{f=0} f{print}' \
        "${VAULT_VERIFY_SCRIPT}"
    echo '    return 0'
    echo '}'
} > "${WORK}/check14.sh"
grep -q 'vault_issuer_id=' "${WORK}/check14.sh" \
    || fatal "could not extract check 14 from ${VAULT_VERIFY_SCRIPT} (anchors moved?)"
grep -q '^# Summary is printed automatically' "${VAULT_VERIFY_SCRIPT}" \
    || fatal "the check-14 STOP anchor is gone from ${VAULT_VERIFY_SCRIPT} — the extraction would run to EOF"
# shellcheck source=/dev/null
source "${WORK}/check14.sh"

VAULT_NAMESPACE=vault; VAULT_POD=vault-0; VAULT_EXEC=""
print_pass() { echo "      PASS $*"; LAST_PASS="${LAST_PASS}$*"$'\n'; }
print_fail() { echo "      FAIL $1"; LAST_FAILMSG="${LAST_FAILMSG}${1} ${2:-}"$'\n'; }
# kubectl is only reached by check 14 here, and only to read Vault's profile.
kubectl() { vault_exec "vault read -format=json sys/config/oauth-resource-server/ivia"; }
_run_coherence() {   # <iviaop advertised issuer>
    ivia_issuer="$1"; LAST_PASS=""; LAST_FAILMSG=""
    _issuer_coherence_check >/dev/null 2>&1
}

#-- 3. Fixtures --------------------------------------------------------------
LIVE_ID="c06ea041"
OLD_ID="9ca77226"
LIVE_ISS="https://wrp.12p3h9.44-205-152-139.nip.io"
OLD_ISS="https://wrp.12p3h9.54-172-187-235.nip.io"
LIVE_ACC="oauth-resource-server_root_${LIVE_ID}"
OLD_ACC="oauth-resource-server_root_${OLD_ID}"
K8S_ACC="auth_kubernetes_600e4e25"

# The four identities the workshop declares, exactly as infrastructure/
# vault-config/outputs.tf exposes them.
TF_JSON='{
  "human_entity_ids":    {"value": {"oscar": "ent-oscar", "jaime": "ent-jaime"}},
  "agent_uc2_entity_id": {"value": "ent-agent-uc2"},
  "uc3_actor_entity_id": {"value": "ent-uc3-actor"}
}'

_reset() {
    : > "${ALIASES}"; : > "${DELFAIL}"; : > "${DELETED}"
    echo "${LIVE_ID}"  > "${PROFILE}"
    echo "${LIVE_ISS}" > "${ISSUER}"
    echo yes > "${VAULT_UP}"
    echo yes > "${PF_UP}"
    echo "${TF_JSON}" > "${TFOUT}"
    echo 0 > "${TFRC}"
    LAST_OK=""; LAST_FAIL=""; LAST_WARN=""; LAST_INFO=""
}

# The four aliases of one generation.
_add_generation() {   # <accessor> <issuer> <id-prefix>
    local acc="$1" iss="$2" pfx="$3"
    {
        echo "${pfx}-1|oscar|${acc}|${iss}|ent-oscar"
        echo "${pfx}-2|jaime|${acc}|${iss}|ent-jaime"
        echo "${pfx}-3|agent-uc2|${acc}|${iss}|ent-agent-uc2"
        echo "${pfx}-4|uc3-actor|${acc}|${iss}|ent-uc3-actor"
    } >> "${ALIASES}"
}
_add_k8s_aliases() {
    {
        echo "k8s-1|uc1/uc1-retriever-sa|${K8S_ACC}||ent-k8s-1"
        echo "k8s-2|b4a6de2d-fb8b-47e0-8537-b0aeff1737ed|${K8S_ACC}||ent-k8s-2"
    } >> "${ALIASES}"
}

_run_sweep() { RC=0; heal_orphan_oauth_aliases >/dev/null 2>&1 || RC=$?
    NDEL="$(grep -c . "${DELETED}" 2>/dev/null || true)"
    NLEFT="$(grep -c . "${ALIASES}" 2>/dev/null || true)"; }
_run_gate()  { RC=0; assert_oauth_aliases_current "$1" >/dev/null 2>&1 || RC=$?; }

echo -e "${BLUE}=== Vault OAuth entity-alias sweep + gate (issue #5) — offline behaviour test ===${NC}"
echo -e "    code under test extracted live from ${VAULT_CONFIGURE_SCRIPT}"
echo

#===============================================================================
# THE SWEEP
#===============================================================================
echo -e "${YELLOW}1. Every alias is on the live profile — the sweep is a no-op${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur; _add_k8s_aliases
_run_sweep
assert "completes cleanly"                     "0" "${RC}"
assert "deletes nothing"                       "0" "${NDEL}"
assert "leaves all six aliases"                "6" "${NLEFT}"
echo

echo -e "${YELLOW}2. A stranded generation is swept before it can collide${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        _add_generation "${OLD_ACC}"  "${OLD_ISS}"  old; _add_k8s_aliases
_run_sweep
assert "completes cleanly"                     "0" "${RC}"
assert "deletes the four stranded aliases"     "4" "${NDEL}"
assert "the live generation survives"          "4" "$(grep -c "${LIVE_ACC}" "${ALIASES}" || true)"
assert "Kubernetes auth aliases are untouched" "2" "$(grep -c "${K8S_ACC}" "${ALIASES}" || true)"
assert "names every alias it deleted"          "4" "$(grep -c 'deleted orphaned OAuth alias old-' <<<"${LAST_INFO}" || true)"
# Wording-independent: what matters is that the audit line carries a COUNT a
# reviewer can check, not the sentence it is wrapped in.
assert "reports how many it deleted"           "yes" "$(grep -qE 'Deleted 4 .*alias' <<<"${LAST_OK}" && echo yes || echo no)"
echo

echo -e "${YELLOW}3. An OAuth alias this workshop never wrote is left alone${NC}"
echo -e "     (a dead accessor is not licence to delete someone else's identity:"
echo -e "      deletion is scoped to the names terraform declares)"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        echo "foreign-1|someone-elses-app|${OLD_ACC}|${OLD_ISS}|ent-foreign" >> "${ALIASES}"
_run_sweep
assert "completes cleanly"                     "0" "${RC}"
assert "deletes nothing"                       "0" "${NDEL}"
assert "the foreign alias survives"            "1" "$(grep -c 'foreign-1' "${ALIASES}" || true)"
assert "names what it left behind, rather than skipping in silence" "yes" \
    "$(grep -q "left alias foreign-1 (name someone-elses-app) on dead profile" <<<"${LAST_WARN}" && echo yes || echo no)"
echo

echo -e "${YELLOW}4. No aliases at all — an ordinary no-op, not a failure${NC}"
_reset
_run_sweep
assert "completes cleanly"                     "0" "${RC}"
assert "deletes nothing"                       "0" "${NDEL}"
echo

echo -e "${YELLOW}5. No profile yet (first deploy) — nothing this sweep is about${NC}"
_reset; : > "${PROFILE}"
_run_sweep
assert "reports 'nothing to sweep', not a fault" "2" "${RC}"
assert "deletes nothing"                         "0" "${NDEL}"
assert "says so plainly"                         "yes" "$(grep -q 'first deploy' <<<"${LAST_INFO}" && echo yes || echo no)"
echo

echo -e "${YELLOW}6. Vault unreadable — refuse to delete, and say the sweep did not run${NC}"
_reset; _add_generation "${OLD_ACC}" "${OLD_ISS}" old; echo no > "${VAULT_UP}"
_run_sweep
assert "fails"                                 "1" "${RC}"
assert "deletes nothing"                       "0" "${NDEL}"
assert "the stranded generation survives"      "4" "${NLEFT}"
echo

echo -e "${YELLOW}7. A delete that Vault refuses is reported, not swallowed${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        _add_generation "${OLD_ACC}"  "${OLD_ISS}"  old
        echo "old-3" > "${DELFAIL}"
_run_sweep
assert "fails"                                 "1" "${RC}"
assert "still deletes the three it could"      "3" "${NDEL}"
assert "names the one it could not"            "yes" "$(grep -q 'Failed to delete orphaned OAuth alias old-3' <<<"${LAST_WARN}" && echo yes || echo no)"
echo

echo -e "${YELLOW}8. The port-forward is down but Vault is healthy${NC}"
echo -e "     (the regression case: a sweep that reads Vault through the tunnel goes"
echo -e "      silently blind here, and the collision it exists to clear survives)"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        _add_generation "${OLD_ACC}"  "${OLD_ISS}"  old
        echo no > "${PF_UP}"
_run_sweep
assert "still completes"                       "0" "${RC}"
assert "still sweeps the stranded generation"  "4" "${NDEL}"
echo

echo -e "${YELLOW}9. Terraform declares no identities while orphans are sitting there${NC}"
echo -e "     (the expected set is unknown, so deleting would be deleting blind —"
echo -e "      and the collision is real, so this stops the deploy)"
_reset; _add_generation "${OLD_ACC}" "${OLD_ISS}" old; echo '{}' > "${TFOUT}"
_run_sweep
assert "fails"                                 "1" "${RC}"
assert "deletes nothing"                       "0" "${NDEL}"
echo

echo -e "${YELLOW}10. Terraform declares no identities and there is nothing to sweep${NC}"
echo -e "     (a fresh checkout reads 'terraform output -json' as {} with exit 0, so"
echo -e "      demanding a non-empty expected set up front would abort a deploy that"
echo -e "      had no orphan in the first place)"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur; _add_k8s_aliases
        echo '{}' > "${TFOUT}"
_run_sweep
assert "completes cleanly rather than aborting the phase" "0" "${RC}"
assert "deletes nothing"                                  "0" "${NDEL}"
assert "leaves all six aliases"                           "6" "${NLEFT}"
assert "raises no refusal"                                "no" \
    "$(grep -q 'refusing to delete any alias' <<<"${LAST_WARN}" && echo yes || echo no)"
echo

echo -e "${YELLOW}11. The terraform workspace itself errors out${NC}"
echo -e "     (an unusable workspace must read the same as an empty one: sweep when"
echo -e "      there is nothing at risk, refuse when there is)"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        : > "${TFOUT}"; echo 1 > "${TFRC}"
_run_sweep
assert "no orphan present — completes cleanly"  "0" "${RC}"
assert "deletes nothing"                        "0" "${NDEL}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        _add_generation "${OLD_ACC}"  "${OLD_ISS}"  old
        : > "${TFOUT}"; echo 1 > "${TFRC}"
_run_sweep
assert "orphan present — refuses rather than deleting blind" "1" "${RC}"
assert "deletes nothing"                                     "0" "${NDEL}"
assert "the stranded generation survives"                    "8" "${NLEFT}"
echo

echo -e "${YELLOW}12. An identity dropped from the workshop is left alone, and said out loud${NC}"
echo -e "     (name-scoped deletion means a removed human's stale alias is NOT swept;"
echo -e "      it only bites if that human is re-added later, so it must be visible)"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
        _add_generation "${OLD_ACC}"  "${OLD_ISS}"  old
        echo '{"human_entity_ids":{"value":{"oscar":"ent-oscar"}},
               "agent_uc2_entity_id":{"value":"ent-agent-uc2"},
               "uc3_actor_entity_id":{"value":"ent-uc3-actor"}}' > "${TFOUT}"
_run_sweep
assert "sweeps the three still-declared identities" "3" "${NDEL}"
assert "leaves the dropped identity's alias"        "1" "$(grep -c '^old-2|' "${ALIASES}" || true)"
assert "names it in the log"                        "yes" \
    "$(grep -q 'left alias old-2 (name jaime) on dead profile' <<<"${LAST_WARN}" && echo yes || echo no)"
assert "counts it in the summary"                   "yes" \
    "$(grep -qE '1 alias\(es\) on a dead profile were left in place' <<<"${LAST_WARN}" && echo yes || echo no)"
echo

#===============================================================================
# THE GATE
#===============================================================================
echo -e "${YELLOW}13. Every identity has an alias at the live profile${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur; _add_k8s_aliases
_run_gate "${LIVE_ISS}"
assert "passes"                                "0" "${RC}"
assert "counts what it read against what it expected" "yes" \
    "$(grep -q '4 found at accessor '"${LIVE_ACC}"', 4 expected' <<<"${LAST_OK}" && echo yes || echo no)"
echo

echo -e "${YELLOW}14. Aliases exist, but only at the PREVIOUS issuer${NC}"
echo -e "     (the deadlock this gate exists for: the profile reads correct while"
echo -e "      every alias write in the same apply was refused with 400)"
_reset; _add_generation "${OLD_ACC}" "${OLD_ISS}" old; _add_k8s_aliases
_run_gate "${LIVE_ISS}"
assert "fails"                                 "1" "${RC}"
assert "names all four missing identities"     "4" "$(grep -c "is missing at the live profile" <<<"${LAST_FAIL}" || true)"
assert "says what breaks at run time"          "yes" "$(grep -q 'no alias found' <<<"${LAST_FAIL}" && echo yes || echo no)"
echo

echo -e "${YELLOW}15. Aliases at the live accessor but stamped with the OLD issuer${NC}"
_reset; _add_generation "${LIVE_ACC}" "${OLD_ISS}" cur
_run_gate "${LIVE_ISS}"
assert "fails — the issuer is part of the identity" "1" "${RC}"
echo

echo -e "${YELLOW}16. Vault unreadable — UNVERIFIED is not a pass${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur; echo no > "${VAULT_UP}"
_run_gate "${LIVE_ISS}"
assert "fails"                                 "1" "${RC}"
assert "says the aliases are UNVERIFIED"       "yes" "$(grep -q 'UNVERIFIED' <<<"${LAST_FAIL}" && echo yes || echo no)"
echo

echo -e "${YELLOW}17. Terraform declares no identities — the gate cannot run${NC}"
_reset; _add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur; echo '{}' > "${TFOUT}"
_run_gate "${LIVE_ISS}"
assert "fails rather than passing on an empty expected set" "1" "${RC}"
echo

echo -e "${YELLOW}18. An identity added to the workshop is gated, not silently skipped${NC}"
_reset
echo '{"human_entity_ids":{"value":{"oscar":"ent-oscar","jaime":"ent-jaime","newcomer":"ent-newcomer"}},
       "agent_uc2_entity_id":{"value":"ent-agent-uc2"},
       "uc3_actor_entity_id":{"value":"ent-uc3-actor"}}' > "${TFOUT}"
_add_generation "${LIVE_ACC}" "${LIVE_ISS}" cur
_run_gate "${LIVE_ISS}"
assert "fails — the new identity has no alias"  "1" "${RC}"
assert "names the newcomer"                     "yes" "$(grep -q "alias 'newcomer' is missing" <<<"${LAST_FAIL}" && echo yes || echo no)"
echo

#===============================================================================
# ISSUER COHERENCE (test-vault-verify.sh check 14)
#===============================================================================
echo -e "${YELLOW}19. Vault validates against the issuer iviaop actually stamps${NC}"
_reset
_run_coherence "${LIVE_ISS}"
assert "passes"                                "yes" "$(grep -q 'Issuer coherence: Vault validates against the same issuer' <<<"${LAST_PASS}" && echo yes || echo no)"
echo

echo -e "${YELLOW}20. Tier 2 moved Vault's issuer; tier 3 has not caught up${NC}"
echo -e "     (both hosts are real and both are live — the disagreement every"
echo -e "      existing gate misses, because each one reads a single side)"
_reset
_run_coherence "${OLD_ISS}"
assert "fails"                                 "yes" "$(grep -q 'Issuer coherence' <<<"${LAST_FAILMSG}" && echo yes || echo no)"
assert "prints both values"                    "yes" "$(grep -q "${LIVE_ISS}" <<<"${LAST_FAILMSG}" && grep -q "${OLD_ISS}" <<<"${LAST_FAILMSG}" && echo yes || echo no)"
assert "tells the operator to re-apply tier 3" "yes" "$(grep -q 'deploy-workshop.sh --tier 3' <<<"${LAST_FAILMSG}" && echo yes || echo no)"
echo

echo -e "${YELLOW}21. Tier-2 placeholder is not a failure${NC}"
echo -e "     (iviaop ships https://issuer-patched-at-root.invalid until tier 3"
echo -e "      flips it; warning here is the false alarm that has misdirected"
echo -e "      debugging before)"
_reset
_run_coherence "https://issuer-patched-at-root.invalid"
assert "passes"                                "yes" "$(grep -q 'not yet applicable' <<<"${LAST_PASS}" && echo yes || echo no)"
assert "raises no failure"                     ""    "${LAST_FAILMSG}"
echo

echo -e "${YELLOW}22. One side unreadable — a comparison that cannot run is not a pass${NC}"
_reset; echo no > "${VAULT_UP}"
_run_coherence "${LIVE_ISS}"
assert "fails"                                 "yes" "$(grep -q 'were NOT compared' <<<"${LAST_FAILMSG}" && echo yes || echo no)"
echo

#===============================================================================
# THE CALL SITE (phase_vault_config)
#===============================================================================
echo -e "${YELLOW}23. What each sweep status does to the deploy${NC}"
echo -e "     (the sweep's exit code is only half the fix — the other half is the"
echo -e "      call site acting on it instead of swallowing it with '|| true')"
if [[ "${CALLSITE_OK}" != yes ]]; then
echo -e "    ${YELLOW}—${NC} SKIPPED: ${VAULT_CONFIGURE_SCRIPT##*/} has no such call site"
echo -e "      (it swallows the sweep status with '|| true', which is the defect"
echo -e "       scenarios 10 and 11 above already fail it on)"
else
_run_call_site 0
assert "clean sweep — the phase carries on"            "0"  "${CS_RC}"
assert "records no failure"                            ""   "${LAST_RECORD}"
_run_call_site 2
assert "first deploy (no profile) — the phase carries on" "0" "${CS_RC}"
assert "records no failure"                            ""   "${LAST_RECORD}"
_run_call_site 1
assert "sweep could not run — the phase stops"         "1"  "${CS_RC}"
assert "records the phase as failed"                   "vault_config=FAIL" "${LAST_RECORD}"
assert "says why, naming the 400 it is preventing"     "yes" \
    "$(grep -q 'alias already exists for issuer and external_id' <<<"${LAST_FAIL}" && echo yes || echo no)"
fi
echo

#===============================================================================
echo "============================================================"
if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}✓ ${PASSED} check(s) passed${NC}"
    exit 0
fi
echo -e "${RED}✗ ${FAILED} of $(( PASSED + FAILED )) check(s) failed${NC}"
exit 1
