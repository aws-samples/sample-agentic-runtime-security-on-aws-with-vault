# Instruqt Distribution — `instruqt/`

This directory is the **Instruqt** distribution of the Agentic Runtime Security
on AWS workshop. It is **additive** to the AWS Workshop Studio v2 distribution
under `workshop/` — the two coexist, share zero state, and target different
attendee experiences.

## Overview

Instruqt runs the workshop as a single ~4-hour mega-track inside a per-attendee
**Instruqt-provisioned AWS sandbox**. The attendee opens a browser, accepts the
runtime parameter prompt (Let's Encrypt email), and is dropped into a Terminal
tab with `aws`, `terraform`, `kubectl`, `git`, and `jq` pre-installed and
`~/.aws/credentials` already pointing at their personal sandbox account.

Everything else — `git clone`, `terraform init`, the 14-step `deploy-workshop.sh`
orchestration, Vault initialization, IVIA configuration, the three use-case
verifiers, and final teardown — runs from challenge `setup-cloud-client` /
`check-cloud-client` / `solve-cloud-client` blocks against that sandbox.

## Dual distribution

| Distribution     | Path           | How attendees consume it                                   | Source of truth for narrative          |
| ---------------- | -------------- | ---------------------------------------------------------- | -------------------------------------- |
| Workshop Studio  | `workshop/`    | Hosted on AWS Workshop Studio v2                           | `workshop/content/**/index.en.md`      |
| Instruqt         | `instruqt/`    | Hosted on Instruqt as track `agentic-runtime-security-aws` | `instruqt/track/NN-<slug>/assignment.md` |

Narrative content originates in `workshop/content/**/index.en.md` and is
**ported** into each `instruqt/track/NN-<slug>/assignment.md`. Ports diverge
only where syntax requires it:

| Workshop Studio syntax                         | Instruqt syntax                                  |
| ---------------------------------------------- | ------------------------------------------------ |
| `:::alert{header="..." type="info\|warning"}…:::` | `{% hint style="info\|warning\|danger" %}…{% endhint %}` |
| `:::expand{header="..."}…:::`                  | Inline body (no expander in Instruqt)            |
| ` ```mermaid ` fenced blocks                   | Same (pre-render to PNG into `assets/` if Instruqt's renderer ever drops support) |

## Region-literal hygiene (Decision 7)

`instruqt/track/config.yml` is a **generated artifact** — gitignored, never
committed. Tracked source is `instruqt/track/config.yml.tmpl` with
`${REGION_PRIMARY}` + `${REGION_KB}` placeholders. `instruqt/scripts/render-config.sh`
extracts both regions at push-time from `infrastructure/terraform.tfvars.example`
(today's documented single-source-of-truth per its file-header comment) and
renders the template via `envsubst`.

This honors the canonical region contract in `CLAUDE.md`: **no AWS region
literal appears in any tracked `instruqt/` file**. The literal lives only in
the generated `config.yml`, which is `.gitignore`d.

Direct `instruqt track push` is **NOT supported** — always go through
`instruqt/scripts/push.sh`, which wraps `render-config.sh` + `instruqt track push`
into a single idempotent command.

## Required Instruqt org secrets

Set these once at the org level — they are NEVER visible to the attendee, and
are injected as env vars into the sandbox at track-play start.

| Org secret name                   | Used by                                                       | What it contains                                                 |
| --------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------- |
| `ICR_ENTITLEMENT_KEY`             | `infrastructure/services/terraform.tfvars` (tier-2 IVIA pull) | IBM Container Registry entitlement key for `cp.icr.io/cp/ivia/*` |
| `IVIA_MMFA_PUSH_SECRET`           | `infrastructure/services/terraform.tfvars` (UC3 MMFA)         | OAuth client secret for the IVIA MMFA push provider              |
| `INSTRUQT_GITHUB_IBM_DEPLOY_KEY`  | `~/.ssh/id_ed25519` (repo clone)                              | Read-only ed25519 private key with access to `git@github.ibm.com:Oscar-Medina/agentic-runtime-security-aws.git` |

## Required runtime_parameter (attendee-supplied)

Prompted in the browser at track-play start; the attendee enters their own value.

| Parameter   | Why it is attendee-supplied                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| `LE_EMAIL`  | Let's Encrypt cert registration uses the email for expiry notifications; must be deliverable to the attendee |

## Authoring loop

1. **Edit** the relevant `instruqt/track/NN-<slug>/assignment.md`, `check-cloud-client`,
   `setup-cloud-client`, or `solve-cloud-client`.
2. **Validate** the track manifest: `cd instruqt/track && instruqt track validate`
3. **Test** end-to-end against a real Instruqt-provisioned sandbox:
   `instruqt track test --keep-running`  (use `--keep-running` to inspect the
   sandbox post-mortem; drop it for a clean teardown verification).
4. **Push** to the Instruqt org:
   `bash instruqt/scripts/push.sh`  (NEVER `instruqt track push` directly —
   the wrapper renders `config.yml` first).
5. **Re-verify** in the Instruqt UI as a fresh attendee in an incognito window.

## Wave-by-wave implementation status

Tracked in `.planning/phases/10-instruqt-port/10-01-PLAN.md`. The plan lays out
six tasks covering script changes (`--tier`, `--skip-tools`, `--yes`), skeleton
+ shim + welcome (Wave 2), deploy + foundation challenges 02-08 (Wave 3),
Use Case 1 challenges 09-11 (Wave 4), Use Case 2 challenges 12-14 (Wave 5), and
Use Case 3 + cleanup + READMEs (Wave 6).

Per-wave summary lands in `.planning/phases/10-instruqt-port/10-01-SUMMARY.md`
when the plan completes.

## Relationship to existing scripts

The Instruqt distribution **reuses** the same `infrastructure/scripts/*` orchestration
the Workshop Studio distribution uses; nothing under `infrastructure/modules/`,
`infrastructure/services/`, `infrastructure/workloads/`, or
`infrastructure/vault-config/` is forked or duplicated. Three small additive
flags were added in Task 2 to support the Instruqt sandbox lifecycle:

| Script                                  | New flag         | Used by                                                  |
| --------------------------------------- | ---------------- | -------------------------------------------------------- |
| `infrastructure/scripts/deploy-workshop.sh` | `--tier <1\|2\|3>` | challenges 05/06/07 (one challenge per deploy tier)      |
| `infrastructure/scripts/check-prerequisites.sh` | `--skip-tools`   | `track_scripts/setup-cloud-client` (sandbox image has CLIs)     |
| `infrastructure/scripts/teardown.sh`    | `--yes`          | `track_scripts/cleanup-cloud-client` + challenge 18 setup-cloud-client |

All three flags are no-op for bare invocation, preserving Workshop Studio
behavior byte-for-byte.
