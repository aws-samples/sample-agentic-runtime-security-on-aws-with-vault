# Workshop content changes — at-an-event walkthrough (2026-08-10)

Compiled by running the content **verbatim as a simulated attendee** against a live account
where CodeBuild pre-provisioned **Tier 1 and Tier 2** (issue #21), then deploying Tier 3 by
hand. Identity throughout:
`arn:aws:sts::865855451418:assumed-role/WSParticipantRole/workshop-attendee-sim`,
region `us-east-1`, stack `cfn-sim-atevent`, cluster `ars-workshop`.

## Scope — what was and was not executed

| Pages | Status |
|---|---|
| `20-prerequisites` → `38-platform-health-check` | **Executed verbatim, every command** |
| `50-use-case-1` (`51`, `52`) | **Executed verbatim, every command** |
| Use Case 2 — all five pages | **Executed verbatim, every command** — including Step 5, run with both cookies from a live browser session you supplied |
| Use Case 3 — `72`, `73`, `74`, CIBA verification blocks | **Executed verbatim** |
| `74` correlation payload | **Partially blocked** — mechanics verified, but the row needs a completed CIBA refund |
| Human Needed (3 steps) | *Enroll Your Device* · *Test the Refund Flow* browser half · *The Bypass Test* Section 4 (all one chain: no refund exists until the phone tap) |
| `80-cleanup` | **Not run** — `teardown.sh --dry-run` only (see finding 6) |

Findings below are what the page said versus what actually came back.

## Completion tracker

**40 of 41 fixed and committed. 1 needs your decision (28).** Nothing has been pushed; no PR exists.

**Finding 39 is the most serious thing found in the whole walkthrough** — *Configure the OAuth
Resource Server* Step 5 failed with a 403 for **every** attendee who followed it, because it
named the wrong cookie. Proven both ways against one live browser session.

Findings 31–33 were found by **executing every bash block on every page I touched**, not just
the blocks I had edited. Findings 34–38 came from executing every Use Case 2 and Use Case 3
command against the live cluster.

The **Executed** column records a command actually run against the live cluster as
`WSParticipantRole` **after** the edit, and marked OK only where it exited 0 and returned what
the page now claims. `n/a` means the change was prose, a heading or a link, with no command to
run. **Human Needed** means the step requires a browser sign-in or a physical device and cannot
be automated — those are listed separately below, not counted as failures.

| # | Page / file | Change | Status | Commit | Executed |
|---|---|---|---|---|---|
| 1 | `20-prerequisites/21-at-an-event` | Tier 1 **and** Tier 2 pre-provisioned; work begins at Tier 3; drop the "have your key + licence ready" instruction; 17–22 min → ~40 min | ✅ Fixed | `b996107` | n/a (prose) |
| 2 | `20-prerequisites/22-ivia-licensing` | "(you supply this)" → "(self-paced: you supply this)" + at-an-event alert | ✅ Fixed | `b996107` | ✅ `openssl x509 … -noout -dates` |
| 3 | `20-prerequisites/23-pre-flight-checks` | Gate install/quota sections as self-paced | ✅ Fixed | `b996107` | ✅ tools verify · quota query · `--dry-run` · runtime probe |
| 4 | `30-deploy-foundation/index` | "deploy the entire stack with one command" → split by path | ✅ Fixed | `b996107` | n/a (prose) |
| 5 | `35-verify-vault` (intro) | Root token was pulled from S3 at an event, not written locally | ✅ Fixed | `b996107` | ✅ all 8 blocks on the page |
| 6 | `80-cleanup` | At-an-event alert: nothing to clean up; scope `teardown.sh` self-paced | ✅ Fixed | `b996107` | ✅ all 4 spot-checks (teardown itself **not** run) |
| 7 | `37-oidc-seam` line 6 | Named the `jwt` backend it contradicts 100 lines later | ✅ Fixed | `83da627` | n/a (prose) |
| 8 | `37-oidc-seam` Step 1 | Expected a `jwt/` mount that does not exist | ✅ Fixed | `83da627` | ✅ `vault auth list` — 2 mounts, no `jwt/` |
| 9 | `37-oidc-seam` Step 2 | 3 of 6 mounts shown; `agent-registry/` omitted | ✅ Fixed | `83da627` | ✅ `vault secrets list` — 6 mounts |
| 10 | `37-oidc-seam` Step 4 | `allowed_roles` missing `uc3-readonly` | ✅ Fixed | `83da627` | ✅ `vault read database/config/workshop-pg` — 4 roles |
| 11 | `37-oidc-seam` Step 5 | **Command errored (exit 5)** — added `--quiet` + `</dev/null` | ✅ Fixed | `83da627` | ✅ **exit 0** (was exit 5) |
| 12 | `37-oidc-seam` Step 5 | Expected issuer was ClusterIP; it is the public WRP host. `bound_issuer` → `issuer_id` | ✅ Fixed | `83da627` | ✅ returns the nip.io issuer |
| 13 | `31-deploy-at-an-event` | Vault `1.20.x+ent` → `2.0.3+ent` | ✅ Fixed | `6865910` | ✅ `vault status \| grep` — `2.0.3+ent` |
| 14 | `31-deploy-at-an-event` | "seven pods" → 8 rows; autoconf Job + `iviadsc` restarts added to looks-broken-isn't list | ✅ Fixed | `6865910` | ✅ `kubectl get pods -n verify-access` — 8 rows |
| 15 | `32-configure-kubectl` | `<region>.compute.internal` → `ec2.internal` for us-east-1 | ✅ Fixed | `6865910` | ✅ `kubectl get nodes` — `ec2.internal` |
| 16 | `35-verify-vault` Step 1 | "all three pods" → 4 rows (agent-injector) | ✅ Fixed | `6865910` | ✅ `kubectl get pods -n vault` — 4 rows |
| 17 | `35-verify-vault` Step 5 | Removed impossible `Build Date`; fixed `agent_registry` type + columns | ✅ Fixed | `6865910` | ✅ version + `secrets list` |
| 18 | `36-verify-identity-access` | `k8s-workshop-acme-*` → `k8s-workshopacme-*` | ✅ Fixed | `6865910` | ✅ `kubectl get ingress` — `k8s-workshopacme-…` |
| 19 | `38-platform-health-check` | **8 documented checks → 13**; dropped replica-dependent pod counts | ✅ Fixed | `6865910` | ✅ `test-vault-verify.sh` **exit 0, 13 passed** |
| 20 | `33-verify-infrastructure` | Added the OpenLDAP + Vault-native-surface sections | ✅ Fixed | `6865910` | ✅ `test-foundation.sh` — ALL passed, 0 FAIL/0 WARN |
| 21 | `bootstrap.sh` | Next-steps told at-an-event attendees to deploy all 3 tiers | ✅ Fixed | `a49aa7b` | ✅ `bootstrap.sh --skip-prereq-gate --image-source ecr` re-run **exit 0**; both paths render; tree stayed clean |
| 22 | `52-verify-credentials` Step 3 | **Returned nothing** — hardcoded `vault-0`; now reads all 3 Raft nodes | ✅ Fixed | `2580504` | ✅ returns the documented row (was empty) |
| 23 | `52-verify-credentials` Step 3 | **`jq` parse error** on non-JSON lines; added `grep` + `--tail=-1` | ✅ Fixed | `2580504` | ✅ no parse error across the window |
| 24 | `52-verify-credentials` Step 2 | Stale answer text + "schema public is empty" gloss | ✅ Fixed | `2580504` | ✅ `/query` returns `vault_authenticated: true` |
| 25 | `52-verify-credentials` Step 5 | 9 checks → 10; `v-kubernet-` → `v-root-` | ✅ Fixed | `2580504` | ✅ `verify-uc1.sh` — **10 checks passed** |
| 26 | `51-configure-vault-auth` Step 1 | `serviceaccount_uid` → `serviceaccount_name`; `policies` → `token_policies` | ✅ Fixed | `2580504` | ✅ `vault read auth/kubernetes/role/uc1` |
| 27 | `51-configure-vault-auth` Step 5 | `optional_authorization_details` `true` → `false` (confirmed against Terraform) | ✅ Fixed | `2580504` | ✅ `vault read agent-registry/…/uc1-agent` |
| 28 | Pages 51, 62, 72 | **`vault` CLI assumed but `--skip-prereq-gate` never installs it** | ⏸️ **Needs your decision** | — | ❌ not resolvable locally — needs the CloudShell image |
| 29 | `74-three-plane-audit` | Named all five `workshop_logs` catalog objects | ✅ Fixed | `d729c3f` | ✅ `SHOW TABLES` + both helper queries |
| 30 | `31-deploy-at-an-event` | Tier 3 "~5–10 min" → "~4–8 min" (measured 3m34s) | ✅ Fixed | `6865910` | n/a (prose) |
| 31 | `52-verify-credentials` (expand) | **`vault lease list` is not a Vault command** — exits 1 with a usage dump. `vault lease` has only `lookup`/`renew`/`revoke` | ✅ Fixed | `1ec6f52` | ✅ `vault list sys/leases/lookup/…` + `vault lease lookup <id>` both exit 0 |
| 32 | `31-deploy-at-an-event` | **Fallback bucket lookup matched nothing** — grepped `bootstrap-statebucket`; bucket is `<stack-name>-statebucket-<suffix>` | ✅ Fixed | `1ec6f52` | ✅ `aws s3 ls \| grep -i statebucket` returns the bucket |
| 33 | `21-aws-account` | **Regression I introduced** — renaming the licensing headings changed their anchors and broke the deep link | ✅ Fixed | `1ec6f52` | n/a (link) |
| 34 | **The Bypass Test** | **Documented script output is stale** — page showed 3 PASS lines, script emits 7 PASS + 1 WARN-skip; the `evil-actor` check the page presented as passing **does not run by default**. Rewritten around Checks 14/16/17/18, real expected output, a Check column on the denials table, and an alert explaining why 19 skips | ✅ Fixed | `5e5d1f8` | ✅ `verify-uc3.sh --bypass` exit 0, **7 checks** — page now matches |
| 35 | **Configure the OAuth Resource Server** Step 4 | Expected `creation_statements` shown as a 5-element JSON array with escaped quotes; the CLI prints **one** bracketed semicolon-separated string. Replaced with real output | ✅ Fixed | `057d7df` | ✅ `vault read database/roles/uc2-personal-readonly` exit 0 — matches |
| 36 | **CIBA Out-of-Band Approval** | 3 commands, **zero expected output**. Added expected output for the pod check and endpoint probe; alert for the log grep (empty + exit 1 until the phone step); widened `--tail=50` → `--tail=-1 --since=30m` | ✅ Fixed | `69a80e3` | ✅ all 3 re-run — exit 0 / 0 / 1-empty as now documented. The rewritten `--tail=-1 --since=30m` was then re-tested **unpiped** (`kubectl … >/dev/null; echo $?` → **0**, 240 lines) to prove the flags are valid and the exit 1 comes from `grep`, not from kubectl rejecting them |
| 37 | **Scope Enforcement** Step 2.3 | `\dp` output contains `v-JWT Toke-…` rows the page never showed — looks like corruption, is actually the OBO issuance at the DB layer. Documented both prefixes | ✅ Fixed | `69a80e3` | ✅ `v-JWT Toke-uc2-pers-…-1786459642` observed live |
| 38 | Every `kubectl run … psql` block (Use Case 2 + 3) | First run on a node that has not cached `postgres:16-alpine` loses the psql output to the attach race. Added a re-run note | ✅ Fixed | `69a80e3` | ✅ reproduced once, then 3/3 clean on re-run |
| 39 | **Configure the OAuth Resource Server** Step 5 | **BLOCKER — 403 for every attendee.** Page said copy the `id_token` cookie; it carries no `act` claim so Vault resolves no agent and fails closed. Must be **`access_token`**. Also `lease_renewable` `true` → `false` | ✅ Fixed | `057d7df` | ✅ **both cookies tested from one browser session** — `id_token` → 403, `access_token` → exit 0, `username=v-JWT Toke-uc2-pers-…` exactly as documented |
| 40 | **OAuth Login Flow** | Same defect in 3 places — 2 sequence-diagram Bearer arrows, step 8, and the claim-flow list all said the `id_token` is forwarded. It is the `access_token` | ✅ Fixed | `f9e8b14` | n/a (prose + diagram) — root cause confirmed in `api/chat/+server.ts` |
| 41 | **Scope Enforcement** — the finding-37 alert | The alert I added in `69a80e3` named the wrong Use Case 3 role: it said attendees may see `v-…-uc3-refu-…` on `banking.accounts`. Live ACL carries `v-root-uc3-read-…` (`uc3-readonly`). Both roles in fact hold `SELECT` on that table — `uc3-refund-writer`'s `INSERT`/`UPDATE` are scoped to `banking.refunds` alone. Names both, and turns the asymmetry into the point: the *write* role still reads `=r/` here | ✅ Fixed | `7c95828` | ✅ live `relacl` on `banking.accounts` + both roles' `creation_statements` from Vault config state |


**The one open item (28)** needs a fact I cannot get from here: whether the Workshop Studio
CloudShell image ships the `vault` CLI. If it does, nothing to do. If it does not, the fix is
to switch those pages to the `kubectl exec -n vault vault-0 -- vault …` form that page 72's own
Verification section already uses — no local CLI required. Say which and I will apply it.

**Still untested regardless of the above:** finding 6's permissions question, and every page
that needs a browser or a phone.

## The themes

1. **#21 moved Tier 2 into account setup, but only `31-deploy-at-an-event` was rewritten.**
   Five other pages still address an attendee who deploys Tier 2 themselves — including two
   prerequisite pages that send them to obtain licensing secrets they will never hold, and a
   cleanup page whose one command cannot work for them.
2. **The `jwt` auth backend was retired (decision (e)) but `37-the-oidc-seam` still teaches
   it** — while asserting the opposite three paragraphs later. `test-vault-verify.sh` now
   actively asserts the mount is *absent*, so the page contradicts the tooling too.
3. **Two Use Case 1 commands fail against a healthy system** — one because Vault is 3-node HA
   and the page hardcodes `vault-0`, one because raw `kubectl logs` is piped into `jq`.

Status key: **BLOCKER** = attendee is told to do something impossible, is asked for a secret
they don't have, or runs a command that errors · **WRONG** = factually incorrect ·
**GAP** = missing at-an-event guidance or missing from a documented list.

---

# Part 1 — Pages that still assume the attendee deploys Tier 2

## 1. `20-prerequisites/21-at-an-event/index.en.md` — BLOCKER

| Line | Current | Change to |
|---|---|---|
| 57 | alert header `Tier-1 infrastructure is pre-provisioned — you run tier-2 and tier-3` | `Tier-1 and Tier-2 are pre-provisioned — you run Tier 3` |
| 58 | "deployed the workshop's **Tier 1** foundation" | "…**Tier 1** foundation **and Tier 2** (Vault + IBM Verify Identity Access)" |
| 65 | "approximately 17–22 minutes" | ~40 min. Measured live 2026-08-10: build **40m29s** end to end. |
| 67 | "**Your hands-on work begins at Tier 2** … Those two tiers … are what you deploy" | "Your hands-on work begins at **Tier 3**. You verify the Tier-2 identity substrate rather than deploying it." |
| 70 | "pull the Tier-1 state and run Tier 2 and Tier 3" | "pull the pre-provisioned state and run Tier 3" |
| 74 | tells the attendee to have the entitlement key + `.hclic` ready | **Delete.** The organizer supplies all three secrets once at stack create; the attendee never holds them. |
| 76 | "where you pull the Tier-1 state and run Tier 2 and Tier 3" | "…pull the pre-provisioned state and run Tier 3" |

**GAP** — the "already provisioned" list (lines 60–63) stops at Tier 1. Add: Vault HA +
Agent Registry, IVIA (8 pods), the Let's Encrypt `nip.io` certificate, and the five Use Case
container images already in the account's ECR.

## 2. `20-prerequisites/22-ivia-licensing/index.en.md` — BLOCKER

Two of three headings read literally `(you supply this)`. At an event the attendee supplies
**nothing**. Line 10's "deploy-workshop.sh prompts you for it on its first run" and line 38's
"reads it from a file on every Tier-2 run" are both self-paced-only.

**Change:** open with an at-an-event alert — you supply nothing, this page is background —
and retitle both sections `(self-paced: you supply this)`.

## 3. `20-prerequisites/23-pre-flight-checks/index.en.md` — WRONG

Tells everyone to run `check-prerequisites.sh`. At an event that is wrong twice: CloudShell
already has the tooling, and the quota table (lines 37–43) describes capacity **account setup
already consumed**. The at-an-event deploy page deliberately passes
`bootstrap.sh --skip-prereq-gate` for this reason.

**Change:** gate the CLI-tools, pre-flight and quota sections as self-paced — line 61 already
does this correctly for the container runtime (`## Self-paced: container runtime`), so follow
that established pattern — and add a short at-an-event note: nothing to install, quotas
already provisioned, continue to Deploy.

⚠️ **See finding 28** — `--skip-prereq-gate` is also what skips the `vault` CLI install that
three later pages depend on. Resolve 28 before rewriting this page.

## 4. `30-deploy-foundation/index.en.md` — WRONG

Line 6: "In this module you deploy the entire workshop stack — VPC, EKS, RDS, Bedrock
Knowledge Base, Vault, IBM Verify Identity Access, and the Use Case workloads — **with one
command**". At an event everything through IVIA already exists, and it was not one command.

**Change:** split by path — self-paced deploys all three tiers; at an event you verify
Tiers 1–2 and deploy Tier 3.

## 5. `30-deploy-foundation/35-verify-vault/index.en.md` — WRONG

Line 6 ("deployed … by `terraform apply` plus `deploy-workshop.sh`") and line 11
("`vault-init.sh` … wrote the Vault root token to `~/vault-init.json` during
initialization"). At an event neither ran on the attendee's machine — the token was written
inside the CodeBuild container and **pulled from S3** in Step 3 of the deploy page. An
attendee who loses the file goes hunting for a `vault-init.sh` run that never happened.

**Change:** "At an event you pulled `~/vault-init.json` from the state bucket in Step 3 of
[Deploy — At an Event]; self-paced, `vault-init.sh` wrote it during Tier 2."

## 6. `80-cleanup/index.en.md` — BLOCKER + GAP

One path only: `bash infrastructure/scripts/teardown.sh`. At an event that is wrong:

- The attendee's Tier-2 state is the **outputs-only** copy (`"resources": []`), so
  `terraform destroy` on `services/` reconciles nothing — the IVIA/Vault PVCs, their EBS
  volumes and the WRP ALB would all be missed. **Proven** from the staged artifact.
- It is unnecessary: the account is reclaimed automatically, and the CloudFormation stack's
  `BuildOnDelete` teardown build is what actually tears the environment down.

**Not established — do not put in the page without testing:** whether `WSParticipantRole`
holds the IAM/KMS delete permissions the sweep needs. I ran `teardown.sh --dry-run` as
`WSParticipantRole` (exit 0), but **that proves nothing about permissions** — dry-run is a
static print that makes **no AWS API calls at all**; its entire output is 10 `[DRY-RUN]
Would …` lines. Settling it requires a real teardown, which was not run.

**Change:** lead with an at-an-event alert — no cleanup action required — and scope the whole
`teardown.sh` walkthrough as self-paced.

---

# Part 2 — `37-the-oidc-seam` teaches a backend that no longer exists

This page is the most out-of-date in the workshop, and it **contradicts itself**.

## 7. Line 6 contradicts Step 3 on the same page — WRONG

> Line 6: "`deploy-workshop.sh` already wired Vault's **`jwt` auth backend** to trust IVIA"
> Line 110: "Vault Enterprise validates the IVIA-issued OAuth JWT directly through its
> **OAuth resource server** profile (`ivia`) — **there is no `jwt` auth backend to
> configure.**"

Line 110 is correct. **Change line 6** to name the OAuth resource server.

## 8. Step 1's expected output lists a mount that does not exist — BLOCKER

Page (lines 84–89) expects three rows including `jwt/`. Live:

```
Path           Type          Accessor                    Description                Version
----           ----          --------                    -----------                -------
kubernetes/    kubernetes    auth_kubernetes_90e9d8e6    n/a                        n/a
token/         token         auth_token_a46f97c3         token based credentials    n/a
```

No `jwt/`. `test-vault-verify.sh` **asserts** its absence:
`✓ PASS jwt/ auth mount is ABSENT — retired IVIA jwt backend removed (decision (e) cutover proof)`.
An attendee diffing against the page sees a missing row and concludes the deploy is broken.
The page also omits the `Version` column and mislabels `kubernetes/`'s description (actual
`n/a`, not "Kubernetes workload auth").

Note `62-configure-oauth-resource-server` Step 1 already documents this **correctly** — same
command, right answer. Page 37 is the outlier.

## 9. Step 2's expected output omits half the mounts — WRONG

Page shows three (`aws/`, `database/`, `sys/`). Live shows **six**:

```
Path               Type              Accessor                   Description
agent-registry/    agent_registry    agent-registry_ac5f78c5    agent registry
aws/               aws               aws_63e86f2c               n/a
cubbyhole/         cubbyhole         cubbyhole_97a5154a         per-token private secret storage
database/          database          database_a9c96df8          n/a
identity/          identity          identity_edccc1fa          identity store
sys/               system            system_ea5dbd46            system endpoints used ...
```

Missing `agent-registry/`, `cubbyhole/`, `identity/`; no Accessor column; and the invented
descriptions ("Dynamic IAM credentials", "Dynamic PostgreSQL credentials") are actually `n/a`.
Omitting `agent-registry/` is the notable one — it is the engine the workshop exists to teach.

## 10. Step 4's `allowed_roles` is missing a role — WRONG

Page: `uc1-readonly, uc2-personal-readonly, uc3-refund-writer`. Live — **four**, and
bracket/space formatted, not comma:

```
allowed_roles    [uc1-readonly uc2-personal-readonly uc3-refund-writer uc3-readonly]
```

`uc3-readonly` is absent from the page.

## 11. Step 5's command is BROKEN — it errors for every attendee — BLOCKER

Ran verbatim; **exit code 5**:

```
jq: parse error: Invalid numeric literal at line 2, column 4
```

Cause: the command omits `--quiet` and `</dev/null`, so `kubectl run`'s pod-lifecycle
message (`pod "oidc-check" deleted`) lands in the `jq` pipe. **`36-verify-identity-access`
Step 4 runs the same curl correctly and documents exactly this** (line 102: "the `--quiet`
flag keeps `kubectl run`'s pod-lifecycle messages out of the `jq` pipe").

**Change:** copy page 36 Step 4's form verbatim — add `--quiet` and `</dev/null`.

## 12. Step 5's expected JSON is wrong, and page 36 already says so — WRONG

Page 37 claims the ClusterIP endpoint returns
`"issuer": "https://iviaop.verify-access.svc.cluster.local:8436/oauth2"`. Live, that same
endpoint returns the **public WRP host**:

```json
{
  "issuer": "https://wrp.c1m7cx.18-204-174-225.nip.io",
  "authorization_endpoint": "https://wrp.c1m7cx.18-204-174-225.nip.io/isvaop/oauth2/authorize",
  "token_endpoint": "https://wrp.c1m7cx.18-204-174-225.nip.io/isvaop/oauth2/token",
  "jwks_uri": "https://wrp.c1m7cx.18-204-174-225.nip.io/isvaop/oauth2/jwks"
}
```

Page 36 Step 4 states this correctly *and explains why* ("The provider always advertises the
one public WRP issuer, which lets Vault validate IVIA tokens against a single
`bound_issuer`"). The two pages directly contradict each other on the same command.

**Also line 150** says "`issuer` matches **`bound_issuer`** above" — `bound_issuer` is
jwt-backend vocabulary; Step 3 on this very page uses `issuer_id`. Stale term, same root cause.

---

# Part 3 — Expected-output blocks that don't match reality

None of these block an attendee, but each one makes a healthy system look broken.

## 13. `31-deploy-at-an-event` line 77 — Vault version — WRONG

Page `Version 1.20.x+ent`; live **`2.0.3+ent`**. `35-verify-vault` line 90 already says
`2.0.3+ent`, so page 31 contradicts reality *and* its sibling.

## 14. `31-deploy-at-an-event` lines 80–86 — "seven pods", output has eight rows — WRONG

```
NAME                           READY   STATUS      RESTARTS      AGE
ivia-autoconf-c2436439-vlgl7   0/1     Completed   0             38m    <-- unmentioned
iviaconfig-8474cc8c6d-6g4jw    1/1     Running     0             47m
iviadsc-78dc7d8cbd-nbktf       1/1     Running     4 (44m ago)   47m    <-- restarts unmentioned
iviaop-55cb5cd967-gc7jk        1/1     Running     0             5m22s
iviaruntime-7fcbc75b54-8wgx4   1/1     Running     0             33m
iviawrprp1-747fbb768c-cbtwt    1/1     Running     0             32m
openldap-79646c67fc-7prr4      1/1     Running     0             47m
postgresql-5b564c6f7b-tcpbx    1/1     Running     0             47m
```

Two things read as failures: the autoconf **Job** at `0/1 Completed` (that is what a finished
Job looks like — genuinely not a failure), and `iviadsc` at `RESTARTS 4`.

On the restarts, state only what is verified. `kubectl describe` reports
`Last State: Terminated · Reason: Error · Exit Code: 1`, with start and finish one second
apart — so it crash-looped four times during bring-up and then stabilised (`Ready: True`).
Do **not** describe this as "normal" in the page without establishing why it exits 1; say the
pod restarts several times during bring-up and is healthy once `READY 1/1`.

**`36-verify-identity-access` line 39 already handles the Job correctly** — it shows the
autoconf row and says "seven pods Running **and the autoconf job Completed**". Copy that
wording to page 31 and add both to page 31's existing "looks like a failure, isn't" list.
(Cosmetic: page 36 lists autoconf last; `kubectl` sorts alphabetically so it appears first.)

## 15. `32-configure-kubectl` lines 20–25 — node DNS suffix is wrong for us-east-1 — WRONG

Page: `ip-10-1-1-xxx.<region>.compute.internal`. Live: **`ip-10-1-28-150.ec2.internal`**.
us-east-1 uses `ec2.internal`; `<region>.compute.internal` is every *other* region. The
contentspec pins `deployableRegions.required: [us-east-1]`, so the page is wrong for the only
region it can run in.

## 16. `35-verify-vault` Step 1 — "all three pods", output has four — WRONG

```
vault-0                                 1/1   Running   0   47m
vault-1                                 1/1   Running   0   47m
vault-2                                 1/1   Running   0   47m
vault-agent-injector-5b7dd85f5c-l848b   1/1   Running   0   47m   <-- unmentioned
```

**Change:** add the `vault-agent-injector` row. (Cosmetic: Step 3's peer list is ordered
vault-0/1/2 on the page but returned 0/2/1 live — worth a "order varies" note.)

## 17. `35-verify-vault` Step 5 — two mismatches — WRONG

- The `secrets list` expected block shows **3 columns**; actual has **4** (Accessor). Type
  reads `agent_registry` with an **underscore**, not `agent-registry`, and the description is
  `agent registry`, not `n/a`.
- The expected block shows a `Build Date` line, but the command is `vault status | grep -i
  version`, which cannot emit it. Live returns only `Version 2.0.3+ent`.

## 18. `36-verify-identity-access` line 74 — ALB hostname shape — WRONG

Page: `k8s-workshop-acme-<hash>.<region>.elb.amazonaws.com`. Live:
`k8s-workshopacme-61ec0da744-2132079147.us-east-1.elb.amazonaws.com` — **`workshopacme`, no
hyphen**; the ALB name strips hyphens from the IngressGroup name.

## 19. `38-platform-health-check` — documents 8 checks, script runs 13 — GAP

Live output:

```
✓ PASS Vault pods running (3 of 3)
✓ PASS Vault seal status: unsealed
✓ PASS Vault Raft peers: 3
✓ PASS Vault audit device: enabled (1 device(s))
✓ PASS IVIA pods running (7 pod(s))
✓ PASS IVIA OIDC discovery: issuer reachable (https://wrp.c1m7cx.18-204-174-225.nip.io)
✓ PASS cert-manager pods running (3 pod(s))
✓ PASS AWS Load Balancer Controller running (2 pod(s))
✓ PASS Vault Enterprise edition (version=2.0.3+ent; sys/license/status responds)
✓ PASS Secrets engines mounted: database/ + aws/ (platform-standard license present)
✓ PASS Agent Registry responds — registration 'uc1-agent' resolvable by display-name
✓ PASS OAuth resource server profile 'ivia' responds (feature active + profile applied)
✓ PASS jwt/ auth mount is ABSENT — retired IVIA jwt backend removed (decision (e))
 ✓ 13 check(s) passed
```

- Page says "all **8** checks PASS" — it is **13**. The five undocumented ones are the whole
  native-Vault story: Enterprise edition, secrets engines, Agent Registry, OAuth resource
  server, and the retired-`jwt` assertion. This is the finding that matters here.
- The "What the script verifies" table (lines 33–42) needs the five new rows.
- Page's `issuer reachable (https://<wrp-alb-hostname>)` is misleading — live shows the
  **nip.io** host, not an ALB hostname.
- Page expects `cert-manager pods running (2 pod(s))` — live **3**; and `AWS Load Balancer
  Controller running (1 pod(s))` — live **2**. These are **replica-count dependent**, so
  rather than swapping one hardcoded number for another, drop the exact counts from the
  expected block (`cert-manager pods running (N pod(s))`).

## 20. `33-verify-infrastructure` — expand list omits two whole sections — GAP

The expand (lines 26–34) lists EKS, RDS, Bedrock KB, audit log groups, region contract. The
script also runs:

```
=== OpenLDAP (IVIA user registry) ===
  ✓ PASS OpenLDAP deployment Available in verify-access namespace
  ✓ PASS OpenLDAP user 'oscar' exists (cn=oscar,dc=ibm,dc=com)
=== Vault Native Surface (Enterprise + Agent Registry) ===
  ✓ PASS Vault Enterprise edition (version=2.0.3+ent)
  ✓ PASS Agent Registry responds — registration 'uc1-agent' resolvable by display-name
```

Worth calling out for at-an-event specifically: this page nominally verifies Tier 1, but it
now also verifies **Tier-2** surface — which is exactly the reassurance an at-an-event
attendee wants. Line 34's region-contract example says `us-west-2`; live prints
`No region literal 'us-east-1' outside infrastructure/terraform.tfvars`.

---

# Part 4 — Tooling that contradicts the page

## 21. `bootstrap.sh` closing summary — WRONG at an event (script, not content)

After the attendee runs the page's Step 2, the last thing on their screen is:

```
Next steps (deploy one tier at a time):
  Each tier prompts for the inputs it needs — Tier 1: Let's Encrypt email · Tier 2: ICR entitlement key + IVIA MMFA secret
  1. Core infra (VPC/EKS/RDS/KB):   ./infrastructure/scripts/deploy-workshop.sh --tier 1
  2. Vault + IVIA:                  ./infrastructure/scripts/deploy-workshop.sh --tier 2
  3. Workloads (Use Cases 1-3):     ./infrastructure/scripts/deploy-workshop.sh --tier 3
```

They were just told Tiers 1–2 are pre-provisioned, and the tooling immediately tells them to
deploy all three and warns of prompts for secrets they do not have. This is the only place in
the run where the tooling actively contradicts the page.

**Change:** suppress items 1–2 when on the at-an-event path, or add an explicit at-an-event line.

---

# Part 5 — Use Case pages

## 22. `50-use-case-1/52-verify-credentials` Step 3 — the command returns NOTHING — BLOCKER

The page's audit-log command hardcodes `vault-0`:

```bash
kubectl logs -n vault vault-0 --since=15m | jq -c 'select(.type=="response" and .request.path=="database/creds/uc1-readonly") | …' | tail -1
```

Ran verbatim after Step 2 → **empty output, exit 0**. The page shows a JSON row as expected.

**Root cause: Vault is 3-node HA and the issuance events are not on `vault-0`.** Proven by
counting matching events per pod over the same window:

```
vault-0  →  0 issuance event(s)
vault-1  →  0 issuance event(s)
vault-2  →  4 issuance event(s)
```

Credentials were definitely issued — the lease count went **2 → 4** across a single `/query`,
and swapping `vault-0` → `vault-2` in the page's own command returns the documented row. Which
pod is active varies per deployment, so this silently fails for roughly two-thirds of attendees
and there is nothing in the output to tell them why.

## 23. `52-verify-credentials` Step 3 — the same command aborts on a `jq` parse error — BLOCKER

Independent of 22. `kubectl logs` is piped straight into `jq`, but the Vault container's
entrypoint writes **non-JSON** lines:

```
Container is running as non-root user, ignoring SKIP_CHOWN
Container is running as non-root user, ignoring SKIP_SETCAP
WARNING: Request Limiter configuration is no longer supported; …
==> Vault server configuration:
```

With `--since=15m` those lines are usually out of the window, so it happens to survive. Widen
to `--since=60m` or `6h` — or run it on a pod that restarted recently — and it dies:

```
jq: parse error: Invalid numeric literal at line 1, column 10
```

**Verified replacement** (returns exactly the row the page documents,
`display_name: kubernetes-uc1-uc1-retriever-sa`):

```bash
kubectl logs -n vault -l app.kubernetes.io/name=vault,component=server --tail=-1 --since=15m \
  | grep -aE '^\{' \
  | jq -c 'select(.type=="response" and .request.path=="database/creds/uc1-readonly")
           | {time, path: .request.path,
              display_name: .auth.display_name,
              lease_id: .response.secret.lease_id}' \
  | tail -1
```

Three changes, all required: `-l …component=server` (fixes 22), `grep -aE '^\{'` (fixes 23),
and **`--tail=-1`** — non-obvious but mandatory, because `kubectl logs` with a **selector**
silently defaults to `--tail=10` per pod. Without it the command returns empty even though it
is otherwise correct. That is a trap worth a one-line note on the page.

## 24. `52-verify-credentials` Step 2 — documented answer no longer matches — WRONG

Page expects `"answer": "I was unable to find any tables in the database ..."` and teaches
that "`uc1-readonly` only GRANTs SELECT on schema `public` (**empty here**)". Live, the agent
answers about the PostgreSQL **system catalog** instead:

> "The database contains numerous system tables and views, which are part of the PostgreSQL
> system catalog… If you are looking for user-created tables, they might be in a different
> schema or might not exist in this database."

`credential_metadata` matches the page exactly (`vault_authenticated: true`, `vault_role: uc1`),
so only the answer text and the "empty here" gloss need rewriting. Note Tier 3 Step 13 now
seeds the banking DB, so "empty" is the wrong mental model to teach — the point is that the
credential is scoped to `public`, not that the database is empty.

## 25. `52-verify-credentials` Step 5 — nine checks documented, ten run — WRONG

`verify-uc1.sh` prints **`✓ 10 check(s) passed`**. The undocumented one is the Agent Registry
check — the native-Vault story again (same omission as finding 19):

```
✓ PASS UC1 Agent Registry: registration 'uc1-agent' resolvable by display-name
        (registry identity; ceiling INERT — k8s uc1-readonly is the floor)
```

Add it to both the table (lines 113–124) and the expected summary, and change
`✓ 9 check(s) passed` → `10`. Also line 111's "runs nine checks".

**Same block, second mismatch:** page expects `username=v-kubernet-uc1-read-…`; live is
`username=v-root-uc1-read-RB5FntCXtJqAgmqBBwta-1786416229` — the script authenticates with the
root token, so the display-name segment is `root`, not `kubernet`.

## 26. `50-use-case-1/51-configure-vault-auth` Step 1 — two field errors — WRONG

| Page | Live |
|---|---|
| `alias_name_source  serviceaccount_uid` | **`serviceaccount_name`** |
| `policies  [uc1-readonly]` | key is **`token_policies`** — there is no `policies` field |

Both are in the block an attendee visually diffs against. The `alias_name_source` one also
undercuts the Platform-track narrative further down the page, which turns on how the alias is
keyed.

The expected block also omits seven fields the command actually returns (`alias_metadata`,
`bound_service_account_namespace_selector`, `token_bound_cidrs`, `token_explicit_max_ttl`,
`token_no_default_policy`, `token_num_uses`, `token_period`) — fine to keep abridged, but say
so ("key fields", as pages 62 and 72 correctly do).

## 27. `51-configure-vault-auth` Step 5 — registration field is inverted — WRONG

Page expects `optional_authorization_details  true`; live is **`false`**.

This one is not cosmetic: the page's whole argument is that Use Case 1's ceiling is *inert*,
and this field is about whether a per-request RAR is optional. Worth confirming which value is
intended before editing — for contrast, `agent-uc2` really is `true` and `uc3-actor` really is
`false`, both matching their pages. Live `uc1-agent` also returns `no_default_ceiling_policy
true` and `owner uc1-retriever-service`, neither documented.

## 28. Pages 51, 62, 72 assume a `vault` CLI the at-an-event path never installs — GAP

Those pages run `vault read` / `vault policy read` directly. The tool that installs the
`vault` CLI is `check-prerequisites.sh` (it installs `kubectl, helm, terraform, vault, aws,
jq, yq`), and the at-an-event deploy page deliberately runs
`bootstrap.sh --skip-prereq-gate`, whose own message is:

```
Skipping tool install + tool-version gates; assuming aws/terraform/kubectl/jq/helm/vault pre-installed.
```

So the at-an-event path never installs it. Whether this actually breaks depends on what the
event's CloudShell image ships — **I could not test that here** (my machine has `vault` via
Homebrew, which masks the problem exactly as it would for anyone testing self-paced).

**Needs a decision, not a guess:** either confirm `vault` is present in the Workshop Studio
CloudShell image, or give these pages the `kubectl exec -n vault vault-0 -- vault …` form that
page 72's own Verification section already uses and which needs no local CLI.

## 29. `70-use-case-3/74-three-plane-audit` — mechanics verified, one table undocumented — GAP

Everything testable without a completed refund works: `terraform -chdir=infrastructure output
-raw region` resolves (`us-east-1`) from the pulled state, the `workshop` Athena workgroup
resolves, the helper functions run, and every catalog object the page queries exists.
`SHOW TABLES IN workshop_logs` returns **five**:

```
agent_traces        <-- not mentioned anywhere on the page
audit_correlation
ivia_decisions
pgaudit_logs
vault_audit
```

The Step 1 query returns a header and no rows, which is correct with no refund performed. The
correlation row itself is **unverified** — it needs the CIBA flow.

## 30. `31-deploy-at-an-event` line 119 — Tier 3 duration overstated — WRONG (minor)

Page says "~5–10 min". Measured live: **3m34s** end to end (19:24:21 → 19:27:55), covering
apply through Step 14 KB ingestion and `Deploy Complete`. Under-promising is the safe
direction, but the real number is better.

---

# What passed exactly as written — no change needed

- **Deploy page Steps 2, 3, 5** — bootstrap exit 0; all five state artifacts pulled
  (`State + config pulled OK`); Tier 3 **exit 0, 8 checks passed, 0 FAIL, 0 WARN**,
  45 resources added, 5/5 deployments rolled, DB seeded, all 3 KB data sources `COMPLETE`.
- **The `issuer_id` contract** — the check the whole at-an-event path exists to prove:
  `issuer_id https://wrp.c1m7cx.18-204-174-225.nip.io` exactly matches
  `NIP_FQDN_WRP=wrp.c1m7cx.18-204-174-225.nip.io`.
- **Outputs-only Tier-2 state** behaved exactly as the page's alert describes.
- **`33-verify-infrastructure`** — `Foundation verification: ALL components passed`, and the
  KB id is surfaced in a "Next step" box at the end rather than left as a placeholder.
- **`34-ingest-knowledge-base`** — re-running the trigger converged; all three data sources
  returned `COMPLETE`, confirming the page's idempotency claim.
- **`35-verify-vault`** Steps 2–4 and the three agent registrations (`agent-uc2`,
  `uc1-agent`, `uc3-actor`) — exact match.
- **`36-verify-identity-access`** Steps 1–4 — all correct, including the autoconf-Job row and
  the internal-issuer explanation that page 37 gets wrong.
- **`37-the-oidc-seam` Step 3** — exact match (`audiences [uc3-actor agent-uc2]`,
  `enabled true`, `issuer_id` = nip.io).
- **`32-configure-kubectl`** — the dual self-paced/at-an-event authorization note (line 14)
  and the `Unauthorized` remediation (line 30) are both exactly right.
- **`51-configure-vault-auth` Steps 2, 3, 4** — policy, auth list and DB role all match
  (modulo extra columns/fields the abridged blocks omit). Step 3 correctly shows **no `jwt/`
  row**, which is what page 37 gets wrong.
- **`52-verify-credentials` Steps 1 and 4** — the `/ask` page serves HTTP 200 with a valid
  Let's Encrypt cert (`ssl_verify_result=0`), and ENFC-01 returns exactly
  `DENIED (expected): Forbidden`.
- **`62-configure-oauth-resource-server` Steps 1–4** — every output matches, including
  `agent-uc2` `optional_authorization_details true`, the ceiling, the human baseline, and the
  `uc2-personal-readonly` DB role. This page is the model the others should follow.
- **`72-configure-rar-ceiling`** — `uc3-actor` registration, `uc3-agent-ceiling` (all six
  paths), the DB role at `default_ttl 5m` / `max_ttl 10m`, and live JIT issuance
  (`lease_duration 5m`) all match exactly.

---

# Deviations from the page, stated for the record

**Step 1** clones `github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault`
at public `main`. That mirror does not yet carry the #21 tier-2 content, so cloning it
verbatim would produce the *old* page instructing the attendee to deploy Tier 2 against an
account where Tier 2 already exists. Ran from the local branch instead. **Every command from
Step 2 onward was executed verbatim as written.**

**Use Case 1 Step 2 needed a second `/query`** to test finding 22 — the first was used for the
page's own Step 2. Both used the page's exact query string.

**No content file has been edited.** This document is a proposal list only.

---

# Part 6 — Use Case 2 and Use Case 3, every command executed (2026-08-11)

Run as `arn:aws:sts::865855451418:assumed-role/WSParticipantRole/workshop-attendee-sim`
against cluster `ars-workshop`, RDS `ars-workshop-pg` (**PostgreSQL 17.9**), Vault 3-node Raft
with `vault-0` active.

## What passed exactly as written

| Page | Blocks | Result |
|---|---|---|
| **OAuth Login Flow** | Step 1 (banking URL), Step 3 (`kubectl logs banking-ui`) | both exit 0 |
| **Configure the OAuth Resource Server** | Steps 1–4 (7 blocks) | all exit 0; 6 of 7 match the page character-for-character (see finding 35 for the 7th) |
| **Verify Per-User Data Access** | Steps 1, 2, 3 + `verify-uc2.sh` | all exit 0, all outputs match — Oscar 2 rows, Jaime 2 rows, RLS policy identical, **20/20 checks** |
| **Scope Enforcement (Layer 2)** | Steps 1.1, 1.2, 1.3, 2.1, 2.2, 2.3 | all match, including the `403` exit-code-2 note and `arwdDxtm` |
| **Credential Revocation** | Steps 1–7 | all match; role created → revoked → gone → absent from leases → both Athena rows found |
| **The Bypass Test** | Sections 2 and 3 | match exactly — `jaime 9` / `oscar 8`, INSERT `permission denied for table refunds` |
| **CIBA Out-of-Band Approval** | pod check, CIBA endpoint probe | exit 0 |

Two things I had flagged as suspect before running, both **cleared**:

- **`arwdDxtm` on Scope Enforcement Step 2.3 is correct.** RDS runs PostgreSQL **17.9**, so the
  `m` (MAINTAIN) privilege is real. The page's "Postgres 17 added `m`" narration is accurate.
- **Scope Enforcement Step 1.3's hardcoded `vault-0` is correct**, and is *not* the same defect
  as finding 22. Proven empirically: I ran the same denied read entered at `vault-1` and the
  audit record landed on `vault-1`, not on the active node. A 403 is rejected at the ACL layer
  on the receiving node before any request forwarding, so the record always lands on whichever
  pod you `exec` into — and Step 1.2 execs into `vault-0`. Finding 22 was different because
  there the issuance came from an agent pod hitting the load-balanced `vault` Service.

## 34. The Bypass Test — the documented output is stale — WRONG

`./verify-uc3.sh --bypass` exits 0, but what it prints bears little resemblance to the page.

| | Page says | Script actually emits |
|---|---|---|
| Check count | `✓ checks passed` (no number) | `✓ 7 check(s) passed` + 1 `⚠ WARN` skip |
| PASS lines | 3 | 7 |
| Wrong-RAR subject | `sub=jaime` | `sub=oscar` |

**The serious part:** the page's second bullet, its second PASS line, and the "Agent actor" row
of the *Three Independent Denials* table all describe a wrong-actor test using
`act.sub=evil-actor`. That check is **Check 19, and it SKIPS by default.** The script says why:
production IVIA only ever signs `act.sub=uc3-actor`, so a wrong-actor token has to be supplied
by an operator via `UC3_WRONG_ACTOR_TOKEN`, and it is explicitly *not required for green*. The
page presents a check that never runs as one that passes.

Three checks that **do** run are undocumented, including the strongest result on the page:

- **Check 16** — the ALLOW case: a correctly-scoped delegated token *is* authorized. The page
  only shows denials, so nothing demonstrates the positive path still works.
- **Check 18** — cross-Use-Case ceiling isolation: an `agent-uc2` token for `oscar` is DENIED
  `database/creds/uc3-refund-writer` because `uc2-agent-ceiling` omits the refund path, *even
  though* `oscar`'s human baseline permits it. This is a genuine agent-confusion defence and it
  is the real replacement for the `evil-actor` story the page tells.
- **Check 15** — the delegated token carries a `jti` and `act.sub=uc3-actor`.

**Change needed:** replace the expected-output block with the real one, rewrite the three
bullets to describe Checks 14 / 17 / 18, retire the `evil-actor` narrative (or mark it clearly
as operator-supplied and skipped by default), and fix the *Three Independent Denials* table's
middle row to describe the ceiling intersection rather than an unregistered actor.

## 35. Configure the OAuth Resource Server, Step 4 — expected output shape is wrong — WRONG

The page shows `creation_statements` as a five-element JSON array with escaped inner quotes:

```
creation_statements    ["CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' ...;",
                        "ALTER ROLE \"{{name}}\" SET search_path TO banking,public;",
                        ...]
```

The CLI actually prints **one** bracketed string, semicolon-separated, with no escaping:

```
creation_statements      [CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; ALTER ROLE "{{name}}" SET search_path TO banking,public; GRANT USAGE ON SCHEMA banking TO "{{name}}"; GRANT SELECT ON ALL TABLES IN SCHEMA banking TO "{{name}}"; ALTER DEFAULT PRIVILEGES IN SCHEMA banking GRANT SELECT ON TABLES TO "{{name}}";]
```

Everything else on that page — `auth list`, `secrets list`, the `agent-uc2` registration
(`optional_authorization_details true` is correct here, unlike `uc1-agent` in finding 27), the
ceiling and the human baseline — matches character-for-character.

## 36. CIBA Out-of-Band Approval — three commands, no expected output — GAP

The Verification section is the only place in Use Case 2 or 3 where commands ship with no
expected output at all. Executed:

```
kubectl get pods -n banking-app -l app=uc3-agent
NAME                         READY   STATUS    RESTARTS   AGE
uc3-agent-7f5cd744d7-zwlzx   1/1     Running   0          11h

kubectl exec -n vault vault-0 -- sh -c "wget -q -O - --no-check-certificate '…/openid-configuration'" | jq '.backchannel_authentication_endpoint'
"https://wrp.c1m7cx.18-204-174-225.nip.io/isvaop/oauth2/ciba"
```

The middle block — `grep -E 'mmfa_push_fired|ciba_status_polled'` — **returns nothing and exits
1** on a cluster where no CIBA flow has run (confirmed: 5,691 lines in the agent log, zero
matches). The page should say so, because an empty result there reads as a broken deployment
rather than "you haven't done the phone step yet."

## 37. Scope Enforcement Step 2.3 — undocumented role-name shape — GAP

The page's expected `\dp` block shows only `"v-root-uc2-pers-<random>-<timestamp>"` rows. Live
output also contains rows like:

```
"v-JWT Toke-uc2-pers-UYmkDOvf5rKVHzdIavKf-1786457092"=r/vault_root
"v-JWT Toke-uc3-refu-5xgFPChcTbZOy3pw4wDX-1786457391"=r/vault_root
```

`v-JWT Toke-` is Vault truncating the audit display name *JWT Token with JTI: …* into the role
name — these are the credentials issued through the OBO path rather than by the root token. It
looks like string corruption unless the page explains it, and it is actually the most
interesting row on the page: it is the on-behalf-of issuance made visible at the database layer.

## 38. First `kubectl run … psql` on an uncached node loses the output — WRONG (intermittent)

The very first execution of *Scope Enforcement* Step 2.2 produced:

```
If you don't see a command prompt, try pressing enter.
pod "pg-insert-attempt" deleted
pod banking-app/pg-insert-attempt terminated (Error)
```

— no `ERROR:  permission denied for table accounts` line at all. The INSERT *was* correctly
rejected (exit 1), but the evidence the page tells the attendee to look for was missing. Three
immediate re-runs were clean and matched the page exactly.

Cause is the `kubectl run -i` attach race: on a node that has not yet pulled
`postgres:16-alpine`, the image pull delays container start and the attach can miss the stream.
This affects **every** `kubectl run … psql` block across Use Case 2 and Use Case 3, and an
attendee hits it at most once per node. The page should tell them to simply re-run the block.

## Human Needed — four steps that cannot be automated

| Step | Why |
|---|---|
| ~~**Configure the OAuth Resource Server**, Step 5~~ | **No longer blocked — executed.** You supplied both the `id_token` and `access_token` from a live session, which is what exposed finding 39. |
| **Enroll Your Device** | Requires a physical phone running IBM Verify and a QR scan. The URL-building command was executed and exits 0. |
| **Test the Refund Flow** | Requires the browser chat plus a physical **Approve** tap. Its URL command was executed and exits 0; the `mmfa_push_fired` log grep returns nothing until the flow runs. |
| **The Bypass Test**, Section 4 | Depends on a refund row, and refunds are only created by the CIBA flow. Confirmed live: `banking.refunds` is **empty for both personas**, so Step 4.1 exits 0 with `(0 rows)` and Step 4.2 has no `REFUND_ID` to use. The page already warns the IDs are per-run; it should also say the section is unreachable until the refund is done. |

## 39. Configure the OAuth Resource Server, Step 5 — 403 for every attendee — BLOCKER

The page told the attendee to copy the **`id_token`** cookie out of DevTools and present it to
Vault as `X-Vault-Token`. That fails 100% of the time:

```
Code: 403. Errors:
* permission denied
```

The token looks perfectly healthy — correct issuer, `sub=oscar`, 58 minutes left on it. The
whole failure is one absent claim. Vault's Agent Registry resolves the acting agent from
`act.sub`, and IVIA stamps `act` onto the **access token only** (`isvaop_pretoken`). An
`id_token` has `sub` but no `act`, so no agent entity resolves, the on-behalf-of intersection
has nothing to intersect, and Vault fails closed.

Proven both directions from a single live browser session, same command, same page:

| Cookie | `act.sub` | Result |
|---|---|---|
| `id_token` | absent | `403 permission denied` |
| `access_token` | `agent-uc2` | exit 0 — `username=v-JWT Toke-uc2-pers-oEQHxtksjMikHtjLPnpe-1786459642` |

The access-token run matched the page's documented expected output line for line, including the
odd-looking `v-JWT Toke-` username — so **the only thing wrong with Step 5 was the cookie name.**
One real diff surfaced alongside it: the page claimed `lease_renewable true`; the observed value
is `false`.

The application already had this right, and says so in a source comment
(`applications/banking-app/ui/src/routes/api/chat/+server.ts`):

> Forward the ACCESS token, not the id_token … The id_token carries no `act` claim, so
> presenting it yields a null identity and Vault denies the database-creds read.

**Fixed:** cookie name corrected in the prose, the numbered steps, the `JWT_TOKEN=` placeholder
and the expected output, plus a warning alert explaining why the `id_token` cannot work — the
403 is correct fail-closed behaviour, and that is worth teaching rather than hiding.

## 40. OAuth Login Flow — the same error, three more times — WRONG

The identical claim appears on the preceding page: the sequence diagram's two `Bearer id_token`
arrows, walkthrough step 8 ("the UI's server-side proxy reads the `id_token` cookie and forwards
it"), and the header of the claim-flow list. All corrected to `access_token`, with a sentence on
why the `id_token` stops at the UI (display-only decoding of the user's name).

---

# What is left, after this pass

**Nothing in Use Case 2 or Use Case 3 is untested except what needs a human.** Four steps, all
recorded above as Human Needed: the browser sign-in behind *Configure the OAuth Resource
Server* Step 5 (now executed, because you supplied both cookies), device enrollment, the refund
browser flow, and *The Bypass Test* Section 4 which depends on it.

The one open decision is still **finding 28** — whether the Workshop Studio CloudShell image
ships the `vault` CLI. If it does not, the fix is to switch the affected pages to the
`kubectl exec -n vault vault-0 -- vault …` form.
