# Workshop Testing Playbook

The single document for testing this workshop. It covers both audiences (at an event, self-paced), both environments (AWS CloudShell, your own terminal or IDE), and the full clean-slate cycle.

**The page is the contract.** Run the exact commands from `workshop/content/**/index.en.md`, in order, as written. Never substitute a homemade one-liner or a wrapper script. If a page's command fails, that *is* the finding.

---

## Pick your cell before you start

**ALWAYS ASK. This is a gate, not a preference.** The workshop has four paths, and the
first thing any test run does — before Phase 0, before the log, before the dashboard — is
put the four to Bear with `AskUserQuestion` and wait for his answer. Never infer the cell
from a previous run, a skill argument, a compacted summary, or what was standing in the
account. A run started on the wrong cell measures the wrong workshop and has to be thrown
away.

Four combinations. They diverge in three places and rejoin at **Configure kubectl**.

|                  | **CloudShell** | **Your own terminal / IDE** |
|---|---|---|
| **At an event**  | The default. Console session credentials, nothing to configure. | **At an Event** Step 5 — the short-term `WSParticipantRole` credentials from the event page's AWS CLI credentials panel. |
| **Self-paced**   | Supported — **Self-paced AWS Account** Step 1 says to skip the configuration. | The default. macOS or Linux only. **Self-paced AWS Account** Step 1 covers SSO, access keys and an existing profile. |

Credentials are the first thing to get right in every cell — the pre-flight checker, `bootstrap.sh` and every `terraform apply` run as whatever the CLI is configured with. Test that step before anything else.

**Where the paths split:**

| Split | At an event | Self-paced |
|---|---|---|
| Prerequisites | `20-prerequisites/21-at-an-event` — **At an Event** | `20-prerequisites/21-aws-account` — **Self-paced AWS Account** |
| Pre-flight | `20-prerequisites/23-pre-flight-checks` — **Run Pre-flight Checks**, one page with CloudShell / laptop tabs | same page, same tabs |
| Deploy | `30-deploy-foundation/31-deploy-at-an-event` — **Deploy — At an Event** (pull staged tier-1 state, then run tiers 2 and 3) | `30-deploy-foundation/31-deploy-self-paced` — **Deploy — Self-paced** (run all three tiers) |

`30-deploy-foundation` — **Deploy Foundation** is a two-button chooser; pick the button matching your audience.

Everything from `30-deploy-foundation/32-configure-kubectl` — **Configure kubectl** onward is one shared path through `80-cleanup` — **Cleanup**.

**Two more forks to settle in the same question**, because they change which commands run:

| Fork | Values | Where it bites |
|---|---|---|
| Image source | `ecr` (default — build the five images and push to your own ECR; needs a container runtime) · `ghcr` (`--image-source=ghcr`, pre-built public images, no build) | Pre-flight and Tier 1 |
| Use Case 3 enrollment | real phone (scan the QR, tap Approve on the CIBA push) · `--no-phone` substitute | The six Use Case 3 pages |

**The environment tabs sync.** Pre-flight uses `groupId="workshop-env"`, so picking CloudShell on one tab block selects it on the other. A page you tested on one tab is half tested — say which tab you were on.

---

## Setup

1. Work from a fork of `https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault`.
2. Sync your fork's `main` with upstream before each session.
3. Clone it where you will run the workshop — the pre-flight page does this for you, and the block is idempotent.

**Region — everything is `us-east-1`.** `workshop/contentspec.yaml` declares `accessibleRegions` and `deployableRegions` as `us-east-1` only, with `maxAccessibleRegions: 1`, and `infrastructure/terraform.tfvars` sets both `region` and `kb_region` to it. The Nova 2 embedding model the Knowledge Base needs exists only there. There is no second region to get wrong.

**Tools.** The pre-flight script installs them all — there are no manual install steps. It expects `kubectl` 1.34.x, `helm` 3.12+, `terraform` 1.10+, `vault` 1.20.4+, `aws` CLI v2, `jq`, and `yq`. CloudShell ships `aws`, `git`, `jq`, `kubectl` and a running Docker daemon; the script installs the rest.

---

## Invariants — these are what make it a test and not a demo

