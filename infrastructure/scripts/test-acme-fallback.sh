#!/usr/bin/env bash
#===============================================================================
# infrastructure/scripts/test-acme-fallback.sh
#
# Offline test for the Let's Encrypt TLS-suffix fallback (issue #5).
#
# The workshop's TLS host names are built on nip.io, a magic-DNS domain shared
# with the whole internet. Let's Encrypt budgets certificates per registered
# domain, so an exhausted nip.io budget fails EVERY attendee's tier-2 deploy at
# once. deploy-workshop.sh answers that by retrying on sslip.io — a different
# registered domain with its own separate budget.
#
# That branch only ever runs on a day Let's Encrypt is refusing nip.io, which
# cannot be provoked on demand and must never be provoked deliberately (it
# would spend the shared budget the workshop depends on). This test drives it
# instead against a stubbed kubectl: no cluster, no AWS, no ACME traffic.
#
# It does NOT copy the code under test. It extracts the REAL
# _acme_issue_certificate and the REAL caller out of deploy-workshop.sh at
# runtime, by anchor, and fails loudly if it cannot find them — a copy silently
# goes stale and then certifies code that is no longer shipped.
#
# Usage: bash infrastructure/scripts/test-acme-fallback.sh
#===============================================================================
# The stubs and fixtures below are invoked INDIRECTLY — by the code extracted
# out of deploy-workshop.sh and sourced at runtime. ShellCheck cannot see that
# call graph, so it reports live stubs as dead (SC2329) and live fixtures as
# unused (SC2034); SC1091 is the generated files it is asked to follow.
# shellcheck disable=SC2329,SC2034,SC1091
set -uo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the suite can be pointed at an older copy of the deploy script
# to prove a regression assertion actually fails without the fix in place.
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-${SCRIPT_DIR}/deploy-workshop.sh}"

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
[ -f "${DEPLOY_SCRIPT}" ] || fatal "deploy-workshop.sh not found at ${DEPLOY_SCRIPT}"

# The function: from its definition line to the first column-0 closing brace.
awk '/^_acme_issue_certificate\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "${DEPLOY_SCRIPT}" > "${WORK}/helper.sh"
grep -q '^_acme_issue_certificate() {' "${WORK}/helper.sh" \
    || fatal "could not extract _acme_issue_certificate() from deploy-workshop.sh (was it renamed?)"
grep -q '^}' "${WORK}/helper.sh" \
    || fatal "extracted _acme_issue_certificate() is not closed — extraction is wrong"

# The caller: the fallback block, anchored on its own comments rather than line
# numbers so it survives edits above it.
{
    echo '_acme_caller() {'
    awk '/# \(5\) Issue the Certificate\./{f=1} /# A suffix change rewrites \.acme-state/{f=0} f{print}' \
        "${DEPLOY_SCRIPT}"
    echo '    return 0'
    echo '}'
} > "${WORK}/caller.sh"
# Literal match against the extracted source — must NOT expand.
# shellcheck disable=SC2016
grep -q '_acme_issue_certificate "${TLS_DNS_SUFFIX_FALLBACK}"' "${WORK}/caller.sh" \
    || fatal "could not extract the fallback caller from deploy-workshop.sh (anchors moved?)"
# The START anchor is proven by the grep above. The STOP anchor is not: if it is
# renamed, awk never clears the flag and swallows the whole tail of the deploy
# script into the function body — which then sources and executes. Prove the
# stop anchor is still there, and prove the extract stopped where it should by
# asserting it did not drag in the script's top-level tier dispatch.
grep -q '# A suffix change rewrites \.acme-state' "${DEPLOY_SCRIPT}" \
    || fatal "the caller STOP anchor is gone from deploy-workshop.sh — the extraction would run to EOF"
grep -q '_run_if_tier' "${WORK}/caller.sh" \
    && fatal "the extracted caller ran past its STOP anchor into deploy-workshop.sh's tier dispatch"

