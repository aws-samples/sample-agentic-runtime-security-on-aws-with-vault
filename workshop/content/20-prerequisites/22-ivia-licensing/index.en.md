---
title: 'Bootstrap HCP Terraform'
weight: 22
---

The `bootstrap.sh` script sets up your HCP Terraform environment in a single command. HCP Terraform is used for **state management only** — all Terraform plans and applies run locally on your machine.

## What Gets Created

| Resource | Where | Purpose |
|----------|-------|---------|
| **EC2 Spot Service-Linked Role** | AWS IAM | Required for on-demand/spot instance management |
| **HCP Terraform Project** | HCP Terraform | Project to organize the Workspace and variable set |
| **Variable Set** (`agentic-runtime-stacks-config`) | HCP Terraform | Sensitive variables only (`icr_entitlement_key`, `simple_ad_admin_password`) |
| **HCP Terraform Workspace** (`agentic-runtime-security`) | HCP Terraform | Local execution mode — HCP stores state only, applies run on your machine |

## Local Execution with Remote State

The workshop uses **HCP Terraform local execution** mode. This means:

- Terraform plans and applies run **on your local machine** — not on HCP Terraform workers.
- HCP Terraform stores the state file remotely, providing locking, versioning, and team visibility.
- Your local AWS credentials (from `aws configure` or environment variables) are used for authentication.
- Only sensitive variables (`icr_entitlement_key`, `simple_ad_admin_password`) are stored in the HCP Terraform variable set.

:::alert{header="HCP Terraform Standard tier required" type="warning"}
HCP Terraform's free tier is end-of-life on 2026-03-31. The workspace + variable set features require the Standard tier. Upgrade at `https://app.terraform.io/app/<your-org>/settings/billing` before running `bootstrap.sh`.
:::

## Run Bootstrap

```bash
bash infrastructure/scripts/bootstrap.sh <YOUR_HCP_ORG>
```

The script is **idempotent** — safe to re-run. It will skip resources that already exist and update the variable set to match current values.

## Preview Mode

To see what would be created without making any changes:

```bash
bash infrastructure/scripts/bootstrap.sh <YOUR_HCP_ORG> --dry-run
```

## Verify Bootstrap Results

The script verifies each resource as it runs — every step is idempotent and prints a green checkmark when the resource exists or was created successfully. When all steps complete, you will see:

```
===============================================================================
 Bootstrap Complete
===============================================================================

  Organization:  <YOUR_HCP_ORG>
  Project:       Agentic Runtime Security
  Variable Set:  agentic-runtime-stacks-config
  Workspace:     agentic-runtime-security
  Exec Mode:     local
  Region:        us-west-2
```

What was created:
- EC2 Spot Service-Linked Role (if it did not already exist)
- HCP Terraform Project, Variable Set (sensitive vars), and Workspace (local execution)

If any step fails, the script stops with a red error and a remediation hint. Fix the issue and re-run — idempotency means completed steps are skipped.

## IBM Verify Identity Access licensing

IBM Verify Identity Access 11.0.2 is deployed self-hosted on EKS in the Platform module. Licensing details are documented in the [IVIA licensing guide](https://www.ibm.com/docs/en/sva/11.0.0). For workshop delivery, the trial entitlement is sufficient.