1. **Run the page verbatim.** Never author a script or a convenience wrapper. The only exception is a clearly-labelled ad-hoc diagnostic while actively troubleshooting a failure.
2. **Verify the cluster context before any `kubectl`, `helm`, or Kubernetes-provider `terraform` call.** This repo is AWS: the context is `workshop` or an `arn:aws:eks:*` ARN. Never a `gke_*` context.
3. **Keep full, untruncated output.** A trimmed log is not evidence. Redact before anything leaves the terminal: AWS account IDs, ARNs, access keys, JWTs and bearer tokens, private IPs, and the **Vault root token** — several pages print it to stdout by design.
4. **Stream every command to one tail-able log**, and hand over its `tail -f` before anything runs — see *Start of run* below. Output nobody can watch does not count as evidence.
5. **Keep the dashboard true, writing after every step** — see *Start of run* and *Reporting every step* below. A stale board reads as no progress and is worse than no board.
6. **Say which step is running, for every step**, before it runs — see *Reporting every step* below.
7. **Never mark a page done on evidence you have not just seen.** The commands must be in *this* run's log. A log from an earlier run does not count. Re-running a passing page costs minutes; a false green costs the workshop.
8. **The self-paced run is measured, not repaired — no fixes mid-run.** Self-paced is the proof that someone on a laptop gets through with nothing but the pages. Patch a script or hand-run a command the page does not contain and you stop measuring that. A break is a **finding**: logged, filed, reported. Fixes happen after the run ends.
9. **Everywhere else, a defect gets fixed, not worked around** — fix the page or the script, one atomic commit, then re-run that page. Never "pre-existing", never a cheat path.
10. **Nothing merges or closes on a green test run.** A passing run means *ready to verify*, nothing more.

---