#-- 2. Stub the outside world ------------------------------------------------
print_info() { echo "      INFO $*"; }
print_warn() { echo "      WARN $*"; LAST_WARN="$*"; }
print_fail() { echo "      FAIL $1"; LAST_FAIL="${2:-}"; }

# Virtual clock: `sleep` advances it, so the function's real 900s ceiling is
# reached in milliseconds instead of a quarter of an hour.
NOW=1000000000
sleep() { NOW=$(( NOW + ${1:-15} )); }
date() { if [[ "${1:-}" == "+%s" ]]; then echo "${NOW}"; else command date "$@"; fi; }

APPLIED="${WORK}/applied"; POLLS="${WORK}/polls"; ORDERS="${WORK}/orders"

RL='Failed to create Order: 429 urn:ietf:params:acme:error:rateLimited: too many certificates (50000) already issued for'

# The cluster, modelled as a file of Orders ("<name>|<first dnsName>|<reason>").
# cert-manager creates one per Certificate spec and NEVER deletes an errored
# one, which is the whole point of scenario 5.
kubectl() {
    local args="$*"

    if [[ "${args}" == *"apply -f -"* ]]; then
        local yaml fq n
        yaml=$(cat)
        fq=$(grep -oE '^[[:space:]]+- wrp\..*' <<<"${yaml}" | sed 's/^[[:space:]]*- //')
        echo "${fq}" >> "${APPLIED}"
        n=$(grep -c . "${APPLIED}")
        case "${SCENARIO}" in
            primary_ratelimited)
                [[ "${fq}" == *.nip.io ]] \
                    && echo "order-${n}|${fq}|${RL} \"nip.io\" in the last 168h0m0s" >> "${ORDERS}" ;;
            both_ratelimited)
                echo "order-${n}|${fq}|${RL} its registered domain in the last 168h0m0s" >> "${ORDERS}" ;;
            dns_failure_not_ratelimited)
                echo "order-${n}|${fq}|Failed to create Order: acme: authorization error: 403 urn:ietf:params:acme:error:dns: DNS problem: NXDOMAIN looking up A for ${fq}" >> "${ORDERS}" ;;
        esac
        return 0
    fi

    if [[ "${args}" == *"delete orders"* ]]; then
        local name
        name=$(tr ' ' '\n' <<<"${args}" | grep -E '^order-' | head -1)
        if [[ -n "${name}" ]]; then
            grep -v "^${name}|" "${ORDERS}" > "${ORDERS}.tmp" 2>/dev/null || true
            mv -f "${ORDERS}.tmp" "${ORDERS}"
        fi
        return 0
    fi

    if [[ "${args}" == *"get orders"* ]]; then
        # Two different jsonpaths: names (for the pre-wait sweep) and
        # "<dnsName>|<reason>" rows (for the rate-limit verdict).
        if [[ "${args}" == *"metadata.name"* ]]; then
            cut -d'|' -f1 "${ORDERS}" 2>/dev/null || true
        else
            cut -d'|' -f2- "${ORDERS}" 2>/dev/null || true
        fi
        return 0
    fi

    if [[ "${args}" == *"get certificate"* ]]; then
        local n wrp bank out
        n=$(( $(cat "${POLLS}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${POLLS}"
        wrp=$(tail -1 "${APPLIED}")
        bank="banking.${wrp#wrp.}"
        # Answer the jsonpath that was actually asked for. Code that requests
        # only the Ready condition gets only the Ready condition — otherwise
        # this stub, not the defect, is what makes an old script fail.
        out=""
        case "${SCENARIO}" in
            clean_issue)               out="True|${wrp} ${bank}" ;;
            primary_ratelimited)
                if [[ "${wrp}" == *sslip.io && ${n} -ge 3 ]]; then out="True|${wrp} ${bank}"
                else out="False|${wrp} ${bank}"; fi ;;
            stale_order_previous_run)
                if [[ ${n} -ge 3 ]]; then out="True|${wrp} ${bank}"; else out="False|${wrp} ${bank}"; fi ;;
            ready_but_for_the_old_host)
                # cert-manager has not reconciled the changed dnsNames yet, so
                # the object still reports Ready for the PREVIOUS hosts.
                if [[ ${n} -ge 3 ]]; then out="True|${wrp} ${bank}"
                else out="True|wrp.old999.44-205-184-217.example wrp.old999.44-205-184-217.example"; fi ;;
            *) out="False|${wrp} ${bank}" ;;
        esac
        if [[ "${args}" == *"spec.dnsNames"* ]]; then echo "${out}"; else echo "${out%%|*}"; fi
        return 0
    fi
    return 0
}

