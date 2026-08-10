#!/usr/bin/env bash
#===============================================================================
# sim-workshop-studio.sh — simulate an AWS Workshop Studio event, in one command
#
# Deploys the workshop's CloudFormation bootstrap the way Workshop Studio does at
# a real event, in a dev account you control, so the at-an-event path can be
# tested end to end before it reaches an event.
#
# WHAT MAKES THIS A SIMULATION AND NOT AN APPROXIMATION
# Three things are easy to skip and silently invalidate the whole test:
#
#   1. Region. contentspec.yaml pins deployableRegions to us-east-1.
#   2. WSParticipantRole. Workshop Studio hands the attendee a role carrying the
#      six managed policies listed in contentspec.yaml. Without a role of that
#      exact NAME the build FAILS outright — buildspec.yml's `aws iam
#      put-role-policy` has no `|| true` and runs under `set -e`. And without
#      that exact POLICY SET the security assertions mean nothing: the point is
#      proving a role holding SecretsManagerReadWrite still cannot read the three
#      licensing secrets.
#   3. Assets key prefix. Workshop Studio passes {{.AssetsBucketPrefix}}, so the
#      assets sit under a prefix, never at the bucket root.
#
# HOW IT RUNS
# The script stops before each major step and waits for Enter, so you can inspect
# state as it goes. The 35-45 minute deploy runs in the background with its
# output teed to a log, so Ctrl-C at any prompt leaves the deploy running.
#
# USAGE
#   ./sim-workshop-studio.sh [OPTIONS]
#   ./sim-workshop-studio.sh --status          # just report; changes nothing
#
# OPTIONS
#   --stack NAME      CloudFormation stack name       (default: cfn-sim-atevent)
#   --region REGION   Deploy region                   (default: us-east-1)
#   --icr-key KEY     IBM Container Registry entitlement key
#   --mmfa-secret S   IBM Verify MMFA push client secret
#   --license PATH    Vault Enterprise .hclic file    (default: ~/Downloads/vault-ent.hclic)
#   --skip-sync       Reuse the assets already in S3 (skip package + upload)
#   --status          Report current state and exit; deploys nothing
#   --yes, -y         Do not pause between steps
#   --help, -h        Show this help
#
# Secrets may instead come from the environment, which keeps them out of shell
# history: ICR_ENTITLEMENT_KEY, IVIA_MMFA_PUSH_CLIENT_SECRET,
# VAULT_ENTERPRISE_LICENSE_PATH. They are passed to CloudFormation through a
# mode-600 parameters file, never as command-line arguments, because arguments
# are visible to every process on the machine via `ps`.
#
# TEARDOWN is deliberately NOT part of this script. It is a separate act:
#   aws cloudformation delete-stack --stack-name <stack> --region <region>
#   aws cloudformation wait stack-delete-complete --stack-name <stack> --region <region>
# (The Delete path runs a CodeBuild that destroys tier 2 then tier 1, so it takes
# roughly as long as the create.)
#===============================================================================
set -uo pipefail

STACK="cfn-sim-atevent"
REGION="us-east-1"
LICENSE_PATH="${VAULT_ENTERPRISE_LICENSE_PATH:-$HOME/Downloads/vault-ent.hclic}"
ICR_KEY="${ICR_ENTITLEMENT_KEY:-}"
MMFA_SECRET="${IVIA_MMFA_PUSH_CLIENT_SECRET:-}"
ASSETS_PREFIX="agentic-runtime-security-aws/"
AUTO_YES=false
SKIP_SYNC=false
STATUS_ONLY=false

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/workshop/scripts/logs"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

