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
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-workshop.sh"

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

APPLIED="${WORK}/applied"; POLLS="${WORK}/polls"

kubectl() {
    local args="$*"
    if [[ "${args}" == *"apply -f -"* ]]; then
        local yaml fq; yaml=$(cat)
        fq=$(grep -oE '^[[:space:]]+- wrp\..*' <<<"${yaml}" | sed 's/^[[:space:]]*- //')
        echo "${fq}" >> "${APPLIED}"
        return 0
    fi
    if [[ "${args}" == *"get certificate"* ]]; then
        case "${SCENARIO}" in
            clean_issue) echo "True" ;;
            primary_ratelimited)
                # Real ACME takes 30-90s, so Ready is not true on the first poll.
                if [[ "$(tail -1 "${APPLIED}")" == *sslip.io ]]; then
                    local n; n=$(( $(cat "${POLLS}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${POLLS}"
                    [[ ${n} -ge 3 ]] && echo "True" || echo "False"
                else echo "False"; fi ;;
            *) echo "False" ;;
        esac
        return 0
    fi
    if [[ "${args}" == *"get orders"* ]]; then
        # Rows are "<first dnsName>|<reason>", exactly as the real jsonpath emits.
        local rl='Failed to create Order: 429 urn:ietf:params:acme:error:rateLimited: too many certificates (50000) already issued for'
        case "${SCENARIO}" in
            primary_ratelimited)
                grep -q 'nip\.io' "${APPLIED}" 2>/dev/null \
                    && echo "wrp.abc123.44-205-184-217.nip.io|${rl} \"nip.io\" in the last 168h0m0s" ;;
            both_ratelimited)
                while read -r f; do [[ -n "${f}" ]] && echo "${f}|${rl} its registered domain in the last 168h0m0s"; done < "${APPLIED}" ;;
            dns_failure_not_ratelimited)
                # nip.io the SERVICE is down. Not a budget refusal — the fallback
                # must NOT fire, because the second suffix is no more reachable.
                while read -r f; do [[ -n "${f}" ]] && echo "${f}|Failed to create Order: acme: authorization error: 403 urn:ietf:params:acme:error:dns: DNS problem: NXDOMAIN looking up A for ${f}"; done < "${APPLIED}" ;;
        esac
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
    NOW=1000000000
    : > "${APPLIED}"; : > "${POLLS}"
    _acme_caller >/dev/null 2>&1
    RC=$?
    CERTS="$(tr '\n' ' ' < "${APPLIED}" | sed 's/ $//')"
    NCERTS="$(grep -c . "${APPLIED}")"
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

echo "============================================================"
if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}✓ ${PASSED} check(s) passed${NC}"
    exit 0
else
    echo -e "${RED}✗ ${FAILED} check(s) failed${NC}, ${PASSED} passed"
    exit 1
fi