**The run is autonomous. Ask the path, then do not stop again.** Once Bear has chosen
the cell, the run goes from Phase 0 to the end of Phase 3 without a single question. Every
decision inside the run is mine to make from the pages, the scripts and the repo: which
command comes next, what a documented flag is for, whether a prompt takes the value the
page already names, how to read an error. A question mid-run is a defect in my preparation,
not diligence. The two exceptions are a genuine external blocker I cannot act on (a
credential only Bear holds, an account-level denial) and something destructive. Everything
else: decide, run it, record what happened, keep going. (Stated 2026-09-28 — "I need you to
run this test autonomously, you have all you need, you do not need to stop to ask me
questions. That is how i want the playbook to be from now on.")

**Findings are Bear's call, not mine — but they do not stop the run.** When something
looks like a break, I record it in the walkthrough log, keep going, and put the whole list
to him at the end for his verdict. Nothing is written to the dashboard's Findings section
until he agrees it is one. A wrong entry at the top of that
page is worse than no entry: it is the first thing anyone reads, and it sends colleagues
chasing a defect that does not exist. (Stated 2026-09-28, after I filed the CloudShell
licence upload as a finding when the upload does exactly what the page says.)

## Start of run — three things, in this order, before Phase 0

**1. Open the walkthrough log and hand over its `tail -f` immediately.** This is the first thing said in a run, before Phase 0 and before any command:

```bash
mkdir -p infrastructure/scripts/logs && echo "infrastructure/scripts/logs/walkthrough-$(date +%s).log"
```

Every command from then on streams to that one file with `tee -a`, and its `tail -f <full path>` goes in chat **once, at the top**, never at the end and never on request. Long steps additionally run in the background. A run whose output cannot be watched live is not a test.

**2. Publish the status dashboard, before Phase 0.** One durable artifact, reused every run — never a new one, or the tab already open stops updating:

> https://claude.ai/artifact/1oFRtqkiutNzyehCprwiuE

Read it first, then republish onto what comes back. Keep the title `Clean-Slate Provisioning Run` and the 🧪 favicon stable — the tab is found by its icon. The page is a static shell published with `capabilities: {db: {}}` that renders from the artifact's own database via `onSnapshot`: a `write_db` updates the open tab instantly with no republish. **Structure is data, not markup** — a new workshop page is one more document, never a page edit. Republish the HTML only to change the design.

The dashboard is Bear's own tool. He uses it, as the workshop's admin and author, to follow a test run step by step; attendees never see it. Work on the dashboard or on this playbook gets no GitHub issue. Once Bear approves a change, commit it and push the branch without asking.

Seed the run, then write state as it changes:

| Document | Carries |
|---|---|
| `config/current` | `{runId}` — the pointer the page reads first |
| `runs/<runId>` | `label, startedAt, updatedAt, branch, commit, cluster, region, identity, currentPhase, questionTitle, question, logPath` |
| `runs/<runId>/phases/<id>` | `order, track` (`phase0`/`A`/`B`), `trackLabel` (first phase of a track only), `code` (the **page title**), `step` (that page's **step heading**), `sub` (the **sub-task** under that step, `''` when the document is the whole step), `name` (`Page › Step › Sub-task`, for the log), `does, cmd, state` (`queued`/`running`/`done`/`failed`/`skipped`), `proof` (array of `{label, value}`), and `trackNoteTitle`/`trackNote` for a track's known-limitation callout |
| `runs/<runId>/findings/<id>` | `order, tone` (`good`/`warn`/`info`), `title, body, proof` |

**Group by the workshop, never by invention.** One phase document is one sub-task: one command block, or one browser action, under one of the page's steps. The dashboard nests them as **Page › Step › Sub-task**. Each page is a collapsible block with a done/total count, its steps are headings inside it, and the sub-task rows sit under each step. So the three names are copied, not written:
- `code` is the page's `title:` front-matter.
- `step` is the page's own `###` heading, verbatim, including its `Step N —` prefix when it has one.
- `sub` is the page's words for the block under that heading: its `####` heading, or its lead-in sentence cut to a short imperative.

A heading with a single command block gets one document with `sub: ''`. A step the cell does not run is seeded `skipped` with the reason as its proof — never deleted, because the count is only honest if every step the page has is on the board. Seed every page's documents at the start of the run, in page order, so `order` follows the workshop.

Moving a phase is one `write_db` `update` on its phase document, with `currentPhase` and `updatedAt` on the run in the same batch.

**3. Then Phase 0.**

---

## Reporting every step

**Before a step runs**, in chat — not only at phase boundaries:

- **Where it is, as `Page › Step › Sub-task`**, each part spelled exactly as the page and the dashboard spell it (*Credential Revocation › Step 6 — Find the issuance event in the audit log (Athena) › Query recent issuances*), plus the page's position in the phase (*page 3 of 6*). Never a name of your own.
- **The command lines that step will run, as bullets** — the actual commands, before they run, so they can be stopped if wrong. Never a prose summary of them.
- **What it proves**, in one plain line.
- **What is queued behind it.**

**After a step runs**: its full untruncated output, and one `write_db` to the dashboard — immediately, not batched, not at the phase boundary. A phase of six pages gets six writes, each carrying that page's own proof. A long-running step gets one write at `running` and another when it lands.

**Never ask before a dashboard write.** Keeping the board true is part of the run, not a change that needs approval. The four ways a row goes stale, and the rule against each:

- **A skipped step's reason goes in `proof`.** The page renders `proof` and nothing else, so a reason left in `note` or any other field is invisible and the row reads as skipped for no reason.
- **Never assign a step to Bear unless he said he will do it.** A row that says "for Bear" or "Bear confirms by hand" about a step he never took on is false.
- **A re-run updates its row in the same turn.** When a page command is run again later — for example the correlation query after a new refund — append that result to the row's `proof` with a label saying what triggered the re-run. Never leave the earlier result standing alone.
- **`currentPhase` names what was skipped.** "All steps done" is only true when nothing is `skipped`. Otherwise it says which steps were skipped and why, in a few words.

The tail shows raw output; it does not say where in the plan the run is. Both are required, and neither substitutes for the other.

---

## Three modes — pick before Phase 0

| Mode | When | What runs |
|---|---|---|
| **Full cycle** | Anything below the pages changed — Terraform, Helm values, module inputs, deploy/teardown script *logic*, image builds — or no environment is standing, or the last validated run is unknown. | Phase 0 → Phase 3, everything below. |
| **Full content pass** | Every page has to be read and run, and the environment standing in front of you is the one to run them against. Typically a branch that changed so much that "only the changed pages" is every page anyway, and whose infrastructure changes were already exercised live, in place, against that same environment. | **Every** page, in workshop order, verbatim, against the running environment. No teardown, no deploy. |
| **Changed-pages pass** | The environment is up and already validated, and the diff since it touches **only** `workshop/content/**` prose and commands, or message strings in scripts. | Only the changed pages, against the running environment. No teardown, no deploy. |

When in doubt it is a full cycle. **Neither content mode proves a clean-slate deploy, and neither substitutes for one.** The failures that only surface on a fresh `terraform init` / `apply` — a `removed` block, a `required_version` raise, a provider constraint, a first-time resource ordering — cannot be reached from a standing environment at all. A content pass that should have been a full cycle reports green on infrastructure nobody tested; a content pass that is *honest about that gap* is a legitimate pre-PR gate on the pages.

---

## Full content pass — every page, standing environment

**Prove the environment first** — the same four checks as the changed-pages pass below. All four must hold, or this is a full cycle.

**Then walk every page**, in the workshop's own order, exactly as a full cycle walks them — but starting at Phase 2 rather than Phase 0, because the environment is already deployed:

1. **Phase 1's pages, read only.** **Run Pre-flight Checks**, the **Deploy** page for your audience, and **Configure kubectl** are already satisfied by the standing environment. Read them end to end against the rendered preview and re-run only the commands that are safe to repeat on a live cluster — the clone block, `aws sts get-caller-identity`, the kubeconfig write. Never re-run a deploy. Say in the report that these pages were read, not executed.
2. **Phase 2 and Phase 3 in full** — every page, every command, verbatim, in order. A page is tested as a page, not as a diff.

**Browser pages are driven in Chrome, by you, before they reach anybody.** A CLI-only pass does not test them. Every page whose step is something a person does in a browser gets opened, clicked through and seen: the sign-in, the transactions card, the persona menu at the lower left and what it opens, the token views, the refund chat's typed row number, the Security Flow's Story and Technical views, and where **Log out** actually is. Record what you saw, not that you looked.

**The report names the gap in one line, precisely.** Not "infrastructure was not tested" — that is usually false, because the infrastructure changes were exercised live. The true statement is narrower: *no clean-slate deploy ran, so the fresh-`init` behaviour of the Terraform changes is unproven*. Name which changes those are.

---

## Changed-pages pass — the changed pages only

**Prove the environment first.** All four must hold, or this is a full cycle:

```bash
kubectl config current-context &&   kubectl get nodes &&   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded &&   aws sts get-caller-identity
```

The context is `workshop`, `ars-workshop` or an `arn:aws:eks:*` ARN — never a `gke_*` one; nodes are `Ready`; nothing unexpected is non-Running; the identity is the one that owns the deploy.

**Establish the baseline.** The last validated run's commit is on the dashboard, in `runs/<runId>.commit`. Read it; do not guess one.

```bash
git diff --stat <baseline-commit>...HEAD -- workshop/content/ infrastructure/scripts/
```

**Classify every changed file before running anything.** If any of these appear, stop and run the full cycle instead:

- `*.tf`, `*.tfvars`, anything under `infrastructure/modules/` or `infrastructure/vault-config/`
- Helm values, Kubernetes manifests, Dockerfiles, anything that changes an image
- **Behaviour** in a deploy or teardown script — a new flag, a changed gate, a reordered step. A changed `print_fail` *message* is content; a changed condition is not.

**Then run the changed pages.** For each one, in the workshop's own page order, with the same reporting and the same dashboard write as any other step: execute its commands verbatim, including the ones that did not change, because a page is tested as a page and not as a diff. A page whose only change is prose still gets read end to end in the browser against the rendered preview.

The dashboard's phases for a changed-pages pass are the changed pages themselves, seeded Page › Step › Sub-task like any other run — the data model takes any phase list. For a full content pass they are every page, in workshop order.

**Every invariant above still applies**, including that a break on the self-paced path is a finding rather than something fixed mid-run.

**Say what was not covered.** A changed-pages pass proves the changed pages and nothing else. The report names the mode, so nobody reads it as a clean-slate result.

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

It backgrounds the deploy and prints two watch commands as it starts. Hand both over in chat immediately, alongside the walkthrough log:

```bash
aws logs tail /aws/codebuild/workshop-tier1 --follow --region us-east-1
```

That is the CodeBuild build itself — the log group is declared at `workshop/static/cfn/bootstrap.yaml:207`. The simulator's own local log is the second, printed as `tail -f <repo>/workshop/scripts/logs/<name>.log` when it starts; `bash workshop/cfn-wrapper/sim-workshop-studio.sh --status` reprints both at any time.

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
- **Use Case 2 — OAuth Personalized Read-only:** **OAuth Login Flow**, **Configure the OAuth Resource Server**, **Verify Per-User Data Access**, **Scope Enforcement (Layer 2)**, **Credential Revocation**. Start the first sign-in in a **fresh incognito window**; switch personas with a *new* incognito window, never Log out — IVIA keeps its own SSO cookie. **Log out** lives in the persona menu: click your photo and name at the bottom left of the dashboard.
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
- **`verify-uc3.sh --bypass` reports far fewer checks than a normal run.** Bypass mode terminates at `infrastructure/scripts/verify-uc3.sh:1111` so it never falls through into the normal-mode checks. Observed on Vault Enterprise 2.1.1: `--bypass` 9 checks, a normal run 19, and 20 when a real CIBA refund preceded it and the Athena correlation row exists. The mandatory-RAR assertion (`optional_authorization_details=false` on registration `uc3-actor`) is a normal-mode check and is *absent*, not failing, in bypass output.
- **Athena's correlation row is empty immediately after a refund.** Firehose buffers for 60 s (`infrastructure/modules/observability/main.tf`), so the audit rows land about a minute after the turn. Re-run the query; do not file it.
- **`localhost:8200/ui` not opening from CloudShell.** `localhost` is the CloudShell container, not the machine your browser runs on. The `vault` CLI reads are the lesson and work identically either way.

---

## Definition of done

**Per page:** every command on it run against live AWS, the real output seen, both the golden path and the obvious edge case tried — and the cell you covered stated (audience × environment, and which tab on a tabbed page).

**Per full cycle:** every page's commands executed with the expected output, defects fixed and re-run, then a plain-English report — what works, what does not, what needs a decision. Nothing merges or closes on it.

**Per changed-pages pass:** every changed page run end to end, the baseline commit named, and the report saying plainly that infrastructure was not re-tested.

**Per full content pass:** every page run end to end against the standing environment, every browser page driven in Chrome and what was seen recorded, the baseline commit named, and one precise line on the gap — which Terraform changes have never run from a fresh `init`.
