---
title: 'Prerequisites'
weight: 20
---

Before deploying any infrastructure, set up your environment using the workshop's automation scripts.

## AWS account

- Active AWS account with administrator-equivalent permissions OR the IAM permissions enumerated by `check-prerequisites.sh`'s IAM permissions check
- **Bedrock model access** — the workshop uses **Amazon Nova Pro** invoked via the cross-region inference profile id `us.amazon.nova-pro-v1:0` in `us-west-2`. Amazon's own Nova family is generally enabled by default in fresh AWS accounts (no click-through acceptance), unlike Anthropic Claude models. If `check-prerequisites.sh` reports access denied, request access via the [Bedrock console model-access page](https://us-west-2.console.aws.amazon.com/bedrock/home#/modelaccess) and select "Amazon Nova Pro". The bare model id `amazon.nova-pro-v1:0` is rejected for on-demand throughput — always use the `us.` prefix. **Cost note:** Nova Pro on-demand pricing (~$0.80 / 1M input tokens, ~$3.20 / 1M output tokens) is roughly 25% of Claude Sonnet 4.x for comparable workshop traffic; total LLM cost for a single workshop run is typically under $0.10.

## HCP Terraform

- HashiCorp Cloud Platform Terraform organization on the **Standard tier**.

:::alert{header="HCP Terraform free tier ends 2026-03-31" type="warning"}
HCP Terraform's free tier is end-of-life on 2026-03-31. Terraform Stacks (used by this workshop) requires the Standard tier. Upgrade at `https://app.terraform.io/app/<your-org>/settings/billing` before running `bootstrap.sh`.
:::

## CLI tools

The workshop expects these versions: kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws CLI v2, jq, yq.

The pre-flight script installs them all and verifies your AWS account in one step (see "Pre-flight checks" section below). Manual install steps are intentionally omitted — running the script is the documented path. Windows users: use WSL2 (Linux subsystem).

## Pre-flight checks

The pre-flight script auto-installs all CLI tools (kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws v2, jq, yq), then verifies Bedrock model access, AWS service quotas, and IAM permissions in one shot. It continues past individual failures and emits a consolidated summary with copy-paste remediation for each failure.

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

Available flags:
  - `--interactive` — prompt before each install AND before each check section
  - `--dry-run` — print install plan without executing
  - `--help` — usage

Then bootstrap the HCP Terraform organization (you'll be asked to confirm preflight passed):

```bash
bash infrastructure/scripts/bootstrap.sh <YOUR_HCP_ORG>
```

`bootstrap.sh` is idempotent — safe to re-run.

## Service quotas

The workshop topology requires four service-quota families in `us-west-2` (CONTEXT-locked decision):

- **EC2 standard vCPUs** ≥ 32 (quota code `L-1216C47A`)
- **VPC Elastic IPs** ≥ 6 (quota code `L-0263D0A3`)
- **RDS DB instances per region** ≥ 1 (quota code `L-7B6409FD`)
- **OpenSearch Serverless OCUs — indexing** ≥ 2 (quota code `L-50FA809B`, AWS name: "Default indexing MAX OCU setting", default 10)
- **OpenSearch Serverless OCUs — search** ≥ 2 (quota code `L-4E98D4EB`, AWS name: "Default search MAX OCU setting", default 10)

`check-prerequisites.sh`'s service-quotas section verifies all five quota codes (EC2 + EIP + RDS + AOSS indexing + AOSS search) and prints the exact `aws service-quotas request-service-quota-increase` command to fix any deficit. Before the per-quota loop runs, the script validates each code against the live AWS Service Quotas catalog (`aws service-quotas list-service-quotas --service-code <svc>`) and FAILs fast if any code is unknown — a runtime guardrail against quota-code drift.

:::alert{header="Workshop Studio quota auto-provisioning" type="info"}
AWS Workshop Studio auto-provisions these quotas before account hand-off when the workshop's publisher configures them in the Catalog Builder admin UI (Account Configuration → Service Quotas tab). See `TESTING.md` "Workshop Studio quota auto-provisioning" for the publisher checklist. If you still encounter quota errors during Phase 2 deploy, run `check-prerequisites.sh` and follow the printed remediation to request increases manually.
:::

## IBM Verify Access licensing

IBM Verify Identity Access 11.0.2 is deployed self-hosted on EKS in Phase 3. Licensing details are documented in the [IVIA licensing guide](https://www.ibm.com/docs/en/sva/11.0.0). For workshop delivery, the trial entitlement is sufficient.

Once all checks pass, continue to [Foundational Infrastructure](../30-foundational/).
