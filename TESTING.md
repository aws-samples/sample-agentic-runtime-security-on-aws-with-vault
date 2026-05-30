# Tester Role Guide

You are testing this workshop the way a real attendee will experience it. Your job is simple: **follow the workshop content exactly, page by page, and report anything that doesn't work** — with enough detail that we can reproduce and fix it without coming back to ask you questions.

This guide is about **testing the workshop and filing good reports**. You do not need to write or fix code to be a great tester — a precise, reproducible report is the most valuable thing you can give us.

## Setup

1. **Fork the repository** on GitHub (the upstream URL will be shared when the repo moves), then work from your own fork.
2. Before each testing session, **sync your fork's `main`** with upstream so you're testing the latest content.

## The golden rule: run the page, not your own commands

Each workshop page is the contract. Run the **exact** commands from the workshop content (`workshop/content/**/index.en.md`), in order, as written. Do **not** substitute your own homemade one-liners. If the page's command fails, that *is* the bug — and that's exactly what we want to hear about.

## Three kinds of findings → three destinations

| You found... | Where it goes |
|---|---|
| **General feedback, a question, or "this was confusing"** | The **private testing Slack channel**. No GitHub issue needed. |
| **A command errored / didn't match expected output** | A **GitHub Issue → "Bug / Something Not Working"**. Must be reproducible. |
| **A content problem** (typo, wrong/unclear instruction, stale screenshot, broken link) | A **GitHub Issue → "Content Problem"**. |

Open issues from the repo's **Issues** tab — the templates will guide you and make sure we get the diagnostics we need on the first pass.

## What makes a bug report fix-ready

The Bug template asks for all of this — please fill it in completely:

- **Which workshop page + section** (content path or page title, and the step).
- **The exact command you ran**, copied from the page.
- **Expected output** (from the page) vs. **what you actually got**.
- **AWS region** — `us-west-2` for most of the workshop; `us-east-1` for Knowledge Base steps.
- **Tool versions** — `terraform`, `kubectl`, `aws`, `helm`, `vault`.
- **Relevant diagnostics** — pod logs (`kubectl logs ...`), `terraform` output, browser console/network for UI issues, and a **screenshot** for anything visual.
- **Reproducibility** — does it happen every time from a clean state, or is it intermittent?

### Redact secrets — every time

Before pasting anything into GitHub **or** Slack, scrub: **AWS account IDs, ARNs, access keys, JWTs / bearer tokens, and private IPs**. Never paste raw tokens or credentials anywhere.

### Before you file

- **Search open issues first.** If it's already reported, add your details to that issue instead of opening a duplicate.
- **One problem per issue.**

## Out of scope — please don't file these

These are settled decisions for this workshop; issues asking for them will be closed:

- **Windows / WSL** support (macOS and Linux only for v1).
- Switching the **Bedrock model** away from Amazon Nova Pro.

## If you fix it yourself (optional)

Most fixes are done by the maintainer — a solid issue is all we ask for. But if you fix something **and have verified it works**, you're welcome to open a Pull Request:

- **`main` is protected.** All changes land via PR **and review** — no direct pushes.
- Open the PR from your fork. The PR template asks you to **show your proof**: the exact commands you ran, their output, and which workshop page now passes.
- **Infra / deploy changes must go through the existing scripts** (which are idempotent and safe to re-run) — not ad-hoc `terraform` / `kubectl` / `vault` / `aws` commands.

## Definition of done (per page)

You've tested a page well when you have: run **every** command on it against live AWS, seen the real output, and tried both the golden path and the obvious edge case — then reported anything that didn't match.