usage() { sed -n '2,54p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)        STACK="${2:?--stack needs a value}"; shift ;;
        --region)       REGION="${2:?--region needs a value}"; shift ;;
        --icr-key)      ICR_KEY="${2:?--icr-key needs a value}"; shift ;;
        --mmfa-secret)  MMFA_SECRET="${2:?--mmfa-secret needs a value}"; shift ;;
        --license)      LICENSE_PATH="${2:?--license needs a value}"; shift ;;
        --skip-sync)    SKIP_SYNC=true ;;
        --status)       STATUS_ONLY=true ;;
        --yes|-y)       AUTO_YES=true ;;
        --help|-h)      usage 0 ;;
        -*)             echo "Unknown option: $1" >&2; usage 1 ;;
        *)              echo "Unexpected argument: $1" >&2; usage 1 ;;
    esac
    shift
done

step() { echo; echo "${BLUE}==============================================================================${NC}";
         echo "${BLUE}  STEP $1 — $2${NC}";
         echo "${BLUE}==============================================================================${NC}"; }
ok()   { echo "  ${GREEN}✓${NC} $1"; }
info() { echo "  ${BLUE}ℹ${NC} $1"; }
warn() { echo "  ${YELLOW}⚠${NC} $1"; }
die()  { echo "  ${RED}✗ $1${NC}" >&2; [[ -n "${2:-}" ]] && echo "    ${YELLOW}Fix:${NC} $2" >&2; exit 1; }

# Stop so the operator can inspect state before the next step mutates anything.
# Reads from /dev/tty so a piped stdin does not silently skip every prompt.
# Test that /dev/tty can actually be OPENED, not merely that it exists: under a
# pipe or a detached job the node is present but unopenable, and a bare -e test
# lets the read fail noisily instead of skipping the prompt.
pause() {
    $AUTO_YES && return 0
    { : < /dev/tty; } 2>/dev/null || return 0
    echo
    read -r -p "  ${YELLOW}?${NC} $1 — Enter to continue, Ctrl-C to stop " _ < /dev/tty
}

