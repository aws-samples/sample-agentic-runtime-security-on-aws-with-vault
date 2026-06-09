# CONTEXT — UC3 three-plane audit fix (2026-06-08 PM)

**Branch:** `feat/provisioning-order-refactor` (LOCAL; 3-tier refactor itself in-flight/uncommitted)
**Status:** PAUSED — Bear done for the day. Do not resume without his go.
**Why audit broke:** NOT an IAM regression. It's an EKS Pod Identity credential-injection timing race.

---

## What is DONE this session (uncommitted until this WIP commit)

1. **Durable Athena `audit_correlation` view auto-create** — `infrastructure/modules/observability/main.tf`
   - Added `null_resource.audit_correlation_view`: runs the stored `CREATE OR REPLACE VIEW` DDL (`local.athena_view_sql`) via AWS CLI during the **tier-1 apply**, polls to `SUCCEEDED`. `depends_on` the 3 base Glue tables (`ivia_decisions`, `vault_audit`, `pgaudit_logs`) + the named query.
   - Updated `aws_athena_named_query.audit_correlation_view` description (kept as console/manual + `verify-uc3.sh` fallback).
   - `README.md` updated (authoritative): Components table + Design Decision now say "view auto-created at apply."
   - `terraform fmt`/`validate` clean. **Verified live:** apply logged `audit_correlation VIEW created/refreshed in workshop_logs`; view materialized.

2. `infrastructure/services/outputs.tf` — `sensitive = true` on `ivia_client_secret` + `ivia_runtime_user_password`.

---

## ROOT CAUSE — empty correlation (PINNED, with proof)

Plain English: EKS Pod Identity is a coat check. When fluent-bit's pod is born, a doorman (the Pod Identity admission webhook) checks a guest list and hands the pod its AWS credentials. The guest-list entry (the pod-identity association) was written **4 seconds** before the pod was born — but the doorman hadn't refreshed his copy yet, so the pod got **no credentials**. AWS never re-checks; that pod runs credential-less forever, falls back to the node role, and is denied writing to `/workshop/*`.

Chain:
- `audit_correlation` view returns 0 rows because the **`vault_audit` plane has 0 rows** → the view's `INNER JOIN ivia_decisions ⋈ vault_audit` annihilates every row.
- `vault_audit` is empty because **fluent-bit pods have NO pod-identity creds injected** → fall back to node role → `CreateLogStream` on `/workshop/vault-audit` returns repeated `AccessDeniedException`.

### Proof (facts, not theory)
| Fact | Evidence |
|---|---|
| fluent-bit pod has zero AWS creds env | `kubectl get pod <fb> -n logging -o json` → no `AWS_*` env in container spec |
| IAM role + policy are CORRECT | role `ars-workshop-fluent-bit` carries inline policy `cloudwatch-workshop` (allows `logs:CreateLogStream`/`PutLogEvents` on `/workshop/*`) |
| Association exists + correctly targeted | `logging/fluent-bit` association present; Pod Identity Agent 5/5 ready |
| Timing race | association created `00:40:45Z`, fluent-bit pods admitted `00:40:49Z` — **4s gap** < webhook propagation; injection silently no-ops, never retried |
| Vault audit device itself works | 2738 JSON audit records on `vault-0` stdout |
| Only fluent-bit path is broken | `/workshop/ivia-decision` HAS data (uc3-agent writes direct via Vault `aws/sts/uc3-logs-writer`, bypassing fluent-bit) |

### Install path (corrected model)
fluent-bit is installed by `module.observability` `helm_release.fluent_bit` (ns `logging`, SA `fluent-bit`) and runs in **tier-1 EKS/infra provisioning**. `module.addons` (eks-blueprints-addons) does **NOT** `enable_aws_for_fluentbit`. `helm_release.fluent_bit` *does* `depends_on` the association (correct) — but `depends_on` only orders the API calls, not the webhook propagation. A manual `kubectl rollout restart` is the WRONG lever (ad-hoc kubectl mutation; fix belongs in provisioning).

---

## PROPOSED FIX (NOT implemented — paused before go/no-go)

Add a `time_sleep` IAM-propagation barrier between `aws_eks_pod_identity_association.fluent_bit` and `helm_release.fluent_bit` in the observability module — **identical pattern already used by `modules/bedrock_kb_aoss`** (see root `infrastructure/main.tf:244-245`, "the time_sleep IAM-propagation barrier in aoss"). Correct-by-construction on every fresh `deploy-workshop.sh`, idempotent, in-pattern.

- Verify the `time` provider is in the observability module `required_providers` before implementing.
- **Caveat — current live cluster:** the running fluent-bit pods already came up credential-less; the barrier fixes *future* fresh deploys but does not recreate existing pods. The pods need ONE recreation to heal. Decide the heal mechanism (let the next from-scratch deploy do it, vs. codify a one-time restart into the same apply) **by studying the repo — do not ask Bear.**

---

## NEXT (after Bear's go)
1. Implement the barrier; apply via `deploy-workshop.sh` (tier-1).
2. Verify `/workshop/vault-audit` populates (fluent-bit logs show successful `CreateLogStream`, no `AccessDenied`).
3. Run a fresh UC3 CIBA flow; confirm `audit_correlation` returns the wide forensic row.
   - The contract is the workshop page `workshop/content/70-use-case-3/74-three-plane-audit/index.en.md` `athena_record` SELECT — use those exact commands, do not invent.

## PENDING TASKS (deferred — no go yet)
- **#1** `--skip-build` flag to skip ECR build+push. A `--skip-build` flag ALREADY exists in `deploy-workshop.sh` — verify it satisfies the ask before adding anything.
- **#2** Investigate the `-target` "not for routine use" warning in `deploy-workshop.sh` tier applies.

**Nothing in `main`. All work LOCAL on `feat/provisioning-order-refactor` until Bear says testing is done.**
