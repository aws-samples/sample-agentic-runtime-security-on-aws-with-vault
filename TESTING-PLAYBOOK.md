# Workshop Testing Playbook

The single document for testing this workshop. It covers both audiences (at an event, self-paced), both environments (AWS CloudShell, your own terminal or IDE), and the full clean-slate cycle.

**The page is the contract.** Run the exact commands from `workshop/content/**/index.en.md`, in order, as written. Never substitute a homemade one-liner or a wrapper script. If a page's command fails, that *is* the finding.

---

## Pick your cell before you start

Four combinations. They diverge in three places and rejoin at **Configure kubectl**.

|                  | **CloudShell** | **Your own terminal / IDE** |
|---|---|---|
| **At an event**  | The default. Console session credentials, nothing to configure. | Supported; you supply your own credentials. |
| **Self-paced**   | Supported. | The default. macOS or Linux; on Windows use WSL2. |

**Where the paths split:**

| Split | At an event | Self-paced |
|---|---|---|
| Prerequisites | `20-prerequisites/21-at-an-event` — **At an Event** | `20-prerequisites/21-aws-account` — **Self-paced AWS Account** |
| Pre-flight | `20-prerequisites/23-pre-flight-checks` — **Run Pre-flight Checks**, one page with CloudShell / laptop tabs | same page, same tabs |
| Deploy | `30-deploy-foundation/31-deploy-at-an-event` — **Deploy — At an Event** (pull staged tier-1 state, then run tiers 2 and 3) | `30-deploy-foundation/31-deploy-self-paced` — **Deploy — Self-paced** (run all three tiers) |

`30-deploy-foundation` — **Deploy Foundation** is a two-button chooser; pick the button matching your audience.

Everything from `30-deploy-foundation/32-configure-kubectl` — **Configure kubectl** onward is one shared path through `80-cleanup` — **Cleanup**.

**The environment tabs sync.** Pre-flight uses `groupId="workshop-env"`, so picking CloudShell on one tab block selects it on the other. A page you tested on one tab is half tested — say which tab you were on.

---

## Setup

1. Work from a fork of `https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault`.
2. Sync your fork's `main` with upstream before each session.
3. Clone it where you will run the workshop — the pre-flight page does this for you, and the block is idempotent.

**Region.** The workshop ships single-region: `workshop/contentspec.yaml` declares `accessibleRegions` and `deployableRegions` as `us-east-1` only, with `maxAccessibleRegions: 1`. Knowledge Base components (AOSS, Bedrock KB, the S3 corpus) are `us-east-1` regardless, because the Nova 2 embedding model is only there. Record the region you actually deployed into on every finding.

**Tools.** The pre-flight script installs them all — there are no manual install steps. It expects `kubectl` 1.34.x, `helm` 3.12+, `terraform` 1.10+, `vault` 1.20.4+, `aws` CLI v2, `jq`, and `yq`. CloudShell ships `aws`, `git`, `jq`, `kubectl` and a running Docker daemon; the script installs the rest.

---

## Invariants — these are what make it a test and not a demo

1. **Run the page verbatim.** Never author a script or a convenience wrapper. The only exception is a clearly-labelled ad-hoc diagnostic while actively troubleshooting a failure.
2. **Verify the cluster context before any `kubectl`, `helm`, or Kubernetes-provider `terraform` call.** This repo is AWS: the context is `workshop` or an `arn:aws:eks:*` ARN. Never a `gke_*` context.
3. **Keep full, untruncated output.** A trimmed log is not evidence. Redact before anything leaves the terminal: AWS account IDs, ARNs, access keys, JWTs and bearer tokens, private IPs, and the **Vault root token** — several pages print it to stdout by design.
4. **Stream every command to one tail-able log** — `infrastructure/scripts/logs/walkthrough-<ts>.log` via `tee -a`, created at cycle start, with its `tail -f` printed once. Long steps additionally run in the background.
5. **Say which step is running, for every step**, before it runs: page title and section as the page spells it, its position in the phase (*page 3 of 6*), the command lines as bullets, what it proves, and what is queued behind it.
6. **Never mark a page done on evidence you have not just seen.** The commands must be in *this* run's log. A log from an earlier run does not count. Re-running a passing page costs minutes; a false green costs the workshop.
7. **The self-paced run is measured, not repaired — no fixes mid-run.** Self-paced is the proof that someone on a laptop gets through with nothing but the pages. Patch a script or hand-run a command the page does not contain and you stop measuring that. A break is a **finding**: logged, filed, reported. Fixes happen after the run ends.
8. **Everywhere else, a defect gets fixed, not worked around** — fix the page or the script, one atomic commit, then re-run that page. Never "pre-existing", never a cheat path.
9. **Nothing merges or closes on a green test run.** A passing run means *ready to verify*, nothing more.