#-------------------------------------------------------------------------------
# report — what the stack looks like right now. Used by --status and by STEP 6.
#-------------------------------------------------------------------------------
report() {
    local final
    final=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NO_STACK")

    if [[ "$final" == "NO_STACK" ]]; then
        warn "No stack named ${STACK} in ${REGION}."
        return 1
    fi

    info "Stack status: ${final}"

    local project
    project=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query "Stacks[].Outputs[?OutputKey=='CodeBuildProjectName'].OutputValue|[]|[0]" \
        --output text 2>/dev/null)
    if [[ -n "$project" && "$project" != "None" ]]; then
        # No --max-items here: it makes the CLI emit a trailing NextToken line,
        # which --output text renders as a second "None" line and corrupts the id.
        local build
        build=$(aws codebuild list-builds-for-project --project-name "$project" --region "$REGION" \
            --sort-order DESCENDING --query 'ids[0]' --output text 2>/dev/null)
        if [[ -n "$build" && "$build" != "None" ]]; then
            local detail
            detail=$(aws codebuild batch-get-builds --ids "$build" --region "$REGION" \
                --query 'builds[0].[buildStatus,currentPhase]' --output text 2>/dev/null)
            info "Latest build: $(echo "$detail" | tr '\t' ' ' | awk '{print $1" (phase "$2")"}')"
            echo "      ${YELLOW}Log:${NC} aws logs tail /aws/codebuild/workshop-tier1 --follow --region ${REGION}"
        fi
    fi

    local staged_ok=0
    local state_bucket
    state_bucket=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query "Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]" \
        --output text 2>/dev/null)
    if [[ -n "$state_bucket" && "$state_bucket" != "None" ]]; then
        info "State bucket: ${state_bucket}"
        aws s3 ls "s3://${state_bucket}/" --recursive 2>/dev/null | sed 's/^/      /'
        echo

        # Assert the artifacts, do not merely describe them. A CREATE_COMPLETE
        # stack holding only tier1/ is exactly the silent-success this branch
        # exists to eliminate — the build reported SUCCEEDED and staged nothing.
        local missing=""
        for prefix in tier1/ tier2/ tier2-private/; do
            if [[ -z "$(aws s3 ls "s3://${state_bucket}/${prefix}" 2>/dev/null)" ]]; then
                missing="${missing}${prefix} "
            fi
        done
        if [[ -z "$missing" ]]; then
            ok "all three prefixes staged: tier1/ tier2/ tier2-private/"
            staged_ok=1
        elif [[ "$final" == "CREATE_COMPLETE" ]]; then
            echo "  ${RED}✗ Stack is CREATE_COMPLETE but these prefixes are EMPTY: ${missing}${NC}" >&2
            echo "    ${YELLOW}Fix:${NC} the build reported success without staging. Read the build log —" >&2
            echo "         this is the silent-success failure mode, not a cosmetic gap." >&2
        else
            info "Not yet staged: ${missing}(expected while the build is still running)"
        fi
    fi

    if [[ "$final" == *FAILED* || "$final" == *ROLLBACK* ]]; then
        echo
        info "Most recent failure events:"
        aws cloudformation describe-stack-events --stack-name "$STACK" --region "$REGION" \
            --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
            --output text 2>/dev/null | head -5 | sed 's/^/      /'
        echo
        info "On a deliberate fault injection, a FAILED stack is the CORRECT result."
    fi

    [[ "$final" == "CREATE_COMPLETE" && "$staged_ok" -eq 1 ]]
}

if $STATUS_ONLY; then
    echo; echo "${BLUE}==============================================================================${NC}"
    echo "${BLUE}  STATUS — ${STACK} in ${REGION}${NC}"
    echo "${BLUE}==============================================================================${NC}"
    report
    exit $?
fi

#-------------------------------------------------------------------------------
# STEP 1 — Preflight. Fail here, not twenty minutes into a build.
#-------------------------------------------------------------------------------
step 1 "Preflight"

ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "No AWS credentials" "Authenticate, then re-run."
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
ok "AWS account ${ACCT} as ${CALLER_ARN}"

for t in aws terraform jq rsync rsvg-convert; do
    command -v "$t" >/dev/null 2>&1 || die "$t not found" "Install $t — package-assets.sh requires it."
done
ok "Required tooling present (aws, terraform, jq, rsync, rsvg-convert)"

# yq is optional to package-assets.sh but it is the ONLY thing that catches two
# buildspec faults CodeBuild reports at DOWNLOAD_SOURCE — after the stack is
# already CREATE_IN_PROGRESS and waiting on a callback that will never come.
if command -v yq >/dev/null 2>&1; then
    ok "yq present — the buildspec lint gate will run"
else
    warn "yq NOT installed: package-assets.sh will SKIP its buildspec lint."
    warn "A malformed buildspec would then fail at DOWNLOAD_SOURCE and hang the stack."
    warn "brew install yq"
fi

[[ -n "$ICR_KEY" ]]     || die "No ICR entitlement key" "Pass --icr-key KEY or export ICR_ENTITLEMENT_KEY."
[[ -n "$MMFA_SECRET" ]] || die "No MMFA push secret"    "Pass --mmfa-secret S or export IVIA_MMFA_PUSH_CLIENT_SECRET."
ok "Both IBM secrets supplied"

[[ -s "$LICENSE_PATH" ]] || die "Vault license missing or empty: ${LICENSE_PATH}" \
    "Pass --license PATH or export VAULT_ENTERPRISE_LICENSE_PATH."
LICENSE_BYTES=$(wc -c < "$LICENSE_PATH" | tr -d ' ')
# CloudFormation caps a String parameter at 4096 bytes. Catch it here; otherwise
# it surfaces as an opaque validation error mid-deploy.
[[ "$LICENSE_BYTES" -lt 4096 ]] || die \
    "License is ${LICENSE_BYTES} bytes — over CloudFormation's 4096-byte parameter limit" \
    "This delivery path cannot carry this license. Raise it before going further."
ok "Vault license ${LICENSE_PATH} (${LICENSE_BYTES} bytes, under the 4096 limit)"

BUCKET="cfn-sim-assets-${ACCT}-$(echo "$REGION" | tr -d '-')"
info "Stack        : ${STACK}"
info "Region       : ${REGION}"
info "Assets bucket: ${BUCKET}"
info "Assets prefix: ${ASSETS_PREFIX}"

# An existing stack CANNOT be reused. Tier1Deployment carries IgnoreUpdate: true,
# so a stack UPDATE is a deliberate no-op that never re-runs the build. Reusing a
# stack therefore looks like success while deploying and staging nothing at all.
if aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" >/dev/null 2>&1; then
    EXISTING=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query 'Stacks[0].StackStatus' --output text)
    die "Stack ${STACK} already exists (${EXISTING})" \
