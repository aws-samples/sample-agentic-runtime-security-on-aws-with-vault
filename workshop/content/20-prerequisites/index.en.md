---
title: 'Prerequisites'
weight: 20
---

Before deploying any infrastructure, set up your environment using the workshop's automation scripts.

## AWS account

- Active AWS account with administrator-equivalent permissions OR the IAM permissions enumerated by `check-permissions.sh`
- **Bedrock model access** — request access to `anthropic.claude-sonnet-4-6` in the `us-west-2` region via the [Bedrock console model-access page](https://us-west-2.console.aws.amazon.com/bedrock/home#/modelaccess). Cross-region inference profile `us.anthropic.claude-sonnet-4-6` is auto-provisioned by AWS once base-model access is granted.

## HCP Terraform

- HashiCorp Cloud Platform Terraform organization on the **Standard tier**.

:::alert{header="HCP Terraform free tier ends 2026-03-31" type="warning"}
HCP Terraform's free tier is end-of-life on 2026-03-31. Terraform Stacks (used by this workshop) requires the Standard tier. Upgrade at `https://app.terraform.io/app/<your-org>/settings/billing` before running `bootstrap.sh`.
:::

## CLI tools

The workshop expects these versions: kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws CLI v2, jq, yq.

Install all of them with one command:

```bash
bash infrastructure/scripts/install-prereqs.sh
```

The script auto-detects macOS (Homebrew) vs Linux (apt or yum, with the official HashiCorp and Kubernetes package repos) and installs everything to consistent versions. Manual install steps are intentionally omitted — running the script is the documented path. Windows users: use WSL2 (Linux subsystem).

## Pre-flight checks

Run all four pre-flight scripts. They continue past individual failures and emit a consolidated summary with copy-paste remediation for each failure.

```bash
bash infrastructure/scripts/check-bedrock-access.sh
bash infrastructure/scripts/check-quotas.sh
bash infrastructure/scripts/check-permissions.sh
```

Then bootstrap the HCP Terraform organization:

```bash
bash infrastructure/scripts/bootstrap.sh <YOUR_HCP_ORG>
```

`bootstrap.sh` is idempotent — safe to re-run.

## Service quotas

The workshop topology requires four service-quota families in `us-west-2` (CONTEXT-locked decision):

- **EC2 standard vCPUs** ≥ 32 (quota code `L-1216C47A`)
- **VPC Elastic IPs** ≥ 6 (quota code `L-0263D0A3`)
- **RDS DB instances per region** ≥ 1 (quota code `L-7B6409FD`)
- **OpenSearch Serverless OCUs — indexing** ≥ 2 (quota code `L-CCD27F9D`)
- **OpenSearch Serverless OCUs — search** ≥ 2 (quota code `L-A8E7DE8E`)

`check-quotas.sh` verifies all five quota codes (EC2 + EIP + RDS + AOSS indexing + AOSS search) and prints the exact `aws service-quotas request-service-quota-increase` command to fix any deficit.

:::alert{header="Workshop Studio quota auto-provisioning" type="info"}
AWS Workshop Studio auto-provisions these quotas before account hand-off when the workshop's publisher configures them in the Catalog Builder admin UI (Account Configuration → Service Quotas tab). See `TESTING.md` "Workshop Studio quota auto-provisioning" for the publisher checklist. If you still encounter quota errors during Phase 2 deploy, run `check-quotas.sh` and follow the printed remediation to request increases manually.
:::

## IBM Verify Access licensing

IBM Verify Identity Access 11.0.2 is deployed self-hosted on EKS in Phase 3. Licensing details are documented in the [IVIA licensing guide](https://www.ibm.com/docs/en/sva/11.0.0). For workshop delivery, the trial entitlement is sufficient.

Once all checks pass, continue to [Foundational Infrastructure](../30-foundational/).