source "${WORK}/helper.sh"
source "${WORK}/caller.sh"

run_scenario() {
    SCENARIO="$1"
    TLS_DNS_SUFFIX="nip.io"; TLS_DNS_SUFFIX_FALLBACK="sslip.io"
    DEPLOY_ID="abc123"; ALB_IP_DASHED="44-205-184-217"
    NIP_FQDN_WRP=""; NIP_FQDN_BANKING=""; LAST_WARN=""; LAST_FAIL=""
    # The caller decides this before issuance runs; the fallback must clear it.
    _acme_suffix_current=true
    NOW=1000000000
    : > "${APPLIED}"; : > "${POLLS}"; : > "${ORDERS}"
    # Scenario 5 starts on a cluster an EARLIER deploy already got refused on.
    if [[ "${SCENARIO}" == "stale_order_previous_run" ]]; then
        echo "order-stale|wrp.old999.44-205-184-217.nip.io|${RL} \"nip.io\" in the last 168h0m0s" > "${ORDERS}"
    fi
    _acme_caller >/dev/null 2>&1
    RC=$?
    CERTS="$(tr '\n' ' ' < "${APPLIED}" | sed 's/ $//')"
    NCERTS="$(grep -c . "${APPLIED}")"
    NPOLLS="$(cat "${POLLS}" 2>/dev/null || echo 0)"
    NSTALE="$(grep -c 'old999' "${ORDERS}" 2>/dev/null || true)"
}

echo -e "${BLUE}=== ACME TLS-suffix fallback (issue #5) — offline behaviour test ===${NC}"
echo -e "    code under test extracted live from deploy-workshop.sh"
echo

echo -e "${YELLOW}1. Let's Encrypt accepts nip.io — no fallback${NC}"
run_scenario clean_issue
assert "returns success"                       "0"                                      "${RC}"
assert "host stays on nip.io"                  "wrp.abc123.44-205-184-217.nip.io"       "${NIP_FQDN_WRP}"
assert "banking SAN matches the same suffix"   "banking.abc123.44-205-184-217.nip.io"   "${NIP_FQDN_BANKING}"
assert "issues exactly one certificate"        "1"                                      "${NCERTS}"
echo

echo -e "${YELLOW}2. nip.io budget exhausted — falls back to sslip.io${NC}"
run_scenario primary_ratelimited
assert "returns success"                       "0"                                      "${RC}"
assert "host moved to the fallback suffix"     "wrp.abc123.44-205-184-217.sslip.io"     "${NIP_FQDN_WRP}"
assert "banking SAN moved with it"             "banking.abc123.44-205-184-217.sslip.io" "${NIP_FQDN_BANKING}"
assert "tried nip.io first, then sslip.io"     "wrp.abc123.44-205-184-217.nip.io wrp.abc123.44-205-184-217.sslip.io" "${CERTS}"
assert "warns that nip.io was refused"         "yes"  "$(grep -q 'refused nip.io as rate limited' <<<"${LAST_WARN}" && echo yes || echo no)"
# The hosts in .acme-state just changed, and tier 3 builds the banking-UI
# Ingress from that file. If this flag stays true the tier-2 "carry the change
# into tier 3" warning can never fire in the one case the fallback creates.
assert "flags the suffix as changed for tier 2" "false"                                 "${_acme_suffix_current}"
echo