"IgnoreUpdate: true means an UPDATE will not re-run the build — you would get an
         updated stack and no deploy. Delete it and let it finish first:
           aws cloudformation delete-stack --stack-name ${STACK} --region ${REGION}
           aws cloudformation wait stack-delete-complete --stack-name ${STACK} --region ${REGION}"
fi
ok "No existing ${STACK} — a fresh CREATE will run the build"

pause "Preflight passed"

#-------------------------------------------------------------------------------
# STEP 2 — WSParticipantRole, mirroring what Workshop Studio hands an attendee.
#-------------------------------------------------------------------------------
step 2 "Simulated attendee role (WSParticipantRole)"

# Read the policy set out of contentspec.yaml rather than hardcoding it here, so
# this can never drift from what a real event actually grants.
POLICIES=$(grep -A20 'managedPolicies:' "${REPO_ROOT}/workshop/contentspec.yaml" \
    | grep -oE 'arn:aws:iam::aws:policy/[A-Za-z0-9]+' | sort -u)
POLICY_COUNT=$(printf '%s\n' "$POLICIES" | grep -c . )
# Assert the count. A regex that silently matched 5 of 6 would produce a role
# that looks right and quietly weakens every security assertion downstream.
[[ "$POLICY_COUNT" -eq 6 ]] || die \
    "Parsed ${POLICY_COUNT} managed policies from contentspec.yaml, expected 6" \
    "Either contentspec's participantRole changed (update this expectation deliberately) or the parse broke."
info "contentspec grants ${POLICY_COUNT} managed policies"

# Turn an assumed-role ARN into the underlying role ARN, so the trust policy
# names a principal that still exists after this session's credentials expire.
TRUST_ARN=$(echo "$CALLER_ARN" | sed -E 's|arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*|arn:aws:iam::\1:role/\2|')

if aws iam get-role --role-name WSParticipantRole >/dev/null 2>&1; then
    ok "WSParticipantRole exists — reconciling its policies"
else
    TRUST_DOC=$(jq -n --arg arn "$TRUST_ARN" '{
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { AWS: $arn },
            Action: ["sts:AssumeRole","sts:TagSession","sts:SetSourceIdentity"]
        }]
    }')
    aws iam create-role --role-name WSParticipantRole \
        --assume-role-policy-document "$TRUST_DOC" \
        --description "Simulated Workshop Studio attendee role (dev-sim only)" >/dev/null \
        || die "Could not create WSParticipantRole" "Check your IAM permissions."
    ok "WSParticipantRole created, trusting ${TRUST_ARN}"
fi

while read -r arn; do
    [[ -z "$arn" ]] && continue
    aws iam attach-role-policy --role-name WSParticipantRole --policy-arn "$arn" 2>/dev/null \
        || warn "attach returned non-zero for ${arn##*/} — the check below decides"
done <<< "$POLICIES"

# VERIFY, do not assume. This is the one step that must not lie: the security
# assertions in Part 4 are meaningless unless the role really carries all six.
ATTACHED=$(aws iam list-attached-role-policies --role-name WSParticipantRole \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | sort -u)
MISSING=$(comm -23 <(printf '%s\n' "$POLICIES") <(printf '%s\n' "$ATTACHED"))
[[ -z "$MISSING" ]] || die \
    "WSParticipantRole is missing $(printf '%s\n' "$MISSING" | grep -c .) of the 6 policies:
         $(printf '%s\n' "$MISSING" | sed 's|.*/||' | tr '\n' ' ')" \
    "Attach them by hand, or check your IAM permissions, then re-run."
