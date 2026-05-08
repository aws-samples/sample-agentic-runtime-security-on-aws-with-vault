---
title: 'Bootstrap HCP Terraform'
weight: 22
---

The `bootstrap.sh` script sets up your entire HCP Terraform and AWS environment in a single command. It creates all the resources needed for the workshop and connects them together.

## What Gets Created

| Resource | Where | Purpose |
|----------|-------|---------|
| **OIDC Identity Provider** | AWS IAM | Allows HCP Terraform to authenticate to AWS via `app.terraform.io` |
| **IAM Role** (`hcp-stacks-deploy`) | AWS IAM | Role that HCP Terraform assumes via OIDC |
| **EC2 Spot Service-Linked Role** | AWS IAM | Required for on-demand/spot instance management |
| **HCP Terraform Project** | HCP Terraform | Project to organize the Stack and variable set |
| **Variable Set** (`agentic-runtime-stacks-config`) | HCP Terraform | Contains `aws_role_arn`, `admin_principal_arn` |
| **HCP Terraform Stack** (`agentic-runtime-security`) | HCP Terraform | Stack with VCS connection to your repository (working directory: `infrastructure/`) |

## Connect HCP Terraform to GitHub

The bootstrap script creates an HCP Terraform Stack that pulls code from **your fork**. Your HCP Terraform organization must have a GitHub VCS connection configured first.

1. In HCP Terraform, go to **Settings** > **Providers** > **Add a VCS provider**
2. Choose **GitHub App** and follow the prompts to install the HashiCorp GitHub App on your GitHub account/org
3. Grant the app access to the **fork** you created in the previous step

:::alert{header="HCP Terraform Standard tier required" type="warning"}
HCP Terraform's free tier is end-of-life on 2026-03-31. Terraform Stacks requires the Standard tier. Upgrade at `https://app.terraform.io/app/<your-org>/settings/billing` before running `bootstrap.sh`.
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

The script verifies each resource as it runs — every step is idempotent and prints a green checkmark (`✓`) when the resource exists or was created successfully. When all seven steps complete, you will see:

```
===============================================================================
 ✓ Bootstrap Complete
===============================================================================

  Organization:  <YOUR_HCP_ORG>
  Project:       Agentic Runtime Security
  Variable Set:  agentic-runtime-stacks-config
  Stack:         agentic-runtime-security
  Region:        us-west-2 (single deployment 'usw2')
```

If any step fails, the script stops with a red error and a remediation hint. Fix the issue and re-run — idempotency means completed steps are skipped.

## IBM Verify Access licensing

IBM Verify Identity Access 11.0.2 is deployed self-hosted on EKS in the Platform module. Licensing details are documented in the [IVIA licensing guide](https://www.ibm.com/docs/en/sva/11.0.0). For workshop delivery, the trial entitlement is sufficient.