echo -e "${YELLOW}3. Both budgets exhausted — fails with a usable instruction${NC}"
run_scenario both_ratelimited
assert "returns failure"                       "1"                                      "${RC}"
assert "tried both suffixes before giving up"  "2"                                      "${NCERTS}"
assert "names both exhausted suffixes"         "yes"  "$(grep -q 'refused BOTH nip.io and sslip.io' <<<"${LAST_FAIL}" && echo yes || echo no)"
assert "tells the operator what kind of suffix works" "yes" "$(grep -q 'dashed-IPv4 magic-DNS provider' <<<"${LAST_FAIL}" && echo yes || echo no)"
echo

echo -e "${YELLOW}4. Failure that is NOT a rate limit — fallback must not fire${NC}"
echo -e "    (nip.io resolving NXDOMAIN: a second magic-DNS suffix would not help,"
echo -e "     and burning it would waste the one budget still intact)"
run_scenario dns_failure_not_ratelimited
assert "returns failure"                       "1"                                      "${RC}"
assert "does NOT try the fallback suffix"      "1"                                      "${NCERTS}"
assert "stays on the primary suffix"           "wrp.abc123.44-205-184-217.nip.io"       "${NIP_FQDN_WRP}"
assert "emits no rate-limit warning"           "yes"  "$(grep -q 'rate limited' <<<"${LAST_WARN}" && echo no || echo yes)"
echo

echo -e "${YELLOW}5. A PREVIOUS deploy was refused on this cluster — judge this run on its own${NC}"
echo -e "    (cert-manager never deletes an errored Order. Left in place, the first"
echo -e "     refusal on a cluster is reported forever: every later run returns"
echo -e "     'rate limited' on its first poll without Let's Encrypt being asked.)"
run_scenario stale_order_previous_run
assert "returns success"                       "0"                                      "${RC}"
assert "stays on nip.io — LE refused nothing"  "wrp.abc123.44-205-184-217.nip.io"       "${NIP_FQDN_WRP}"
assert "does NOT burn the fallback budget"     "1"                                      "${NCERTS}"
assert "emits no rate-limit warning"           "yes"  "$(grep -q 'rate limited' <<<"${LAST_WARN}" && echo no || echo yes)"
assert "swept the earlier run's Order"         "0"                                      "${NSTALE}"
echo

echo -e "${YELLOW}6. Certificate still Ready for the OLD hosts — must not satisfy the gate${NC}"
echo -e "    (Ready alone says nothing about WHICH hosts. Accepting it writes"
echo -e "     .acme-state with FQDNs no certificate covers, and ACM imports a"
echo -e "     certificate whose SANs do not match what the ALB will serve.)"
run_scenario ready_but_for_the_old_host
assert "returns success"                       "0"                                      "${RC}"
assert "waited for the cert to cover our hosts" "yes"  "$([[ ${NPOLLS} -ge 3 ]] && echo yes || echo no)"
assert "host is the one we asked for"          "wrp.abc123.44-205-184-217.nip.io"       "${NIP_FQDN_WRP}"
echo

echo -e "${YELLOW}7. Primary and fallback set to the same suffix — refused up front${NC}"
echo -e "    (Let's Encrypt budgets per registered domain, so a 'fallback' to the"
echo -e "     same suffix is a second 15-minute wait on the budget that just"
echo -e "     refused us. The Step 7 failure text invites exactly this mistake.)"
SAME_OUT=$(TLS_DNS_SUFFIX=sslip.io TLS_DNS_SUFFIX_FALLBACK=sslip.io \
    bash "${DEPLOY_SCRIPT}" --help 2>&1); SAME_RC=$?
assert "refuses to run"                        "1"                                      "${SAME_RC}"
assert "names the duplicated suffix"           "yes"  "$(grep -q "both 'sslip.io'" <<<"${SAME_OUT}" && echo yes || echo no)"
assert "says why a same-suffix retry is useless" "yes" "$(grep -q 'budgets per' <<<"${SAME_OUT}" && echo yes || echo no)"
echo

echo "============================================================"
if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}✓ ${PASSED} check(s) passed${NC}"
    exit 0
else
    echo -e "${RED}✗ ${FAILED} check(s) failed${NC}, ${PASSED} passed"
    exit 1
fi