ok "all ${POLICY_COUNT} policies verified present on WSParticipantRole"

# A WorkshopAthenaAudit inline policy left over from an earlier build would mask
# whether THIS build's put-role-policy actually ran. A real event starts without it.
if aws iam list-role-policies --role-name WSParticipantRole --query 'PolicyNames' \
    --output text 2>/dev/null | grep -q WorkshopAthenaAudit; then
    aws iam delete-role-policy --role-name WSParticipantRole --policy-name WorkshopAthenaAudit \
        && ok "removed stale inline WorkshopAthenaAudit (the build must re-add it)"
fi

pause "Attendee role ready"

#-------------------------------------------------------------------------------
# STEP 3 — Package and upload the assets CodeBuild will source.
#-------------------------------------------------------------------------------
step 3 "Package and upload assets"

if $SKIP_SYNC; then
    warn "--skip-sync: reusing whatever already sits in s3://${BUCKET}/${ASSETS_PREFIX}"
    warn "If you changed code since the last upload, this run tests the OLD code."
else
    # package-assets.sh rsyncs infrastructure/ and applications/ into
    # workshop/assets/terraform/ and runs the secret-leak, private-key and
    # keystore gates. It is what carries local code changes into what CodeBuild runs.
    info "Running package-assets.sh (syncs source into assets/, runs the leak gates)..."
    bash "${REPO_ROOT}/workshop/scripts/package-assets.sh" \
        || die "package-assets.sh failed" "Fix the gate failure it reported, then re-run."
    ok "Assets packaged, all leak gates passed"

    if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        ok "Assets bucket ${BUCKET} exists"
    else
        # us-east-1 must NOT be given a LocationConstraint; every other region must.
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
        else
            aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
                --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
        fi
        aws s3api put-bucket-encryption --bucket "$BUCKET" \
            --server-side-encryption-configuration \
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
        aws s3api put-public-access-block --bucket "$BUCKET" \
            --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
        ok "Assets bucket ${BUCKET} created (SSE-AES256, public access blocked)"
    fi

    aws s3 sync "${REPO_ROOT}/workshop/assets/" "s3://${BUCKET}/${ASSETS_PREFIX}" \
        --exclude 'cfn/*' --exclude '*/.terraform/*' --only-show-errors \
        || die "Asset upload failed" "Check your S3 permissions on ${BUCKET}."
    ok "Assets uploaded to s3://${BUCKET}/${ASSETS_PREFIX}"
fi

# The build cannot start without these two objects; a missing buildspec fails at
# DOWNLOAD_SOURCE and leaves the stack waiting on a callback that never arrives.
for key in "buildspec/buildspec.yml" "terraform/infrastructure/scripts/deploy-workshop.sh"; do
    aws s3api head-object --bucket "$BUCKET" --key "${ASSETS_PREFIX}${key}" >/dev/null 2>&1 \
        || die "Missing in S3: ${ASSETS_PREFIX}${key}" "Re-run without --skip-sync."
    ok "present: ${key}"
done

pause "Assets staged"

#-------------------------------------------------------------------------------
# STEP 4 — Deploy the stack. This is the step a Workshop Studio event performs.
#-------------------------------------------------------------------------------
step 4 "Deploy the CloudFormation stack"

mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/sim-deploy-$(date +%s).log"

# Secrets go to CloudFormation through a mode-600 file, NEVER as command-line
# arguments: arguments are world-readable through `ps` for the life of the call.
# jq --rawfile reads the license verbatim, so embedded newlines survive intact.
# The trap covers only the window before the deploy launches — dying at the
# STEP 4 prompt must not leave the file behind. Once the background job owns the
# file the trap is cleared, because an EXIT trap fires on Ctrl-C too and would
# otherwise delete the file out from under a deploy that is still reading it.
PARAMS_FILE="$(mktemp -t cfnparams)"
chmod 600 "$PARAMS_FILE"
trap 'rm -f "$PARAMS_FILE"' EXIT INT TERM

