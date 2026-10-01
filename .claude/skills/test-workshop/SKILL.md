---
name: test-workshop
description: 'Test this workshop end to end — full cycle, full content pass or changed-pages pass — following TESTING-PLAYBOOK.md. Invoke when Bear says "let''s test the workshop", "/test-workshop", or names a path to test (self-paced, at-event, CloudShell, laptop). Asks which audience, environment and options to run, every time.'
---

## The playbook is the authority — read it first

Read `TESTING-PLAYBOOK.md` at the repo root **before doing anything else**, and follow it. It is the only description of how this workshop is tested: the invariants, the start-of-run order, the phases, the Use Case 3 command inventory, and the behaviours that look like failures and are not. Do not restate it here and do not work from memory of it — read the file, because it changes.

This skill exists to do two things the playbook cannot: settle **which mode** and **which path** are being run, before the run starts.

## Step 1 — settle the mode

The playbook's *Three modes* table decides it:

- **Full cycle** — self-paced only. Tear down, redeploy all three tiers from the pages, walk every page. Required when anything below the pages changed (Terraform, Helm values, images, deploy/teardown script behaviour) or nothing is standing.
- **Full content pass** — walk every page on the environment already standing. No teardown, no deploy; the deploy pages are read, not executed — except at an event, where **Deploy — At an Event** runs tiers 2 and 3.
- **Changed-pages pass** — walk only the pages changed since the last tested run, on the environment already standing.

Check before offering: is an environment standing (`kubectl config current-context`, `kubectl get nodes`), and what changed since the last validated run (its commit is on the dashboard at `runs/<runId>.commit`). A content pass or changed-pages pass **never tears anything down first**. Never tear down a standing environment without Bear saying to.

## Step 2 — ASK which path. Always.

**This is a hard gate. Ask every single run, with `AskUserQuestion`, and wait.** Never
infer the cell from a previous session, from this skill's own argument text, from a
compacted summary, or from what happens to be standing in the account. Bear's direction,
2026-09-28: *"you need to AALWAYS ASK THAT DAMN IT"* — after a run was started on the
wrong environment and had to be abandoned mid-flight.

Put these to him in one call:

| Choice | Values |
|---|---|
| **Audience** | At an event — always a real Workshop Studio account, tier 1 already built · Self-paced — always Bear's own AWS account |
| **Environment** (at an event only) | AWS CloudShell · Own terminal or IDE. Self-paced is always his own terminal — never CloudShell, never asked. |
| **Image source** (self-paced only) | `ecr` (default: build the five images, push to your own ECR) · `ghcr` (`--image-source=ghcr`, pre-built public images) |
| **Use Case 3 enrollment** | Real phone (scan the QR, tap Approve) · `--no-phone` substitute |

Ask with `AskUserQuestion` — one question per choice, all in the same call. Never as a prose list.

Ask every run, even the ones he named last time. The only choices you may carry
forward are ones he stated **in this session's own messages**.

## Step 3 — confirm the base before anything runs

Every command of the run executes in the **test clone**, a fresh clone of GitHub `main` — never the dev checkout, never under `~/git-repos`. Own terminal: `~/Documents/sample-agentic-runtime-security-on-aws-with-vault`. CloudShell: `~/sample-agentic-runtime-security-on-aws-with-vault`. State in one line, from inside the clone, and stop if any of it is wrong:

- `pwd` is the test clone; its branch and HEAD — `git rev-parse --abbrev-ref HEAD` and `git log --oneline -1`.
- The clone's working tree is clean — `git status --short` is empty.
- The cluster context, when one is standing — `workshop` or an `arn:aws:eks:*` ARN, never `gke_*`.
- The caller identity and region — `aws sts get-caller-identity`, region `us-east-1`.

A test of the wrong branch, or of a dirty tree, measures nothing.

## Step 3.5 — then run it to the end without asking

Once Step 2's path is settled and Step 3's base is confirmed, the run is **autonomous**.
No questions from Phase 0 to the end of Phase 3. Decide from the pages, the scripts and
the repo; record what happens; keep going. Stop only for a credential Bear alone holds, an
account-level denial nothing in the repo can clear, or a destructive action. Findings are
collected and put to him at the end, not raised mid-run.

## Step 4 — run the playbook

Start of run, in the playbook's order: hand over the `tail -f` first, then publish the dashboard and seed it from its template, `.claude/skills/test-workshop/templates/<mode>--<path>.json`, then the mode's first phase. The templates are rebuilt with `python3 .claude/skills/test-workshop/generator/build.py` — never edited by hand.

Follow the published workshop in the browser, as the attendee, in every mode; drive its browser steps in Chrome. Report every step as *Reporting every step* specifies, and write the dashboard after each one.

**Self-paced ends with a hold.** After the last page, stop with everything standing. Bear checks what he wants, including the CIBA refund in the browser. If he finds something, the environment stays up and the fix is tested on it with a content or changed-pages pass. Once he says he is done, walk **Cleanup** verbatim. At an event, never Cleanup.

## What this skill must never do

- **Never author a script, wrapper, or convenience one-liner.** The page is the command. A wrapper of mine once dropped `--image-source ecr` and produced a bogus 403 that cost a day.
- **Never mark a page done on evidence not in this run's log.** An older run's log does not count.
- **Never fix anything mid-run on the self-paced path** — that path is measured, not repaired. A break is a finding.
- **Never close, merge, or open a PR** on the strength of the run. A green run means ready for Bear to test, and nothing more.
- **Never run Phase 0 against a standing, validated environment** because the playbook opens with it. Settle the mode first.
- **Never run Cleanup before Bear says he is done verifying.**