---

## Phase 0 — clean slate (both audiences, always)

```bash
bash infrastructure/scripts/teardown.sh --yes
```

Then confirm zero residuals: `aws eks list-clusters` empty, no workshop S3 buckets, no workshop ACM cert, no orphan ALB.

Wipe all **four** Terraform roots — `infrastructure`, `infrastructure/services`, `infrastructure/workloads`, `infrastructure/vault-config`:

```bash
rm -f terraform.tfstate* && rm -rf .terraform/
```

Then `rm -f infrastructure/.acme-state ~/vault-init.json`.

**At an event, additionally** — these sit outside the stack's resource graph and survive `delete-stack`: the sim assets bucket (`cfn-sim-assets-<acct>-<region>`), the CFN state bucket (`cfn-sim-atevent-statebucket-*`), and the EKS access entry the sim added for the caller principal.

---

## Phase 1 — deploy

**Self-paced** — walk the pages:
**Run Pre-flight Checks** → **Deploy — Self-paced** → **Configure kubectl**.

**At an event** — provisioning is CFN → Lambda → CodeBuild, exercised locally as the dev simulator:

```bash
bash workshop/cfn-wrapper/sim-workshop-studio.sh --yes
```

It deploys **tier 1 only** (`workshop/assets/buildspec/buildspec.yml:91` runs `deploy-workshop.sh --tier 1`) and stages only `tier1/terraform.tfstate` and `tier1/terraform.tfvars`. The attendee runs tiers 2 and 3 themselves — that is the lesson.

Judge progress by the **CodeBuild log, never the stack events** — CFN shows `CREATE_IN_PROGRESS` and nothing else for the whole build, by design. Tier 1 took ~18 min observed. The lines that matter at the end:

```
Tier-1 deploy complete.
State staged to s3://<state-bucket>/tier1/
```

Then the attendee pages: **At an Event** → **Run Pre-flight Checks** → **Deploy — At an Event** → **Configure kubectl**.

**The four attendee-denial assertions cannot run at an event as the code stands.** They assert a 403 on `tier2-private/terraform.tfstate`, a readable sanitized `tier2/` copy, and a secret scan of it — none of those objects exist now, because CodeBuild never deploys tier 2. Do not report them as passing, and do not treat their absence as a deploy failure.

---

## Phase 2 — verify the foundation (both audiences)

All six `33-verify-deployment` pages, in order:

**Verify Infrastructure** → **Ingest Knowledge Base** → **Validate Vault** → **Validate Identity Access** → **The OIDC Seam** → **Platform Health Check**.

---

## Phase 3 — the three use cases (both audiences)

- **Use Case 1 — Non-Personalized Read-Only:** **Request Flow**, **Configure Vault Auth for Use Case 1**, **Verify Credentials and Enforcement**.
- **Use Case 2 — OAuth Personalized Read-only:** **OAuth Login Flow**, **Configure the OAuth Resource Server**, **Verify Per-User Data Access**, **Scope Enforcement (Layer 2)**, **Credential Revocation**. Start the first sign-in in a **fresh incognito window**; switch personas with a *new* incognito window, never Logout — IVIA keeps its own SSO cookie.
- **Use Case 3 — Privileged Action with CIBA:** all six pages, see below.