jq -n \
    --arg bucket "$BUCKET" \
    --arg prefix "$ASSETS_PREFIX" \
    --arg icr "$ICR_KEY" \
    --arg mmfa "$MMFA_SECRET" \
    --rawfile lic "$LICENSE_PATH" \
    '[
      {ParameterKey:"TerraformSourceBucket",    ParameterValue:$bucket},
      {ParameterKey:"AssetsKeyPrefix",          ParameterValue:$prefix},
      {ParameterKey:"AcmeEmail",                ParameterValue:""},
      {ParameterKey:"IcrEntitlementKey",        ParameterValue:$icr},
      {ParameterKey:"IviaMmfaPushClientSecret", ParameterValue:$mmfa},
      {ParameterKey:"VaultEnterpriseLicense",   ParameterValue:$lic}
    ]' > "$PARAMS_FILE" || die "Could not build the parameters file"
ok "Parameters written to a mode-600 temp file (nothing secret on the command line)"

info "The stack stays CREATE_IN_PROGRESS until the CodeBuild callback fires:"
info "tier 1 (~17 min) then tier 2 (~15 min). Budget 35-45 minutes."
pause "About to CREATE the stack"

# Backgrounded so Ctrl-C at any later prompt leaves the deploy running. A
# background job in a non-interactive shell ignores SIGINT, so Ctrl-C reaches
# only this script. The subshell owns the parameters file and shreds it when the
# CLI is finished with it, which is why the parent clears its trap below.
(
    aws cloudformation deploy \
        --template-file "${REPO_ROOT}/workshop/static/cfn/bootstrap.yaml" \
        --stack-name "$STACK" \
        --region "$REGION" \
        --capabilities CAPABILITY_NAMED_IAM \
        --no-fail-on-empty-changeset \
        --parameter-overrides "file://${PARAMS_FILE}"
    _rc=$?
    rm -f "$PARAMS_FILE"
    exit "$_rc"
) > "$LOG" 2>&1 &
DEPLOY_PID=$!
trap - EXIT INT TERM
ok "Deploy running in the background (pid ${DEPLOY_PID})"
echo
echo "  ${YELLOW}Watch the deploy:${NC}  tail -f ${LOG}"
echo "  ${YELLOW}Watch the build:${NC}   aws logs tail /aws/codebuild/workshop-tier1 --follow --region ${REGION}"
echo "  ${YELLOW}Check any time:${NC}    ${BASH_SOURCE[0]} --status"

#-------------------------------------------------------------------------------
# STEP 5 — Follow it. Ctrl-C here is safe; the deploy keeps going.
#-------------------------------------------------------------------------------
step 5 "Follow the build"

echo
echo "  The line that matters, near the end of tier 2:"
echo "    ${GREEN}PASS${NC} Gate: Tier-2 exit contract (Vault issuer_id = https://wrp.<id>.<ip>.nip.io)"
echo
info "Polling every 60s. Ctrl-C is safe — the deploy continues without this script."
echo

LAST=""
while kill -0 "$DEPLOY_PID" 2>/dev/null; do
    NOW=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "PENDING")
    if [[ "$NOW" != "$LAST" ]]; then
        echo "  $(date '+%H:%M:%S')  ${NOW}"
        LAST="$NOW"
    fi
    sleep 60
done

wait "$DEPLOY_PID"
DEPLOY_RC=$?

#-------------------------------------------------------------------------------
# STEP 6 — Result.
#-------------------------------------------------------------------------------
step 6 "Result"

if report; then
    echo
    ok "Simulation complete — tier 1 and tier 2 are provisioned."
    ok "Next: assume WSParticipantRole and run the attendee checks."
    exit 0
else
    echo
    warn "Deploy exited ${DEPLOY_RC}. Full output: ${LOG}"
    exit 1
fi
