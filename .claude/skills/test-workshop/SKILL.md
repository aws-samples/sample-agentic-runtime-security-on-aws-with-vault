---
name: test-workshop
description: 'Run a full clean-slate test of this workshop end to end, following TESTING-PLAYBOOK.md. Invoke when Bear says "let''s test the workshop", "/test-workshop", or names a path to test (self-paced, at-event, CloudShell, laptop). Asks which cell of the 2x2 to run when he has not already said.'
---

## The playbook is the authority — read it first

Read `TESTING-PLAYBOOK.md` at the repo root **before doing anything else**, and follow it. It is the only description of how this workshop is tested: the invariants, the start-of-run order, the phases, the Use Case 3 command inventory, and the behaviours that look like failures and are not. Do not restate it here and do not work from memory of it — read the file, because it changes.

This skill exists to do two things the playbook cannot: settle **which mode** and **which cell of the 2×2** are being run, before the run starts.

## Step 1 — settle the mode

The playbook's *Two modes* table decides it. Do not ask before checking:

- Is an environment standing? `kubectl config current-context` and `kubectl get nodes`.
- What changed since the last validated run? Its commit is on the dashboard at `runs/<runId>.commit`; diff `workshop/content/` and `infrastructure/scripts/` against it.

If nothing is standing, or the diff touches Terraform, Helm values, images, or deploy/teardown script **behaviour**, it is a **full cycle** — say so and do not offer the shorter one. If the environment is up and the diff is pages and message strings only, say which pages changed and offer the **content pass**, with the full cycle as the other option.

Never tear down a standing, validated environment without Bear saying to.

## Step 2 — settle the cell

Two independent choices. Take whichever Bear already gave in his message or in `$ARGUMENTS`, and ask **only** for what is still missing — never re-ask something he already said.

| Choice | Values | How it is usually phrased |
|---|---|---|
| **Audience** | At an event · Self-paced | "at-event", "at an event", "ws", "workshop studio" · "self-paced", "selfpaced", "my account" |
| **Environment** | AWS CloudShell · Own terminal or IDE | "cloudshell", "cs" · "laptop", "local", "terminal", "ide", "mac" |

Ask with `AskUserQuestion` — one question per missing choice, both in the same call. Never as a prose list.

If he names only an audience (the historical trigger was just "self-paced" or "at-event"), ask only the environment.

## Step 3 — confirm the base before anything runs

State in one line, and stop if any of it is wrong:

- The branch and its HEAD commit — `git rev-parse --abbrev-ref HEAD` and `git log --oneline -1`.
- That the working tree is clean — `git status --short` must be empty.
- The cluster context — `kubectl config current-context` must be `workshop` or an `arn:aws:eks:*` ARN, never a `gke_*` one.
- The caller identity and region — `aws sts get-caller-identity` and the region, which is `us-east-1`.

A test of the wrong branch, or of a dirty tree, measures nothing.

## Step 4 — run the playbook

Start of run, in the playbook's order: hand over the `tail -f` first, publish and seed the dashboard second, Phase 0 third. Then, for a full cycle, Phase 0 through Phase 3 for the cell chosen in Step 2 — or, for a content pass, the changed pages only.

Report every step as *Reporting every step* specifies, and write the dashboard after each one.

## What this skill must never do

- **Never author a script, wrapper, or convenience one-liner.** The page is the command. A wrapper of mine once dropped `--image-source ecr` and produced a bogus 403 that cost a day.
- **Never mark a page done on evidence not in this run's log.** An older run's log does not count.
- **Never fix anything mid-run on the self-paced path** — that path is measured, not repaired. A break is a finding.
- **Never close, merge, or open a PR** on the strength of the run. A green run means ready for Bear to test, and nothing more.
- **Never run Phase 0 against a standing, validated environment** because the playbook opens with it. Settle the mode first.