**Stop before Cleanup** unless the run is explicitly a teardown test.

---

## Use Case 3 — the `--no-phone` rule, and what it does not replace

The CIBA approval runs through the virtual authenticator:

```bash
cd infrastructure/scripts && ./verify-uc3.sh --no-phone
```

It enrolls over the same OAuth + SCIM endpoints and signs the user-presence challenge, so no IBM Verify phone is needed, and it produces a real refund row.

**`--no-phone` substitutes for exactly two things:** the QR enrollment on **Enroll Your Device**, and the physical Approve tap in **Test the Refund Flow**. **Every other command on the Use Case 3 pages still runs verbatim:**

- **Test the Refund Flow** — the banking URL from `.acme-state`; the `mmfa_push_fired` log check (`--tail=-1` is load-bearing with `-l`).
- **CIBA Out-of-Band Approval** — uc3-agent pod Running; the OIDC discovery probe from `vault-0` returning `backchannel_authentication_endpoint`; the `mmfa_push_fired|ciba_status_polled` log grep.
- **Vault Enforces the RAR Ceiling** — port-forward plus `VAULT_ADDR` / `VAULT_TOKEN`; `vault read agent-registry/registration/display-name/uc3-actor`; `vault policy read uc3-agent-ceiling`; then the three `kubectl exec` reads (registration, `database/roles/uc3-refund-writer`, `database/creds/...` showing a 5-minute lease).
- **The Bypass Test** — `./verify-uc3.sh --bypass`, then the four transient `psql` pods: RLS scoping by sub, INSERT denied (`permission denied for table refunds`), find-refund, and a cross-owner read returning 0 rows while the owner read returns the row.
- **Three-Plane Audit Correlation** — `AWS_REGION` from Terraform output, the `athena_run` / `athena_query` / `athena_record` / `athena_scalar` helpers, capture `REQUEST_ID`, then the correlation row. Athena calls need `--work-group workshop`.

**Hazard:** `verify-uc3.sh` fires the push at the *first* enrolled device, so `--no-phone` must never race a real enrolled phone. Clean on a from-scratch build.

---

## Looks like a failure, is not

Check these before filing:

- **The clone block does nothing the second and third time.** It appears on three pages — **Run Pre-flight Checks** Step 2, **Self-paced AWS Account** Step 1, and **Deploy — At an Event** Step 1 — and is deliberately idempotent. Running it inside the repo is a no-op that exits 0.
- **`ERROR: no root token in ~/vault-init.json — the Tier-2 deploy has not run on this machine`** is the correct output when you reach a Vault page before tier 2 has run. It replaced a line that printed success on a missing file.
- **At an event, the pre-flight IAM simulation reports `implicitDeny`** on `iam:CreateRole`, `eks:CreateCluster`, `rds:CreateDBInstance`. The page tells you to re-run with `--skip-iam-sim` (add `--skip-quotas` if the quota section also denies). The authoritative permissions test is the deploy itself.
- **`terraform: command not found` in CloudShell after an idle disconnect.** Tools installed outside `$HOME` live on a non-persistent overlay. Re-run pre-flight Step 2. The license you uploaded and `~/vault-init.json` are in `$HOME` and survive.
- **`kubectl version --client` reporting something other than 1.34.x in CloudShell** — CloudShell's own newer binary in `/usr/local/bin` shadows the one the script installed in `/usr/bin`. The page gives the `ln -sf` fix.
- **The `mmfa_push_fired|ciba_status_polled` grep returning nothing** before any refund has run.
- **`localhost:8200/ui` not opening from CloudShell.** `localhost` is the CloudShell container, not the machine your browser runs on. The `vault` CLI reads are the lesson and work identically either way.

---

## Definition of done

**Per page:** every command on it run against live AWS, the real output seen, both the golden path and the obvious edge case tried — and the cell you covered stated (audience × environment, and which tab on a tabbed page).

**Per cycle:** every page's commands executed with the expected output, defects fixed and re-run, then a plain-English report — what works, what does not, what needs a decision. Nothing merges or closes on it.
